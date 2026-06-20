import Foundation
import Core

/// Fixture-backed sample data + mock services used by the Containers `#Preview`s.
///
/// `Container` has no public memberwise initializer (its fields are decoded from
/// the real CLI JSON), so previews build sample values by decoding JSON shaped
/// exactly like `container list --all --format json` (container v1.0.0). This
/// keeps previews compiling and rendering without a live daemon or the real
/// `container` binary.
enum ContainerPreviewData {
    /// One running container decoded from fixture-shaped JSON.
    static let runningContainer: Container = decode(runningJSON)

    /// One stopped container (state flipped, no active interfaces).
    static let stoppedContainer: Container = decode(stoppedJSON)

    /// A service that returns both sample containers and never throws.
    static var populatedService: any ContainerService {
        PreviewService(containers: [runningContainer, stoppedContainer])
    }

    /// A service that returns nothing (drives the empty state).
    static var emptyService: any ContainerService {
        PreviewService(containers: [])
    }

    // MARK: - JSON

    private static let runningJSON = """
    {
      "id": "preview-web",
      "configuration": {
        "id": "preview-web",
        "image": {
          "reference": "docker.io/library/nginx:latest",
          "descriptor": { "digest": "sha256:abc", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 9218 }
        },
        "resources": { "cpus": 4, "memoryInBytes": 2147483648 },
        "platform": { "architecture": "arm64", "os": "linux" },
        "networks": [ { "network": "default" } ]
      },
      "status": {
        "state": "running",
        "startedDate": "2026-06-17T19:33:38Z",
        "networks": [
          {
            "hostname": "preview-web",
            "ipv4Address": "192.168.64.5/24",
            "ipv6Address": "fd33:9ce7:6eb3:3497:f4de:29ff:feda:36ac/64",
            "macAddress": "f6:de:29:da:36:ac",
            "network": "default"
          }
        ]
      }
    }
    """

    private static let stoppedJSON = """
    {
      "id": "preview-db",
      "configuration": {
        "id": "preview-db",
        "image": {
          "reference": "docker.io/library/postgres:16",
          "descriptor": { "digest": "sha256:def", "mediaType": "application/vnd.oci.image.index.v1+json", "size": 12345 }
        },
        "resources": { "cpus": 2, "memoryInBytes": 1073741824 },
        "platform": { "architecture": "arm64", "os": "linux" },
        "networks": [ { "network": "default" } ]
      },
      "status": {
        "state": "stopped",
        "startedDate": null,
        "networks": []
      }
    }
    """

    private static func decode(_ json: String) -> Container {
        // Force-decode is acceptable here because the JSON is a compile-time
        // constant shaped to the model; a failure is a developer error caught
        // immediately in the preview canvas, never in shipped code paths.
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(Container.self, from: Data(json.utf8))
    }
}

/// A trivial in-memory `ContainerService` for previews: returns canned
/// containers, succeeds on every action, and produces empty streams. Never
/// touches the filesystem or a process.
private struct PreviewService: ContainerService {
    let containers: [Container]

    func listContainers() async throws -> [Container] { containers }
    func start(_ id: String) async throws {}
    func stop(_ id: String) async throws {}
    func remove(_ id: String) async throws {}
    func run(_ spec: RunSpec) async throws -> String { "preview-id" }
    func stats(_ ids: [String]) async throws -> [ContainerStats] { [] }
    func listImages() async throws -> [ContainerImage] { [] }
    func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func removeImage(_ id: String) async throws {}
    func listVolumes() async throws -> [ContainerVolume] { [] }
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
