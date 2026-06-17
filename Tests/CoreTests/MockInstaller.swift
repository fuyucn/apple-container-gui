import Foundation
@testable import Core

/// Test-support mock `Installer`. Drives `SetupCoordinator.runAutoSetup`
/// through its happy path (or a chosen failure) without any network, process,
/// or admin prompt. Records which steps ran so the coordinator test can assert
/// ordering. Reference type guarded by a lock for `Sendable`.
final class MockInstaller: Installer, @unchecked Sendable {
    private let lock = NSLock()

    let pkgURL: URL
    let digest: String?
    /// Progress fractions emitted by `download` before `.finished`.
    let progressSteps: [Double]
    /// When set, the named step throws this error.
    let failAt: Step?
    let error: Error

    enum Step: Sendable { case latest, download, verify, install }

    private var _ran: [Step] = []
    var ran: [Step] { lock.lock(); defer { lock.unlock() }; return _ran }
    private func record(_ s: Step) { lock.lock(); _ran.append(s); lock.unlock() }

    init(
        pkgURL: URL = URL(string: "https://example.com/container.pkg")!,
        digest: String? = "abc123",
        progressSteps: [Double] = [0.5, 1.0],
        failAt: Step? = nil,
        error: Error = InstallerError.noPkgAsset
    ) {
        self.pkgURL = pkgURL
        self.digest = digest
        self.progressSteps = progressSteps
        self.failAt = failAt
        self.error = error
    }

    func latestPkgURL() async throws -> (url: URL, digest: String?) {
        record(.latest)
        if failAt == .latest { throw error }
        return (pkgURL, digest)
    }

    func download(_ url: URL, expectedDigest: String?) -> AsyncThrowingStream<DownloadEvent, Error> {
        record(.download)
        let steps = progressSteps
        let shouldFail = failAt == .download
        let err = error
        let finished = URL(fileURLWithPath: "/tmp/mock-container.pkg")
        return AsyncThrowingStream { continuation in
            if shouldFail { continuation.finish(throwing: err); return }
            for s in steps { continuation.yield(.progress(s)) }
            continuation.yield(.finished(finished))
            continuation.finish()
        }
    }

    func verifySignature(at path: URL, expectedTeamID: String) async throws {
        record(.verify)
        if failAt == .verify { throw error }
    }

    func installPkg(at path: URL) async throws {
        record(.install)
        if failAt == .install { throw error }
    }
}
