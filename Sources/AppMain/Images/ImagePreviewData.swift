import Foundation
import Core

/// Fixture-backed sample images + mock services used by the Images `#Preview`s.
///
/// `ContainerImage` decodes from the real CLI JSON shape (`container image list
/// --format json`, container v1.0.0). Previews build sample values by decoding
/// JSON shaped exactly like that output so they compile and render without a
/// live daemon or the real `container` binary.
enum ImagePreviewData {
    /// Two sample images decoded from fixture-shaped JSON.
    static let images: [ContainerImage] = [decode(alpineJSON), decode(nginxJSON)]

    /// A service that returns both sample images and never throws.
    static var populatedService: any ContainerService {
        ImagePreviewService(images: images)
    }

    /// A service that returns nothing (drives the empty state).
    static var emptyService: any ContainerService {
        ImagePreviewService(images: [])
    }

    /// A service whose `pullImage` stream yields a few canned progress lines
    /// then finishes — drives the `PullImageView` progress preview.
    static var pullingService: any ContainerService {
        ImagePreviewService(images: images, pullLines: [
            "Fetching manifest for docker.io/library/redis:alpine",
            "Pulling layer sha256:abc123… 12.4 MB",
            "Pulling layer sha256:def456… 3.1 MB",
            "Unpacking image",
            "Done.",
        ])
    }

    /// A service whose `pushImage` stream yields a few canned progress lines
    /// then finishes — drives the `PushImageView` progress preview. (Reuses the
    /// `pullLines` seam, which `ImagePreviewService.pushImage` streams too.)
    static var pushingService: any ContainerService {
        ImagePreviewService(images: images, pullLines: [
            "Pushing docker.io/library/redis:alpine",
            "Pushing layer sha256:abc123… 12.4 MB",
            "Pushing layer sha256:def456… 3.1 MB",
            "Done.",
        ])
    }

    // MARK: - JSON

    private static let alpineJSON = """
    {
      "id": "28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b",
      "configuration": {
        "name": "docker.io/library/alpine:latest",
        "descriptor": {
          "digest": "sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b",
          "mediaType": "application/vnd.oci.image.index.v1+json",
          "size": 9218
        }
      },
      "variants": [
        {
          "digest": "sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f",
          "platform": { "architecture": "amd64", "os": "linux" },
          "size": 3848024
        },
        {
          "digest": "sha256:aaaa19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56dffff",
          "platform": { "architecture": "arm64", "os": "linux", "variant": "v8" },
          "size": 3622182
        }
      ]
    }
    """

    private static let nginxJSON = """
    {
      "id": "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
      "configuration": {
        "name": "docker.io/library/nginx:alpine",
        "descriptor": {
          "digest": "sha256:aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
          "mediaType": "application/vnd.oci.image.index.v1+json",
          "size": 10240
        }
      },
      "variants": [
        {
          "digest": "sha256:1111ccddeeff00112233445566778899aabbccddeeff001122334455667788ff",
          "platform": { "architecture": "arm64", "os": "linux" },
          "size": 22118400
        }
      ]
    }
    """

    private static func decode(_ json: String) -> ContainerImage {
        // Force-decode is acceptable here because the JSON is a compile-time
        // constant shaped to the model; a failure is a developer error caught
        // immediately in the preview canvas, never in shipped code paths.
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(ContainerImage.self, from: Data(json.utf8))
    }
}

/// A trivial in-memory `ContainerService` for Images previews: returns canned
/// images, succeeds on every action, and produces a (configurable) pull stream.
/// Never touches the filesystem or a process.
private struct ImagePreviewService: ContainerService {
    let images: [ContainerImage]
    var pullLines: [String] = []

    func listContainers() async throws -> [Container] { [] }
    func start(_ id: String) async throws {}
    func stop(_ id: String) async throws {}
    func remove(_ id: String) async throws {}
    func run(_ spec: RunSpec) async throws -> String { "preview-id" }
    func stats(_ ids: [String]) async throws -> [ContainerStats] { [] }
    func listImages() async throws -> [ContainerImage] { images }
    func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        let lines = pullLines
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
    func removeImage(_ id: String) async throws {}
    func pruneImages() async throws {}
    func tagImage(source: String, newRef: String) async throws {}
    func pushImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        let lines = pullLines
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
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
