import Testing
import Foundation
import CryptoKit
@testable import Core

// MARK: - latestPkgURL: releases JSON parsing

/// Canned `releases/latest` payload mirroring the real apple/container 1.0.0
/// shape: a signed pkg, a dSYM zip, and an unsigned pkg. `latestPkgURL` must
/// pick the signed `.pkg` and surface its `sha256:`-prefixed digest as plain
/// hex.
private let releasesJSON = """
{
  "tag_name": "1.0.0",
  "assets": [
    {
      "name": "container-dSYM.zip",
      "browser_download_url": "https://github.com/apple/container/releases/download/1.0.0/container-dSYM.zip",
      "digest": "sha256:e7f1549a530a6c87d8c130c2a53454cfc4440fe75c9d96bc4ac1fe17ff7bd0fa"
    },
    {
      "name": "container-installer-unsigned.pkg",
      "browser_download_url": "https://github.com/apple/container/releases/download/1.0.0/container-installer-unsigned.pkg",
      "digest": "sha256:70e708fb22a1ce9064350f370ddd8b4b1dd5b6ed34e48ecdb53c55bb1069c73b"
    },
    {
      "name": "container-1.0.0-installer-signed.pkg",
      "browser_download_url": "https://github.com/apple/container/releases/download/1.0.0/container-1.0.0-installer-signed.pkg",
      "digest": "sha256:13f45f26da94c354adcbefe1e8f7631e7f126e93c5d4dd6a5a538aa66b4f479d"
    }
  ]
}
"""

@Test func latestPkgURLExtractsSignedPkgAndDigest() async throws {
    let client = MockHTTPClient(body: Data(releasesJSON.utf8))
    let installer = GitHubInstaller(session: client, runner: MockCommandRunner())

    let (url, digest) = try await installer.latestPkgURL()

    #expect(url.absoluteString == "https://github.com/apple/container/releases/download/1.0.0/container-1.0.0-installer-signed.pkg")
    // Prefix stripped, lowercased.
    #expect(digest == "13f45f26da94c354adcbefe1e8f7631e7f126e93c5d4dd6a5a538aa66b4f479d")
}

@Test func latestPkgURLThrowsWhenNoPkgAsset() async throws {
    let json = #"{"tag_name":"1.0.0","assets":[{"name":"notes.txt","browser_download_url":"https://x/notes.txt","digest":null}]}"#
    let client = MockHTTPClient(body: Data(json.utf8))
    let installer = GitHubInstaller(session: client, runner: MockCommandRunner())

    await #expect(throws: InstallerError.noPkgAsset) {
        _ = try await installer.latestPkgURL()
    }
}

@Test func latestPkgURLThrowsOnHTTPError() async throws {
    let client = MockHTTPClient(body: Data(), statusCode: 503)
    let installer = GitHubInstaller(session: client, runner: MockCommandRunner())

    await #expect(throws: InstallerError.httpStatus(503)) {
        _ = try await installer.latestPkgURL()
    }
}

@Test func normalizeDigestStripsPrefixAndLowercases() {
    #expect(GitHubInstaller.normalizeDigest("sha256:ABCDEF") == "abcdef")
    #expect(GitHubInstaller.normalizeDigest("ABCDEF") == "abcdef")
    #expect(GitHubInstaller.normalizeDigest(nil) == nil)
    #expect(GitHubInstaller.normalizeDigest("") == nil)
}

// MARK: - download: SHA256 mismatch → finish(throwing:)

@Test func downloadFinishesThrowingOnDigestMismatch() async throws {
    let payload = Data("the real bytes".utf8)
    let server = try LoopbackHTTPServer(body: payload)
    defer { server.stop() }

    let installer = GitHubInstaller(
        session: URLSessionHTTPClient(),
        runner: MockCommandRunner()
    )
    // Deliberately wrong expected digest → mismatch.
    let wrongDigest = String(repeating: "0", count: 64)

    var caught: Error?
    do {
        for try await _ in installer.download(server.url, expectedDigest: wrongDigest) {}
    } catch {
        caught = error
    }

    let mismatch = try #require(caught as? InstallerError)
    guard case .digestMismatch(let expected, let actual) = mismatch else {
        Issue.record("expected .digestMismatch, got \(mismatch)")
        return
    }
    #expect(expected == wrongDigest)
    let realHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    #expect(actual == realHash)
}

