import Foundation
@testable import Core

/// Test-support mock implementing `ContainerService`.
///
/// Returns pre-seeded domain values from the async query/action methods and
/// finite, pre-seeded line arrays from the streaming methods (finishing the
/// continuation — `.finish()` on success, `.finish(throwing:)` when an error is
/// configured). Records which actions were invoked so view-model tests can
/// assert "action then refresh" behavior.
///
/// A reference type guarded by a lock so it is `Sendable` under strict
/// concurrency and tests can read recorded state after calling through. All
/// lock usage is confined to synchronous helpers (NSLock is unavailable from
/// async contexts).
final class MockContainerService: ContainerService, @unchecked Sendable {
    private let lock = NSLock()

    // Seeded results.
    private var _containers: [Container]
    private var _stats: [ContainerStats]
    private var _images: [ContainerImage]
    private var _imageConfig: ImageConfig?
    private var _daemonStatus: DaemonStatus
    private let streamLines: [String]
    private let streamError: Error?
    private let throwOnAction: Error?

    // Recorded invocations.
    private var _listContainersCount = 0
    private var _listImagesCount = 0
    private var _daemonStatusCount = 0
    private var _startedDaemonCount = 0
    private var _startedIDs: [String] = []
    private var _stoppedIDs: [String] = []
    private var _removedIDs: [String] = []
    private var _runSpecs: [RunSpec] = []
    private var _statsCalls: [[String]] = []
    private var _removedImageIDs: [String] = []
    private var _pulledRefs: [String] = []
    private var _imageConfigRefs: [String] = []
    private var _buildInvocations: [(dockerfile: String, context: String, tag: String)] = []
    private var _logsInvocations: [(id: String, follow: Bool)] = []

    init(
        containers: [Container] = [],
        stats: [ContainerStats] = [],
        images: [ContainerImage] = [],
        imageConfig: ImageConfig? = nil,
        daemonStatus: DaemonStatus = DaemonStatus(state: .stopped, appRoot: nil, installRoot: nil),
        streamLines: [String] = [],
        streamError: Error? = nil,
        throwOnAction: Error? = nil
    ) {
        self._containers = containers
        self._stats = stats
        self._images = images
        self._imageConfig = imageConfig
        self._daemonStatus = daemonStatus
        self.streamLines = streamLines
        self.streamError = streamError
        self.throwOnAction = throwOnAction
    }

    /// Run `body` while holding the lock — the only place the lock is touched.
    /// `nonisolated` + synchronous so it is never called from an async context.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - Seeding

    func setContainers(_ containers: [Container]) { withLock { _containers = containers } }
    func setDaemonStatus(_ status: DaemonStatus) { withLock { _daemonStatus = status } }

    // MARK: - Recorded reads

    var listContainersCalls: Int { withLock { _listContainersCount } }
    var listImagesCalls: Int { withLock { _listImagesCount } }
    var daemonStatusCalls: Int { withLock { _daemonStatusCount } }
    var startDaemonCalls: Int { withLock { _startedDaemonCount } }
    var startCalls: [String] { withLock { _startedIDs } }
    var stopCalls: [String] { withLock { _stoppedIDs } }
    var removeCalls: [String] { withLock { _removedIDs } }
    var runSpecs: [RunSpec] { withLock { _runSpecs } }
    var statsCalls: [[String]] { withLock { _statsCalls } }
    var removeImageCalls: [String] { withLock { _removedImageIDs } }
    var pullCalls: [String] { withLock { _pulledRefs } }
    var imageConfigCalls: [String] { withLock { _imageConfigRefs } }
    var buildInvocations: [(dockerfile: String, context: String, tag: String)] { withLock { _buildInvocations } }
    var logsInvocations: [(id: String, follow: Bool)] { withLock { _logsInvocations } }

    // MARK: - ContainerService

    func listContainers() async throws -> [Container] {
        withLock { _listContainersCount += 1; return _containers }
    }

    func start(_ id: String) async throws {
        if let e = throwOnAction { throw e }
        withLock { _startedIDs.append(id) }
    }

    func stop(_ id: String) async throws {
        if let e = throwOnAction { throw e }
        withLock { _stoppedIDs.append(id) }
    }

    func remove(_ id: String) async throws {
        if let e = throwOnAction { throw e }
        withLock { _removedIDs.append(id) }
    }

    func run(_ spec: RunSpec) async throws -> String {
        if let e = throwOnAction { throw e }
        return withLock { _runSpecs.append(spec); return "new-container-id" }
    }

    func stats(_ ids: [String]) async throws -> [ContainerStats] {
        if let e = throwOnAction { throw e }
        return withLock { _statsCalls.append(ids); return _stats }
    }

    func listImages() async throws -> [ContainerImage] {
        withLock { _listImagesCount += 1; return _images }
    }

    func imageConfig(_ ref: String) async throws -> ImageConfig {
        if let e = throwOnAction { throw e }
        return withLock {
            _imageConfigRefs.append(ref)
            return _imageConfig ?? ImageConfig()
        }
    }

    func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        withLock { _pulledRefs.append(ref) }
        return makeStream()
    }

    func removeImage(_ id: String) async throws {
        if let e = throwOnAction { throw e }
        withLock { _removedImageIDs.append(id) }
    }

    func logs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        withLock { _logsInvocations.append((id, follow)) }
        return makeStream()
    }

    func daemonStatus() async throws -> DaemonStatus {
        withLock { _daemonStatusCount += 1; return _daemonStatus }
    }

    func startDaemon() async throws {
        if let e = throwOnAction { throw e }
        withLock { _startedDaemonCount += 1 }
    }

    func build(dockerfile: String, context: String, tag: String) -> AsyncThrowingStream<String, Error> {
        withLock { _buildInvocations.append((dockerfile, context, tag)) }
        return makeStream()
    }

    // MARK: - Helpers

    private func makeStream() -> AsyncThrowingStream<String, Error> {
        let lines = streamLines
        let error = streamError
        return AsyncThrowingStream { continuation in
            for line in lines {
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.yield(line)
            }
            continuation.finish(throwing: error)
        }
    }
}
