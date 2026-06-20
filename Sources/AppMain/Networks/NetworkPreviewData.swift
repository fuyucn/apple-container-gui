import Foundation
import Core

/// Fixture-backed sample networks + mock services used by the Networks `#Preview`s.
///
/// `ContainerNetwork` decodes from the real CLI JSON shape (`container network
/// list --format json`, container v1.0.0). Previews build sample values by
/// decoding JSON shaped exactly like that output so they compile and render
/// without a live daemon or the real `container` binary.
enum NetworkPreviewData {
    /// Two sample networks decoded from fixture-shaped JSON: the builtin
    /// `default` network and a user-created one.
    static let networks: [ContainerNetwork] = [decode(defaultJSON), decode(backendJSON)]

    /// A service that returns both sample networks and never throws.
    static var populatedService: any ContainerService {
        NetworkPreviewService(networks: networks)
    }

    /// A service that returns nothing (drives the empty state).
    static var emptyService: any ContainerService {
        NetworkPreviewService(networks: [])
    }

    // MARK: - JSON

    private static let defaultJSON = """
    {
      "id": "default",
      "configuration": {
        "name": "default",
        "mode": "nat",
        "plugin": "container-network-vmnet",
        "creationDate": "2026-06-17T19:32:12Z",
        "labels": { "com.apple.container.resource.role": "builtin" },
        "options": {}
      },
      "status": {
        "ipv4Gateway": "192.168.64.1",
        "ipv4Subnet": "192.168.64.0/24",
        "ipv6Subnet": "fd33:9ce7:6eb3:3497::/64"
      }
    }
    """

    private static let backendJSON = """
    {
      "id": "backend",
      "configuration": {
        "name": "backend",
        "mode": "nat",
        "plugin": "container-network-vmnet",
        "creationDate": "2026-06-18T09:30:00Z",
        "labels": {},
        "options": {}
      },
      "status": {
        "ipv4Gateway": "192.168.65.1",
        "ipv4Subnet": "192.168.65.0/24",
        "ipv6Subnet": null
      }
    }
    """

    private static func decode(_ json: String) -> ContainerNetwork {
        // Force-decode is acceptable here because the JSON is a compile-time
        // constant shaped to the model; a failure is a developer error caught
        // immediately in the preview canvas, never in shipped code paths.
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(ContainerNetwork.self, from: Data(json.utf8))
    }
}

/// A trivial in-memory `ContainerService` for Networks previews: returns canned
/// networks and succeeds on every action. Never touches the filesystem or a
/// process.
private struct NetworkPreviewService: ContainerService {
    let networks: [ContainerNetwork]

    func listContainers() async throws -> [Container] { [] }
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
    func listNetworks() async throws -> [ContainerNetwork] { networks }
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
