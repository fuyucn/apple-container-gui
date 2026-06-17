import Foundation

/// Top-level app state: holds the current `DaemonStatus` and gates the rest of
/// the UI on the daemon being ready. Can start the daemon.
///
/// (Full onboarding/install flow is owned by `SetupCoordinator`; this view model
/// is the lightweight runtime daemon gate the app shell binds to.)
@MainActor
@Observable
public final class AppViewModel {
    /// Latest daemon status. Starts `.unknown` until the first refresh.
    public private(set) var daemonStatus: DaemonStatus

    /// The most recent error surfaced by a status check or start, if any.
    public private(set) var lastError: String?

    private let service: any ContainerService

    public init(service: any ContainerService) {
        self.service = service
        self.daemonStatus = DaemonStatus(state: .unknown, appRoot: nil, installRoot: nil)
    }

    /// True when the daemon is running and the main UI can be shown.
    public var isReady: Bool { daemonStatus.state == .running }

    /// Re-read the daemon status from the service.
    public func refreshDaemonStatus() async {
        do {
            daemonStatus = try await service.daemonStatus()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Start the daemon, then refresh the status.
    public func startDaemon() async {
        do {
            try await service.startDaemon()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        await refreshDaemonStatus()
    }
}
