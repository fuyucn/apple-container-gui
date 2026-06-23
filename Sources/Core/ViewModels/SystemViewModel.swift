import Foundation

/// Drives the System pane in Settings: daemon status + version, builder
/// lifecycle, and read-only VM resource properties.
///
/// `@MainActor @Observable` so SwiftUI observes each published property
/// directly. Degrades gracefully: a failed refresh records `lastError` and
/// leaves the corresponding snapshot nil/empty rather than throwing, so the
/// view can show an unavailable state. Lifecycle actions (builder/daemon
/// start/stop/delete) run the action, record any error, then refresh.
@MainActor
@Observable
public final class SystemViewModel {
    /// Latest daemon status, or nil before the first refresh / after a failure.
    public private(set) var daemonStatus: DaemonStatus?
    /// Component versions from `system version`, empty before refresh / on error.
    public private(set) var versions: [SystemVersion] = []
    /// Latest builder status, or nil before the first refresh / after a failure.
    public private(set) var builderStatus: BuilderStatus?
    /// Read-only VM properties, or nil before the first refresh / after failure.
    public private(set) var properties: SystemProperties?
    /// The most recent error surfaced by a refresh or lifecycle action.
    public private(set) var lastError: String?

    private let service: any ContainerService

    public init(service: any ContainerService) {
        self.service = service
    }

    /// Re-read daemon status, versions, builder status, and VM properties. Each
    /// read degrades independently: a failure clears that snapshot and records
    /// the error, but the others still populate.
    public func refresh() async {
        var firstError: String?

        do { daemonStatus = try await service.daemonStatus() }
        catch { daemonStatus = nil; firstError = firstError ?? String(describing: error) }

        do { versions = try await service.systemVersion() }
        catch { versions = []; firstError = firstError ?? String(describing: error) }

        do { builderStatus = try await service.builderStatus() }
        catch { builderStatus = nil; firstError = firstError ?? String(describing: error) }

        do { properties = try await service.systemProperties() }
        catch { properties = nil; firstError = firstError ?? String(describing: error) }

        lastError = firstError
    }

    /// Start the daemon, then refresh.
    public func startDaemon() async {
        await act { try await self.service.startDaemon() }
    }

    /// Stop the daemon, then refresh.
    public func stopDaemon() async {
        await act { try await self.service.stopDaemon() }
    }

    /// Start the builder with optional CPUs/memory, then refresh.
    public func startBuilder(cpus: Int? = nil, memory: String? = nil) async {
        await act { try await self.service.builderStart(cpus: cpus, memory: memory) }
    }

    /// Stop the builder, then refresh.
    public func stopBuilder() async {
        await act { try await self.service.builderStop() }
    }

    /// Delete the builder (force), then refresh.
    public func deleteBuilder() async {
        await act { try await self.service.builderDelete() }
    }

    /// Run a lifecycle action, recording any error, then refresh regardless.
    private func act(_ action: () async throws -> Void) async {
        do {
            try await action()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }
}
