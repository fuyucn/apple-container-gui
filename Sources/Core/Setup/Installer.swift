import Foundation
import CryptoKit

/// A progress event emitted while downloading the `container` installer `.pkg`.
public enum DownloadEvent: Sendable {
    /// Fractional download progress in `0.0...1.0`. Emitted as bytes arrive;
    /// only meaningful when the server reports a content length, otherwise it
    /// stays at `0` until `.finished`.
    case progress(Double)
    /// The download completed and was written to this on-disk URL (a temp file).
    case finished(URL)
}

/// Errors surfaced by an `Installer`.
public enum InstallerError: Error, Equatable, Sendable {
    /// The releases API response could not be parsed, or contained no `.pkg`
    /// asset.
    case noPkgAsset
    /// The releases API (or download) returned a non-success HTTP status.
    case httpStatus(Int)
    /// The downloaded bytes' SHA256 did not match the expected digest.
    /// Carries the expected and actual hex digests for diagnostics.
    case digestMismatch(expected: String, actual: String)
    /// `pkgutil --check-signature` did not report the expected Apple Team ID,
    /// or the package was unsigned / untrusted. Carries the captured output.
    case signatureMismatch(String)
    /// Running `installer` via `osascript` exited non-zero. Carries stderr.
    case installFailed(String)
}

/// Downloads, verifies, and installs Apple's `container` runtime `.pkg`.
///
/// Authenticity is established in two independent layers: the asset's SHA256
/// digest (integrity) AND the package's Developer-ID signature + notarization
/// pinned to Apple's Team ID (authenticity). A matching digest alone does not
/// prove the bytes came from Apple, so `verifySignature` is mandatory before
/// `installPkg`.
///
/// `Sendable` so the `@MainActor` `SetupCoordinator` can hold and call it.
public protocol Installer: Sendable {
    /// Resolves the latest release's `.pkg` asset download URL and, when the
    /// API advertises one, its expected SHA256 digest (hex, no `sha256:`
    /// prefix). `digest` is `nil` when the API does not report one.
    func latestPkgURL() async throws -> (url: URL, digest: String?)

    /// Streams the download of `url`, emitting `.progress` then a terminal
    /// `.finished(tempURL)`. When `expectedDigest` is non-nil the accumulated
    /// bytes are SHA256-checked on completion and the stream finishes with
    /// `InstallerError.digestMismatch` on a mismatch (the temp file is removed).
    func download(_ url: URL, expectedDigest: String?) -> AsyncThrowingStream<DownloadEvent, Error>

    /// Verifies the `.pkg` at `path` is signed + notarized by the developer
    /// whose Apple Team ID equals `expectedTeamID`, by shelling
    /// `pkgutil --check-signature`. Throws `InstallerError.signatureMismatch`
    /// otherwise.
    func verifySignature(at path: URL, expectedTeamID: String) async throws

    /// Installs the verified `.pkg` at `path` by invoking `installer -pkg …
    /// -target /` with administrator privileges via `osascript`. Triggers the
    /// system authorization prompt.
    func installPkg(at path: URL) async throws
}

/// `Installer` backed by the `apple/container` GitHub releases API and the
/// system `pkgutil` / `installer` tools (the latter via `osascript` for the
/// admin prompt). All process execution flows through the injected
/// `CommandRunner`, keeping `Process` confined to `Core/CLI`.
public struct GitHubInstaller: Installer {
    /// Apple's Team ID for the `container` Developer-ID Installer certificate
    /// (`Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)`),
    /// observed via `pkgutil --check-signature` on the real 1.0.0 signed pkg.
    /// Callers pass this to `verifySignature` as the pin.
    public static let appleTeamID = "UPBK2H6LZM"

    private let session: HTTPClient
    private let runner: CommandRunner
    private let releasesURL: URL

    /// - Parameters:
    ///   - session: HTTP client (protocol-wrapped `URLSession` in production,
    ///     a mock in tests).
    ///   - runner: command runner for `pkgutil` / `osascript`.
    ///   - releasesURL: the `releases/latest` API endpoint (overridable for
    ///     tests).
    public init(
        session: HTTPClient = URLSessionHTTPClient(),
        runner: CommandRunner,
        releasesURL: URL = URL(string: "https://api.github.com/repos/apple/container/releases/latest")!
    ) {
        self.session = session
        self.runner = runner
        self.releasesURL = releasesURL
    }

    // MARK: - Releases lookup

