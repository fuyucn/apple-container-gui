import Foundation

/// A volume as reported by `container volume list --format json` (container
/// v1.0.0). Each element carries a top-level `id` and a `configuration`
/// (name, driver, format, size, source path, labels, optional options).
/// Only the fields the GUI needs are modeled; unknown fields are tolerated by
/// Codable's default behavior (extra keys ignored).
public struct ContainerVolume: Codable, Identifiable, Sendable {
    public let id: String
    public let configuration: Configuration

    public struct Configuration: Codable, Sendable {
        public let name: String
        public let driver: String
        public let format: String
        public let sizeInBytes: Int
        public let source: String
        public let creationDate: String
        public let labels: [String: String]
        /// Driver-specific options (e.g. `{"size": "64M"}`). Optional because the
        /// runtime may omit it for volumes created without explicit options.
        public let options: [String: String]?
    }

    /// Volume name, e.g. `my-data`.
    public var name: String { configuration.name }

    /// Provisioned size in bytes, passed through from the configuration.
    public var sizeInBytes: Int { configuration.sizeInBytes }

    /// The volume's storage driver, e.g. `local`.
    public var driver: String { configuration.driver }

    /// Human-friendly size string derived from `sizeInBytes`, e.g. `64 MB`.
    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(configuration.sizeInBytes), countStyle: .file)
    }
}
