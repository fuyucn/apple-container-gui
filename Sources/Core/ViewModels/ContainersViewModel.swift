import Foundation

/// Drives the containers list UI: holds the current `[Container]`, refreshes it
/// from the `ContainerService`, performs lifecycle actions (start/stop/remove)
/// and supports background polling.
///
/// `@MainActor @Observable` so SwiftUI views observe `containers` directly.
/// Depends only on the `ContainerService` protocol so it is fully unit-testable
/// against a mock.
@MainActor
@Observable
public final class ContainersViewModel {
    /// Containers as of the last refresh (running and stopped).
    public private(set) var containers: [Container] = []

    /// The most recent error surfaced by a refresh or action, if any.
    public private(set) var lastError: String?

    private let service: any ContainerService

    /// The running poll loop, if polling is active. Stored so it can be
    /// cancelled — a fire-and-forget `Task {}` cannot be stopped.
    private var pollTask: Task<Void, Never>?

    public init(service: any ContainerService) {
        self.service = service
    }

    /// Re-read the container list from the service. Errors are captured into
    /// `lastError` rather than thrown so polling never crashes the loop.
    public func refresh() async {
        do {
            containers = try await service.listContainers()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Start a container, then refresh so the UI reflects the new state.
    public func start(_ id: String) async {
        await perform { try await self.service.start(id) }
    }

    /// Gracefully stop a container, then refresh. Optionally pass a `signal`
    /// (`-s`) and a `timeout` in seconds (`-t`); both default to nil so
    /// `stop(id)` keeps the runtime's default graceful behavior.
    public func stop(_ id: String, signal: String? = nil, timeout: Int? = nil) async {
        await perform { try await self.service.stop(id, signal: signal, timeout: timeout) }
    }

    /// Forcibly signal a container (`kill`), then refresh. Optionally pass a
    /// `signal` (`-s`); nil uses the runtime's default kill signal.
    public func kill(_ id: String, signal: String? = nil) async {
        await perform { try await self.service.kill(id, signal: signal) }
    }

    /// Remove a container, then refresh. When `stopFirst` is true (a running
    /// container), gracefully `stop` it before deleting — a plain delete fails
    /// on a running container, and stopping first lets it shut down cleanly
    /// (SIGTERM with a grace period) rather than being force-killed. When
    /// `force` is true, skip the graceful stop and pass `-f` to the runtime so
    /// it removes a running container outright; `force` takes precedence over
    /// `stopFirst`.
    public func remove(_ id: String, stopFirst: Bool = false, force: Bool = false) async {
        await perform {
            if force {
                try await self.service.remove(id, force: true)
            } else {
                if stopFirst { try await self.service.stop(id) }
                try await self.service.remove(id)
            }
        }
    }

    /// Delete all containers (running and stopped) via `delete --all`, then
    /// refresh.
    public func deleteAll() async {
        await perform { try await self.service.deleteAll() }
    }

    /// Create and run a new container from `spec`, then refresh so the UI shows
    /// it. Errors are captured into `lastError` rather than thrown.
    public func run(_ spec: RunSpec) async {
        await perform { _ = try await self.service.run(spec) }
    }

    /// Remove all stopped containers (`prune`), then refresh.
    public func prune() async {
        await perform { try await self.service.pruneContainers() }
    }

    /// Export a container's filesystem to a tar archive at `path`. Does not
    /// refresh the list (an export does not change container state); errors are
    /// captured into `lastError`.
    public func export(id: String, to path: String) async {
        do {
            try await service.exportContainer(id, to: path)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    /// Begin polling: refresh now and every `interval` until stopped. Cancels
    /// any existing poll loop first so there is never more than one running.
    public func startPolling(interval: Duration) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                if Task.isCancelled { break }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stop polling and release the task.
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
