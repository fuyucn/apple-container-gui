import Foundation

/// Drives the Disk Usage panel (Docker-Desktop-style breakdown): holds the
/// latest `DiskUsage` snapshot, refreshes it from `system df`, and exposes a
/// per-category reclaim (prune) action that prunes then re-reads usage.
///
/// `@MainActor @Observable` so SwiftUI observes `usage`/`lastError` directly.
/// Degrades gracefully when the daemon is down: `refresh` clears `usage` and
/// records `lastError` rather than throwing, so the view can show an
/// unavailable state.
@MainActor
@Observable
public final class DiskUsageViewModel {
    /// The latest disk-usage snapshot, or `nil` before the first successful
    /// refresh (or after a failed one).
    public private(set) var usage: DiskUsage?

    /// The most recent error surfaced by a refresh or prune action.
    public private(set) var lastError: String?

    private let service: any ContainerService

    public init(service: any ContainerService) {
        self.service = service
    }

    /// Re-read disk usage from the service. On failure (e.g. daemon down),
    /// clears `usage` and records the error so the view degrades gracefully.
    public func refresh() async {
        do {
            usage = try await service.systemDF()
            lastError = nil
        } catch {
            usage = nil
            lastError = String(describing: error)
        }
    }

    /// Prune unused images, then refresh usage.
    public func reclaimImages() async {
        await prune { try await self.service.pruneImages() }
    }

    /// Prune stopped containers, then refresh usage.
    public func reclaimContainers() async {
        await prune { try await self.service.pruneContainers() }
    }

    /// Prune unused volumes, then refresh usage.
    public func reclaimVolumes() async {
        await prune { try await self.service.pruneVolumes() }
    }

    /// Run a prune action, recording any error, then refresh usage regardless.
    private func prune(_ action: () async throws -> Void) async {
        do {
            try await action()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }
}