    public func latestPkgURL() async throws -> (url: URL, digest: String?) {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("apple-container-gui", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallerError.httpStatus(http.statusCode)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        // Prefer a signed installer pkg over any other `.pkg` asset.
        let pkgAssets = release.assets.filter { $0.name.hasSuffix(".pkg") }
        guard let asset = pkgAssets.first(where: { $0.name.contains("signed") && !$0.name.contains("unsigned") })
            ?? pkgAssets.first(where: { !$0.name.contains("unsigned") })
            ?? pkgAssets.first,
              let url = URL(string: asset.browserDownloadURL)
        else {
            throw InstallerError.noPkgAsset
        }
        return (url, Self.normalizeDigest(asset.digest))
    }

    /// Strips a leading `sha256:` (or `sha256-`) prefix and lowercases the hex,
    /// returning `nil` for an absent/empty digest.
    static func normalizeDigest(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var s = raw.lowercased()
        for prefix in ["sha256:", "sha256-", "sha-256:"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        return s.isEmpty ? nil : s
    }

    // MARK: - Download + digest verification

    public func download(_ url: URL, expectedDigest: String?) -> AsyncThrowingStream<DownloadEvent, Error> {
        let session = self.session
        let expected = Self.normalizeDigest(expectedDigest)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var hasher = SHA256()
                    var received: Int64 = 0
                    let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw InstallerError.httpStatus(http.statusCode)
                    }
                    let total = response.expectedContentLength
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("container-installer-\(UUID().uuidString).pkg")
                    FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: tempURL)
                    defer { try? handle.close() }

                    var chunk = Data()
                    chunk.reserveCapacity(64 * 1024)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if chunk.count >= 64 * 1024 {
                            hasher.update(data: chunk)
                            try handle.write(contentsOf: chunk)
                            received += Int64(chunk.count)
                            chunk.removeAll(keepingCapacity: true)
                            if total > 0 {
                                continuation.yield(.progress(min(1.0, Double(received) / Double(total))))
                            }
                        }
                    }
                    if !chunk.isEmpty {
                        hasher.update(data: chunk)
                        try handle.write(contentsOf: chunk)
                        received += Int64(chunk.count)
                    }
                    try handle.close()

                    if let expected {
                        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                        guard actual == expected else {
                            try? FileManager.default.removeItem(at: tempURL)
                            throw InstallerError.digestMismatch(expected: expected, actual: actual)
                        }
                    }
                    continuation.yield(.progress(1.0))
                    continuation.yield(.finished(tempURL))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Signature verification

    public func verifySignature(at path: URL, expectedTeamID: String) async throws {
        let result = try await runner.run("/usr/sbin/pkgutil", ["--check-signature", path.path])
        let output = result.stdout + result.stderr
        // `pkgutil` exits non-zero for an unsigned/untrusted package.
        guard result.exitCode == 0 else {
            throw InstallerError.signatureMismatch(output)
        }
        // The Team ID appears parenthesized in the leaf certificate line, e.g.
        // `Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)`.
        guard output.contains("(\(expectedTeamID))") else {
            throw InstallerError.signatureMismatch(output)
        }
    }

    // MARK: - Install

    public func installPkg(at path: URL) async throws {
        let script = Self.installAppleScript(pkgPath: path.path)
        let result = try await runner.run("/usr/bin/osascript", ["-e", script])
        guard result.exitCode == 0 else {
            throw InstallerError.installFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    /// Builds the `osascript` AppleScript that runs `installer` with admin
    /// privileges. The pkg path is escaped for BOTH shell and AppleScript:
    /// `shellQuote` wraps it in single quotes (shell-safe), then the whole
    /// `do shell script` string literal has its `\` and `"` escaped for
    /// AppleScript. This is the shell-injection guard the unit test pins.
    static func installAppleScript(pkgPath: String) -> String {
        let shellCmd = "installer -pkg \(shellQuote(pkgPath)) -target /"
        return "do shell script \(appleScriptQuote(shellCmd)) with administrator privileges"
    }

    /// POSIX single-quote escaping: wrap in `'…'`, and render any embedded
    /// single quote as the `'\''` sequence. Makes the value a single,
    /// metacharacter-inert shell word.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string-literal escaping: wrap in `"…"`, escaping `\` and `"`.
    static func appleScriptQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}

// MARK: - HTTP abstraction

/// Minimal HTTP surface used by `GitHubInstaller`, wrapping the two
/// `URLSession` calls it needs so tests can inject canned responses without a
/// network. `Sendable` for use across actors.
public protocol HTTPClient: Sendable {
    /// Fetches the full response body (used for the small releases JSON).
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    /// Streams the response body byte-by-byte (used for the large pkg download).
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
}

/// Production `HTTPClient` backed by `URLSession.shared`.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await session.bytes(for: request)
    }
}

// MARK: - GitHub releases JSON

/// Subset of the GitHub `releases/latest` payload we decode.
private struct GitHubRelease: Decodable {
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }
}
