import Foundation

/// A network as reported by `container network list --format json` (container
/// v1.0.0). Each element carries a top-level `id`, a `configuration`
/// (name, mode, plugin, creationDate, labels, options) and an optional `status`
/// (ipv4 gateway/subnet, optional ipv6 subnet) that the runtime populates once
/// the network is realized. Only the fields the GUI needs are modeled; unknown
/// fields are tolerated by Codable's default behavior (extra keys ignored).
public struct ContainerNetwork: Codable, Identifiable, Sendable {
    public let id: String
    public let configuration: Configuration
    /// Realized network status. Optional because a freshly-created network may
    /// not yet report gateway/subnet information.
    public let status: Status?

    public struct Configuration: Codable, Sendable {
        public let name: String
        public let mode: String
        public let plugin: String
        public let creationDate: String
        public let labels: [String: String]
        public let options: [String: String]
    }

    public struct Status: Codable, Sendable {
        public let ipv4Gateway: String
        public let ipv4Subnet: String
        /// IPv6 subnet, when the runtime assigns one. Optional.
        public let ipv6Subnet: String?
    }

    /// Network name, e.g. `default`.
    public var name: String { configuration.name }

    /// The IPv4 gateway address, e.g. `192.168.64.1`; empty when no status.
    public var gateway: String { status?.ipv4Gateway ?? "" }

    /// The IPv4 subnet CIDR, e.g. `192.168.64.0/24`; empty when no status.
    public var subnet: String { status?.ipv4Subnet ?? "" }
}
