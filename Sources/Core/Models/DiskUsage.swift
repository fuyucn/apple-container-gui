import Foundation

/// Disk-usage totals for the container runtime, decoded from
/// `system df --format json` (container v1.0.0).
///
/// Note that `system df` emits an OBJECT (not an array) with three per-category
/// blobs — `containers`, `images`, `volumes` — each carrying the same shape
/// (`active`, `reclaimable`, `sizeInBytes`, `total`). This is the
/// Docker-Desktop-style "Disk Usage" breakdown the Settings pane surfaces.
///
/// `Sendable` so the view model on the main actor can hold and pass it freely.
public struct DiskUsage: Codable, Sendable, Equatable {
    /// Stopped + running container disk usage.
    public let containers: Category
    /// Local image disk usage.
    public let images: Category
    /// Volume disk usage.
    public let volumes: Category

    public init(containers: Category, images: Category, volumes: Category) {
        self.containers = containers
        self.images = images
        self.volumes = volumes
    }

    /// One category's usage breakdown. `sizeInBytes` is the total on-disk size;
    /// `reclaimable` is the portion that pruning would free; `active`/`total`
    /// are item counts (active = in-use, total = all).
    public struct Category: Codable, Sendable, Equatable {
        /// Number of in-use items in this category.
        public let active: Int
        /// Bytes that pruning this category would reclaim.
        public let reclaimable: Int
        /// Total on-disk size in bytes.
        public let sizeInBytes: Int
        /// Total number of items in this category.
        public let total: Int

        public init(active: Int, reclaimable: Int, sizeInBytes: Int, total: Int) {
            self.active = active
            self.reclaimable = reclaimable
            self.sizeInBytes = sizeInBytes
            self.total = total
        }

        /// `sizeInBytes` as a human-readable, file-style byte count.
        public var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: Int64(sizeInBytes), countStyle: .file)
        }

        /// `reclaimable` as a human-readable, file-style byte count.
        public var reclaimableDescription: String {
            ByteCountFormatter.string(fromByteCount: Int64(reclaimable), countStyle: .file)
        }
    }
}
