import Foundation

/// Status of the `buildkit` builder container, decoded from
/// `builder status --format json` (container v1.0.0).
///
/// That command emits a container-like JSON array (the same shape as
/// `list --format json`): each element carries a `configuration` (with an
/// `image.reference` and a `resources` blob of `cpus`/`memoryInBytes`) and a
/// `status` (with a `state` string). The builder is considered RUNNING when the
/// array is non-empty and at least one entry reports a running state; an empty
/// array means the builder container does not exist (stopped/deleted).
///
/// `Sendable` so the view model on the main actor can hold and pass it freely.
public struct BuilderStatus: Sendable, Equatable {
    /// Whether the builder container exists and is running.
    public let isRunning: Bool
    /// The builder image reference (e.g.
    /// `ghcr.io/apple/container-builder-shim/builder:0.12.0`), when reported.
    public let image: String?
    /// CPUs allocated to the builder container, when reported.
    public let cpus: Int?
    /// Builder container memory in bytes, when reported.
    public let memoryInBytes: Int?

    public init(isRunning: Bool, image: String? = nil, cpus: Int? = nil, memoryInBytes: Int? = nil) {
        self.isRunning = isRunning
        self.image = image
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
    }

    /// A stopped/absent builder (empty status array).
    public static let stopped = BuilderStatus(isRunning: false)

    /// Memory as a human-readable, file-style byte count, or nil when unknown.
    public var memoryDescription: String? {
        guard let memoryInBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(memoryInBytes), countStyle: .memory)
    }

    // MARK: - Decoding

    /// The JSON shape of one `builder status --format json` element. Only the
    /// fields the GUI needs are decoded; everything else is ignored.
    private struct Entry: Decodable {
        struct Configuration: Decodable {
            struct Image: Decodable { let reference: String? }
            struct Resources: Decodable {
                let cpus: Int?
                let memoryInBytes: Int?
            }
            let image: Image?
            let resources: Resources?
        }
        struct Status: Decodable { let state: String? }
        let configuration: Configuration?
        let status: Status?
    }

    /// Parse the `builder status --format json` array. Running when the array is
    /// non-empty and at least one entry reports a running state (or no state at
    /// all — a present entry implies the container exists). Resource/image fields
    /// are taken from the first entry.
    public init(parsingJSON json: String) throws {
        let data = Data(json.utf8)
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            throw ContainerError.decodingFailed(String(describing: error))
        }
        guard let first = entries.first else {
            self = .stopped
            return
        }
        let running = entries.contains { entry in
            guard let state = entry.status?.state else { return true }
            return state.lowercased() == "running"
        }
        self.isRunning = running
        self.image = first.configuration?.image?.reference
        self.cpus = first.configuration?.resources?.cpus
        self.memoryInBytes = first.configuration?.resources?.memoryInBytes
    }
}
