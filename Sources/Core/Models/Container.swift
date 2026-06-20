import Foundation

/// Run state derived from the container `status.state` string. Unknown strings
/// degrade to `.unknown` rather than failing to decode.
public enum RunState: Sendable, Equatable {
    case running
    case stopped
    case unknown

    init(string: String) {
        switch string.lowercased() {
        case "running": self = .running
        case "stopped": self = .stopped
        default: self = .unknown
        }
    }
}

/// A container as reported by `container list --all --format json` (container
/// v1.0.0). The real schema is two-part: `configuration` (desired spec) and
/// `status` (runtime). Only the fields the GUI needs are modeled; unknown
/// fields are tolerated by Codable's default behavior (extra keys ignored).
public struct Container: Codable, Identifiable, Sendable {
    public let id: String
    public let configuration: Configuration
    public let status: Status

    public struct Configuration: Codable, Sendable {
        public let image: ImageRef
        public let resources: RunResources
        public let platform: Platform
        public let networks: [ConfigNetwork]
        /// Host/container port mappings as reported by the runtime. Optional so
        /// JSON that omits the key (older/leaner shapes) still decodes; surfaced
        /// non-optionally via `Container.publishedPorts`.
        public let publishedPorts: [PublishedPort]?
    }

    /// A published-port mapping from `configuration.publishedPorts`. The runtime
    /// emits extra keys (`count`, `hostAddress`, `proto`) that Codable ignores;
    /// only the host/container ports the GUI needs are modeled.
    public struct PublishedPort: Codable, Sendable {
        public let hostPort: Int
        public let containerPort: Int
    }

    public struct ImageRef: Codable, Sendable {
        public let reference: String
        public let descriptor: Descriptor
    }

    public struct Descriptor: Codable, Sendable {
        public let digest: String
        public let mediaType: String
        public let size: Int
    }

    public struct RunResources: Codable, Sendable {
        public let cpus: Int
        public let memoryInBytes: Int
    }

    public struct Platform: Codable, Sendable {
        public let architecture: String
        public let os: String
    }

    public struct ConfigNetwork: Codable, Sendable {
        public let network: String?
    }

    public struct Status: Codable, Sendable {
        public let state: String
        public let startedDate: String?
        public let networks: [NetworkStatus]
    }

    public struct NetworkStatus: Codable, Sendable {
        public let hostname: String?
        public let ipv4Address: String?
        public let ipv6Address: String?
        public let macAddress: String?
        public let network: String?
    }

    /// Mapped run state; unknown strings → `.unknown`.
    public var state: RunState { RunState(string: status.state) }

    /// Image reference, e.g. `docker.io/library/alpine:latest`.
    public var imageReference: String { configuration.image.reference }

    /// First IPv4 address (CIDR form) reported by the runtime, if any.
    public var primaryIPv4: String? {
        status.networks.compactMap(\.ipv4Address).first
    }

    /// Published host/container port mappings; empty when none are configured.
    public var publishedPorts: [PublishedPort] {
        configuration.publishedPorts ?? []
    }
}
