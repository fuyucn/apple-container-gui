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
    private var _volumes: [ContainerVolume]
    private var _networks: [ContainerNetwork]
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
    private var _stoppedCalls: [(id: String, signal: String?, timeout: Int?)] = []
    private var _killedCalls: [(id: String, signal: String?)] = []
    private var _removedIDs: [(id: String, force: Bool)] = []
    private var _deleteAllCount = 0
    private var _runSpecs: [RunSpec] = []
    private var _pruneContainersCount = 0
    private var _exportCalls: [(id: String, path: String)] = []
    private var _statsCalls: [[String]] = []
    private var _removedImageIDs: [String] = []
    private var _listVolumesCount = 0
    private var _createdVolumes: [(name: String, size: String?, labels: [String: String])] = []
    private var _removedVolumeNames: [String] = []
    private var _pruneVolumesCount = 0
    private var _listNetworksCount = 0
    private var _createdNetworks: [(name: String, isInternal: Bool, subnet: String?, labels: [String: String])] = []
    private var _removedNetworkNames: [String] = []
    private var _pulledRefs: [String] = []
    private var _pruneImagesCount = 0
    private var _tagImageCalls: [(source: String, newRef: String)] = []
    private var _pushedRefs: [String] = []
    private var _imageConfigRefs: [String] = []
    private var _buildInvocations: [(dockerfile: String, context: String, tag: String)] = []
    private var _logsInvocations: [(id: String, follow: Bool, boot: Bool, tail: Int?)] = []
    private var _imageShellRefs: [String] = []
    private var _saveImageCalls: [(ref: String, path: String)] = []

    init(
        containers: [Container] = [],
        stats: [ContainerStats] = [],
        images: [ContainerImage] = [],
        volumes: [ContainerVolume] = [],
        networks: [ContainerNetwork] = [],
        imageConfig: ImageConfig? = nil,
        daemonStatus: DaemonStatus = DaemonStatus(state: .stopped, appRoot: nil, installRoot: nil),
        streamLines: [String] = [],
        streamError: Error? = nil,
        throwOnAction: Error? = nil
    ) {
        self._containers = containers
        self._stats = stats
        self._images = images
        self._volumes = volumes
        self._networks = networks
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
    var stopCalls: [(id: String, signal: String?, timeout: Int?)] { withLock { _stoppedCalls } }
    var killCalls: [(id: String, signal: String?)] { withLock { _killedCalls } }
    var removeCalls: [(id: String, force: Bool)] { withLock { _removedIDs } }
    var deleteAllCalls: Int { withLock { _deleteAllCount } }
    var runSpecs: [RunSpec] { withLock { _runSpecs } }
    var pruneContainersCalls: Int { withLock { _pruneContainersCount } }
    var exportCalls: [(id: String, path: String)] { withLock { _exportCalls } }
    var statsCalls: [[String]] { withLock { _statsCalls } }
    var removeImageCalls: [String] { withLock { _removedImageIDs } }
    var listVolumesCalls: Int { withLock { _listVolumesCount } }
    var createVolumeCalls: [(name: String, size: String?, labels: [String: String])] { withLock { _createdVolumes } }
    var removeVolumeCalls: [String] { withLock { _removedVolumeNames } }
    var pruneVolumesCalls: Int { withLock { _pruneVolumesCount } }
    var listNetworksCalls: Int { withLock { _listNetworksCount } }
    var createNetworkCalls: [(name: String, isInternal: Bool, subnet: String?, labels: [String: String])] { withLock { _createdNetworks } }
    var removeNetworkCalls: [String] { withLock { _removedNetworkNames } }
    var pullCalls: [String] { withLock { _pulledRefs } }
    var pruneImagesCalls: Int { withLock { _pruneImagesCount } }
    var tagImageCalls: [(source: String, newRef: String)] { withLock { _tagImageCalls } }
    var pushCalls: [String] { withLock { _pushedRefs } }
    var imageConfigCalls: [String] { withLock { _imageConfigRefs } }
    var buildInvocations: [(dockerfile: String, context: String, tag: String)] { withLock { _buildInvocations } }
    var logsInvocations: [(id: String, follow: Bool, boot: Bool, tail: Int?)] { withLock { _logsInvocations } }
    var imageShellRefs: [String] { withLock { _imageShellRefs } }
    var saveImageCalls: [(ref: String, path: String)] { withLock { _saveImageCalls } }

    // MARK: - ContainerService

    func listContainers() async throws -> [Container] {
        withLock { _listContainersCount += 1; return _containers }
    }

    func start(_ id: String) async throws {
        if let e = throwOnAction { throw e }
        withLock { _startedIDs.append(id) }
    }

    func stop(_ id: String, signal: String?, timeout: Int?) async throws {
        if let e = throwOnAction { throw e }
        withLock { _stoppedCalls.append((id, signal, timeout)) }
    }

    func kill(_ id: String, signal: String?) async throws {
        if let e = throwOnAction { throw e }
        withLock { _killedCalls.append((id, signal)) }
    }

    func remove(_ id: String, force: Bool) async throws {
        if let e = throwOnAction { throw e }
        withLock { _removedIDs.append((id, force)) }
    }

    func deleteAll() async throws {
        if let e = throwOnAction { throw e }
        withLock { _deleteAllCount += 1 }
    }

    func run(_ spec: RunSpec) async throws -> String {
        if let e = throwOnAction { throw e }
        return withLock { _runSpecs.append(spec); return "new-container-id" }
    }

    func pruneContainers() async throws {
        if let e = throwOnAction { throw e }
        withLock { _pruneContainersCount += 1 }
    }

    func exportContainer(_ id: String, to path: String) async throws {
        if let e = throwOnAction { throw e }
        withLock { _exportCalls.append((id, path)) }
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

    func pruneImages() async throws {
        if let e = throwOnAction { throw e }
        withLock { _pruneImagesCount += 1 }
    }

    func tagImage(source: String, newRef: String) async throws {
        if let e = throwOnAction { throw e }
        withLock { _tagImageCalls.append((source, newRef)) }
    }

    func pushImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        withLock { _pushedRefs.append(ref) }
        return makeStream()
    }

    func saveImage(_ ref: String, to path: String) async throws {
        if let e = throwOnAction { throw e }
        withLock { _saveImageCalls.append((ref, path)) }
    }

    func listVolumes() async throws -> [ContainerVolume] {
        withLock { _listVolumesCount += 1; return _volumes }
    }

    func createVolume(name: String, size: String?, labels: [String: String]) async throws {
        if let e = throwOnAction { throw e }
        withLock { _createdVolumes.append((name, size, labels)) }
    }

    func removeVolume(_ name: String) async throws {
        if let e = throwOnAction { throw e }
        withLock { _removedVolumeNames.append(name) }
    }

    func pruneVolumes() async throws {
        if let e = throwOnAction { throw e }
        withLock { _pruneVolumesCount += 1 }
    }

    func listNetworks() async throws -> [ContainerNetwork] {
        withLock { _listNetworksCount += 1; return _networks }
    }

    func createNetwork(name: String, internal isInternal: Bool, subnet: String?, labels: [String: String]) async throws {
        if let e = throwOnAction { throw e }
        withLock { _createdNetworks.append((name, isInternal, subnet, labels)) }
    }

    func removeNetwork(_ name: String) async throws {
        if let e = throwOnAction { throw e }
        withLock { _removedNetworkNames.append(name) }
    }

    func logs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> AsyncThrowingStream<String, Error> {
        withLock { _logsInvocations.append((id, follow, boot, tail)) }
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

    func imageShellInvocation(ref: String) async throws -> ProcessInvocation {
        if let e = throwOnAction { throw e }
        withLock { _imageShellRefs.append(ref) }
        return ProcessInvocation(executable: "container", arguments: ["run", "--rm", "-i", "-t", ref, "sh"])
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