@Test func downloadFinishesWithFileOnMatchingDigest() async throws {
    let payload = Data("the real bytes".utf8)
    let server = try LoopbackHTTPServer(body: payload)
    defer { server.stop() }

    let installer = GitHubInstaller(session: URLSessionHTTPClient(), runner: MockCommandRunner())
    let correct = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

    var finishedURL: URL?
    for try await event in installer.download(server.url, expectedDigest: correct) {
        if case .finished(let u) = event { finishedURL = u }
    }
    let u = try #require(finishedURL)
    let written = try Data(contentsOf: u)
    #expect(written == payload)
    try? FileManager.default.removeItem(at: u)
}

// MARK: - installPkg / osascript shell-injection guard

@Test func installAppleScriptQuotesSimplePath() {
    let script = GitHubInstaller.installAppleScript(pkgPath: "/tmp/container-installer-ABC.pkg")
    #expect(script == "do shell script \"installer -pkg '/tmp/container-installer-ABC.pkg' -target /\" with administrator privileges")
}

@Test func installAppleScriptNeutralizesInjection() {
    // A malicious path containing shell metacharacters and a single quote must
    // be rendered inert: the single quote becomes the POSIX '\'' sequence and
    // is NOT able to break out of the quoted argument; `;` and `$()` stay
    // literal inside the single quotes.
    let evil = "/tmp/a'; rm -rf / #.pkg"
    let script = GitHubInstaller.installAppleScript(pkgPath: evil)

    // The path is single-quoted in the shell command. The lone `'` is escaped
    // as '\'' which in AppleScript-literal form is '\\''.
    #expect(script.contains("installer -pkg '/tmp/a'\\\\''; rm -rf / #.pkg' -target /"))
    // No unescaped break: the `rm -rf` text never sits outside a quote pair as
    // a bare command (it remains within the single-quoted region).
    #expect(script.hasPrefix("do shell script \""))
    #expect(script.hasSuffix("\" with administrator privileges"))
}

@Test func shellQuoteEscapesSingleQuote() {
    #expect(GitHubInstaller.shellQuote("plain") == "'plain'")
    #expect(GitHubInstaller.shellQuote("a'b") == "'a'\\''b'")
}

@Test func appleScriptQuoteEscapesQuotesAndBackslashes() {
    #expect(GitHubInstaller.appleScriptQuote("a\"b") == "\"a\\\"b\"")
    #expect(GitHubInstaller.appleScriptQuote("a\\b") == "\"a\\\\b\"")
}

// MARK: - verifySignature (against MockCommandRunner)

@Test func verifySignatureMatchesPinnedTeamID() async throws {
    let signed = """
    Package "x.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Certificate Chain:
        1. Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)
    """
    let runner = MockCommandRunner(result: .init(exitCode: 0, stdout: signed, stderr: ""))
    let installer = GitHubInstaller(session: MockHTTPClient(body: Data()), runner: runner)

    // Does not throw when the pinned Team ID is present.
    try await installer.verifySignature(at: URL(fileURLWithPath: "/tmp/x.pkg"), expectedTeamID: "UPBK2H6LZM")
}

@Test func verifySignatureThrowsOnWrongTeamID() async throws {
    let signed = "1. Developer ID Installer: Some Other Co (XXXXXXXXXX)"
    let runner = MockCommandRunner(result: .init(exitCode: 0, stdout: signed, stderr: ""))
    let installer = GitHubInstaller(session: MockHTTPClient(body: Data()), runner: runner)

    await #expect(throws: InstallerError.self) {
        try await installer.verifySignature(at: URL(fileURLWithPath: "/tmp/x.pkg"), expectedTeamID: "UPBK2H6LZM")
    }
}

@Test func verifySignatureThrowsOnNonZeroExit() async throws {
    let runner = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "no signature"))
    let installer = GitHubInstaller(session: MockHTTPClient(body: Data()), runner: runner)

    await #expect(throws: InstallerError.self) {
        try await installer.verifySignature(at: URL(fileURLWithPath: "/tmp/x.pkg"), expectedTeamID: "UPBK2H6LZM")
    }
}
