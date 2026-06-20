import Foundation

/// Drives the volumes list UI: holds the current `[ContainerVolume]`, refreshes
/// it, creates volumes, removes them, and prunes unused volumes.
@MainActor
@Observable
public final class VolumesViewModel {
    /// Volumes as of the last refresh.
    public private(set) var volumes: [ContainerVolume] = []

    /// The most recent error surfaced by a refresh or action.
    public private(set) var lastError: String?

    private let service: any ContainerService

    public init(service: any ContainerService) {
        self.service = service
    }

    /// Re-read the volume list from the service.
    public func refresh() async {
        do {
            volumes = try await service.listVolumes()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Create a volume, then refresh.
    public func create(name: String, size: String?, labels: [String: String]) async {
        do {
            try await service.createVolume(name: name, size: size, labels: labels)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    /// Remove a volume, then refresh.
    public func remove(_ name: String) async {
        do {
            try await service.removeVolume(name)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    /// Prune unused volumes, then refresh.
    public func prune() async {
        do {
            try await service.pruneVolumes()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }
}
