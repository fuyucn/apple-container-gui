import Foundation
import Core

/// Fixture-backed sample volumes + mock services used by the Volumes `#Preview`s.
///
/// `ContainerVolume` decodes from the real CLI JSON shape (`container volume
/// list --format json`, container v1.0.0). Previews build sample values by
/// decoding JSON shaped exactly like that output so they compile and render
/// without a live daemon or the real `container` binary.
enum VolumePreviewData {
    /// Two sample volumes decoded from fixture-shaped JSON.
    static let volumes: [ContainerVolume] = [decode(dataJSON), decode(cacheJSON)]

    /// A service that returns both sample volumes and never throws.
    static var populatedService: any ContainerService {
        VolumePreviewService(volumes: volumes)
    }

    /// A service that returns nothing (drives the empty state).
    static var emptyService: any ContainerService {
        VolumePreviewService(volumes: [])
    }

    // MARK: - JSON

    private static let dataJSON = """
    {
      "id": "my-data",
      "configuration": {
        "name": "my-data",
        "driver": "local",
        "format": "ext4",
        "sizeInBytes": 67108864,
        "source": "/var/lib/container/volumes/my-data",
        "creationDate": "2026-06-17T10:00:00Z",
        "labels": { "env": "prod" },
        "options": { "size": "64M" }
      }
    }
    """

    private static let cacheJSON = """
    {
      "id": "build-cache",
      "configuration": {
        "name": "build-cache",
        "driver": "local",
        "format": "ext4",
        "sizeInBytes": 268435456,
        "source": "/var/lib/container/volumes/build-cache",
        "creationDate": "2026-06-18T09:30:00Z",
        "labels": {},
        "options": { "size": "256M" }
      }
    }
    """

    private static func decode(_ json: String) -> ContainerVolume {
        // Force-decode is acceptable here because the JSON is a compile-time
        // constant shaped to the model; a failure is a developer error caught
        // immediately in the preview canvas, never in shipped code paths.
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(ContainerVolume.self, from: Data(json.utf8))
    }
}

/// A trivial in-memory `ContainerService` for Volumes previews: returns canned
/// volumes and succeeds on every action. Never touches the filesystem or a
/// process.
private struct VolumePreviewService: ContainerService {
    let volumes: [ContainerVolume]

    func listContainers() async throws -> [Container] { [] }
    func start(_ id: String) async throws {}
    func stop(_ id: String, signal: String?, timeout: Int?) async throws {}
    func kill(_ id: String, signal: String?) async throws {}
    func remove(_ id: String) async throws {}
    func run(_ spec: RunSpec) async throws -> String { "preview-id" }
    func pruneContainers() async throws {}
    func exportContainer(_ id: String, to path: String) async throws {}
    func stats(_ ids: [String]) async throws -> [ContainerStats] { [] }
    func listImages() async throws -> [ContainerImage] { [] }
    func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func removeImage(_ id: String) async throws {}
    func pruneImages() async throws {}
    func tagImage(source: String, newRef: String) async throws {}
    func pushImage(_ ref: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func listVolumes() async throws -> [ContainerVolume] { volumes }
    func createVolume(name: String, size: String?, labels: [String: String]) async throws {}
    func removeVolume(_ name: String) async throws {}
    func pruneVolumes() async throws {}
    func listNetworks() async throws -> [ContainerNetwork] { [] }
    func createNetwork(name: String, internal isInternal: Bool, subnet: String?, labels: [String: String]) async throws {}
    func removeNetwork(_ name: String) async throws {}
    func logs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func daemonStatus() async throws -> DaemonStatus {
        DaemonStatus(state: .running, appRoot: nil, installRoot: nil)
    }
    func startDaemon() async throws {}
    func build(dockerfile: String, context: String, tag: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
