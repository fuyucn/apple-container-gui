import Foundation

/// An image as reported by `container image list --format json` (container
/// v1.0.0). Each element carries its OCI index `id` (digest), a `configuration`
/// (name + descriptor) and per-platform `variants`. Unknown fields (e.g. the
/// large per-variant `config` blob) are tolerated and not modeled.
public struct ContainerImage: Codable, Identifiable, Sendable {
    public let id: String
    public let configuration: Configuration
    public let variants: [Variant]

    public struct Configuration: Codable, Sendable {
        public let name: String
        public let descriptor: Descriptor
    }

    public struct Descriptor: Codable, Sendable {
        public let digest: String
        public let mediaType: String
        public let size: Int
    }

    public struct Variant: Codable, Sendable {
        public let digest: String
        public let platform: Platform
        public let size: Int
    }

    public struct Platform: Codable, Sendable {
        public let architecture: String
        public let os: String
        public let variant: String?
    }

    /// Image name/reference, e.g. `docker.io/library/alpine:latest`.
    public var name: String { configuration.name }

    /// Sum of all variant sizes in bytes.
    public var totalSize: Int { variants.map(\.size).reduce(0, +) }

    /// Distinct, ordered list of variant architectures.
    public var platforms: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for v in variants where !seen.contains(v.platform.architecture) {
            seen.insert(v.platform.architecture)
            result.append(v.platform.architecture)
        }
        return result
    }
}
