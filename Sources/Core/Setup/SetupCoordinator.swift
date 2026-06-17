import Foundation

/// Drives the app's launch-time readiness check (the M3 subset of setup):
/// resolves the `container` binary and the daemon status, mapping the result to
/// a `SetupState` the UI gates on. It performs NO downloading or installing —
/// that is a later milestone. The only remediation it can trigger is asking the
/// daemon to start (via the injected `ContainerService.startDaemon`, which the
/// view layer calls before re-running `check()`).
@MainActor
@Observable
public final class SetupCoordinator {
    /// The outcome of a readiness check. Drives which setup UI is shown; only
    /// `.ready` lets the normal app shell through.
    public enum SetupState: Equatable, Sendable {
        /// A check is in flight (initial state).
        case checking
        /// The `container` binary could not be located — show install guidance.
        case missingBinary
        /// The binary is present but the daemon is not running — offer to start it.
        case daemonStopped
        /// Auto-setup is downloading the installer `.pkg`; carries fractional
        /// progress in `0.0...1.0`.
        case downloading(Double)
        /// The downloaded `.pkg` is verified and being installed (the admin
        /// authorization prompt may be on screen).
        case installing
        /// The runtime is installed and the daemon is being started.
        case startingDaemon
        /// Binary present and daemon running — proceed to the app.
        case ready
        /// The check itself errored (e.g. status query threw); carries a message.
        case failed(String)
    }

    /// The current readiness state. Observed by `SetupView`.
    public private(set) var state: SetupState = .checking

    private let service: any ContainerService
    private let cli: ContainerCLI
    private let installer: (any Installer)?

    public init(service: any ContainerService, cli: ContainerCLI, installer: (any Installer)? = nil) {
        self.service = service
        self.cli = cli
        self.installer = installer
    }

    /// Resolve the binary path and daemon status, mapping to a `SetupState`.
    ///
    /// - No binary → `.missingBinary` (daemon is not even queried).
    /// - Binary present, daemon running → `.ready`.
    /// - Binary present, daemon stopped/unknown → `.daemonStopped`.
    /// - Status query throws → `.failed(message)`.
    public func check() async {
        state = .checking

        guard await cli.resolveBinaryPath() != nil else {
            state = .missingBinary
            return
        }

        do {
            let status = try await service.daemonStatus()
            state = status.state == .running ? .ready : .daemonStopped
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// Ask the daemon to start, then re-run `check()`. Surfaces any start error
    /// through the subsequent `check()` (which re-queries status).
    public func startDaemonAndRecheck() async {
        state = .checking
        do {
            try await service.startDaemon()
        } catch {
            state = .failed(String(describing: error))
            return
        }
        await check()
    }

    /// Full-auto install path: resolve the latest installer `.pkg`, download it
    /// (streaming progress into `.downloading`), verify its signature against
    /// the pinned Apple Team ID, install it (`.installing`), start the daemon
    /// (`.startingDaemon`), then re-`check()` to reach `.ready`.
    ///
    /// Any failure short-circuits to `.failed(message)`. A no-op (stays
    /// `.failed`) when no `Installer` was injected.
    public func runAutoSetup() async {
        guard let installer else {
            state = .failed("No installer available.")
            return
        }
        do {
            // 1. Resolve the latest signed pkg URL + expected digest.
            let (url, digest) = try await installer.latestPkgURL()

            // 2. Download, streaming progress and capturing the temp file URL.
            state = .downloading(0)
            var pkgURL: URL?
            for try await event in installer.download(url, expectedDigest: digest) {
                switch event {
                case .progress(let fraction):
                    state = .downloading(fraction)
                case .finished(let location):
                    pkgURL = location
                }
            }
            guard let pkgURL else {
                state = .failed("Download did not produce a file.")
                return
            }

            // 3. Verify signature + notarization against the pinned Team ID.
            try await installer.verifySignature(at: pkgURL, expectedTeamID: GitHubInstaller.appleTeamID)

            // 4. Install (admin prompt).
            state = .installing
            try await installer.installPkg(at: pkgURL)

            // 5. Start the daemon, then re-check to confirm readiness.
            state = .startingDaemon
            try await service.startDaemon()
            await check()
        } catch {
            state = .failed(String(describing: error))
        }
    }

    #if ENABLE_PREVIEWS
    /// Preview-only seam: builds a coordinator already pinned to `state` so
    /// SwiftUI previews can render a specific `SetupState` without driving the
    /// real `check()` / `runAutoSetup()` flow. Compiled out of production
    /// builds; not part of the shipping API.
    @MainActor
    public static func previewPinned(
        _ state: SetupState,
        service: any ContainerService,
        cli: ContainerCLI
    ) -> SetupCoordinator {
        let coordinator = SetupCoordinator(service: service, cli: cli)
        coordinator.state = state
        return coordinator
    }
    #endif
}
