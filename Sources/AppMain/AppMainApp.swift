import SwiftUI
import AppKit
import Core

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure the app activates and shows its window when launched from a
        // bundled `.app`. A bare SwiftPM executable defaults to no activation
        // policy, which suppresses the window/menu bar.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct AppMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// View models composed once at launch over a single real service. Held as
    /// `@State` so the same instances survive scene/view re-creation.
    @State private var containersViewModel: ContainersViewModel
    @State private var imagesViewModel: ImagesViewModel
    @State private var volumesViewModel: VolumesViewModel
    @State private var appViewModel: AppViewModel
    @State private var logsViewModel: LogsViewModel
    @State private var buildViewModel: BuildViewModel
    @State private var activityMonitorViewModel: ActivityMonitorViewModel

    /// Drives the launch-time setup gate (binary + daemon readiness). Owned here
    /// so its `check()` Task and state survive scene/view re-creation.
    @State private var setupCoordinator: SetupCoordinator

    /// The shared service, threaded to the terminal tab so it can resolve the
    /// `container exec` invocation from Core rather than hand-building argv.
    private let service: any ContainerService

    init() {
        // Compose dependency injection once: a real CLI-backed service over a
        // process runner. `ContainerCLI` auto-discovers the binary (no override),
        // so this works wherever `container` is installed — and degrades to
        // empty states (never crashes) when it is not.
        let runner = ProcessCommandRunner()
        let cli = ContainerCLI(runner: runner, overridePath: nil)
        let service = CLIContainerService(runner: runner, cli: cli)
        _containersViewModel = State(initialValue: ContainersViewModel(service: service))
        _imagesViewModel = State(initialValue: ImagesViewModel(service: service))
        _volumesViewModel = State(initialValue: VolumesViewModel(service: service))
        _appViewModel = State(initialValue: AppViewModel(service: service))
        _logsViewModel = State(initialValue: LogsViewModel(service: service))
        _buildViewModel = State(initialValue: BuildViewModel(service: service))
        _activityMonitorViewModel = State(initialValue: ActivityMonitorViewModel(service: service))
        _setupCoordinator = State(initialValue: SetupCoordinator(service: service, cli: cli))
        self.service = service
    }

    var body: some Scene {
        WindowGroup {
            RootGateView(
                setupCoordinator: setupCoordinator,
                containersViewModel: containersViewModel,
                imagesViewModel: imagesViewModel,
                volumesViewModel: volumesViewModel,
                appViewModel: appViewModel,
                logsViewModel: logsViewModel,
                buildViewModel: buildViewModel,
                activityMonitorViewModel: activityMonitorViewModel,
                service: service
            )
        }

        MenuBarExtra {
            MenuBarContent(appViewModel: appViewModel)
        } label: {
            // Green dot when the daemon is running, gray otherwise. Driven by
            // the observed `AppViewModel.daemonStatus`.
            Image(systemName: appViewModel.isReady
                ? "circle.fill"
                : "circle")
                .foregroundStyle(appViewModel.isReady ? Color.green : Color.gray)
        }
    }
}

/// The menu shown by the `MenuBarExtra`: daemon status text and a Start Service
/// action. Binds only to the already-tested `AppViewModel`.
///
/// Note: the `ContainerService` protocol (and `AppViewModel`) expose
/// `startDaemon()` but no stop-daemon control, so only "Start Service" is wired.
@MainActor
private struct MenuBarContent: View {
    @Bindable var appViewModel: AppViewModel

    var body: some View {
        Text(statusText)

        Divider()

        Button("Start Service") {
            Task { await appViewModel.startDaemon() }
        }
        .disabled(appViewModel.isReady)

        Button("Refresh Status") {
            Task { await appViewModel.refreshDaemonStatus() }
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        switch appViewModel.daemonStatus.state {
        case .running: return "Service: Running"
        case .stopped: return "Service: Stopped"
        case .unknown: return "Service: Unknown"
        }
    }
}

/// The window's root: runs the setup readiness check at launch and shows
/// `SetupView` until the runtime is `.ready`, then swaps in the normal
/// `RootView`. Holds no business logic — it observes `SetupCoordinator.state`
/// and forwards the already-tested view models to `RootView`.
@MainActor
private struct RootGateView: View {
    @Bindable var setupCoordinator: SetupCoordinator
    @Bindable var containersViewModel: ContainersViewModel
    @Bindable var imagesViewModel: ImagesViewModel
    @Bindable var volumesViewModel: VolumesViewModel
    @Bindable var appViewModel: AppViewModel
    @Bindable var logsViewModel: LogsViewModel
    @Bindable var buildViewModel: BuildViewModel
    @Bindable var activityMonitorViewModel: ActivityMonitorViewModel
    let service: any ContainerService

    var body: some View {
        Group {
            if setupCoordinator.state == .ready {
                RootView(
                    containersViewModel: containersViewModel,
                    imagesViewModel: imagesViewModel,
                    volumesViewModel: volumesViewModel,
                    appViewModel: appViewModel,
                    logsViewModel: logsViewModel,
                    buildViewModel: buildViewModel,
                    activityMonitorViewModel: activityMonitorViewModel,
                    service: service
                )
            } else {
                SetupView(coordinator: setupCoordinator)
            }
        }
        .task {
            // Resolve binary + daemon at launch. Safe when neither is present:
            // the coordinator maps to .missingBinary / .daemonStopped and the
            // app never touches Process directly.
            await setupCoordinator.check()
        }
    }
}
