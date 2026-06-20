import SwiftUI
import Core

/// The sidebar sections of the app. `Identifiable` + `CaseIterable` so the
/// sidebar `List` can enumerate them; each carries an SF Symbol + label.
enum SidebarSection: String, Identifiable, CaseIterable {
    case activityMonitor
    case containers
    case images
    case volumes
    case networks
    case build
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .activityMonitor: return "Activity Monitor"
        case .containers: return "Containers"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .build: return "Build"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .activityMonitor: return "chart.line.uptrend.xyaxis"
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .build: return "hammer"
        case .settings: return "gearshape"
        }
    }
}

/// A titled group of sidebar sections, so the sidebar `List` can render a
/// `Section("General")` header above the general entries and a `Section`
/// grouping the resource (Containers / Images / Build / Settings) entries.
enum SidebarGroup: String, Identifiable, CaseIterable {
    case general = "General"
    case resources = "Resources"

    var id: String { rawValue }

    var sections: [SidebarSection] {
        switch self {
        case .general: return [.activityMonitor]
        case .resources: return [.containers, .images, .volumes, .networks, .build, .settings]
        }
    }
}

/// The app's root window content and the app's single `NavigationSplitView`
/// host. It is a three-column split: a sidebar enumerating `SidebarSection`s,
/// a content column showing the selected section's view, and a detail column
/// showing the selected container's details (for the Containers section).
///
/// Owning the only `NavigationSplitView` keeps navigation flat — section views
/// (e.g. `ContainerListView`) render *into* this split's columns rather than
/// nesting their own. Holds no business logic — it binds to the injected,
/// already unit-tested view models.
@MainActor
struct RootView: View {
    /// View model driving the containers section. Injected from the app so the
    /// same instance survives view re-creation.
    @Bindable var containersViewModel: ContainersViewModel

    /// View model supplying local images to the Run form's image picker.
    @Bindable var imagesViewModel: ImagesViewModel

    /// View model driving the Volumes section.
    @Bindable var volumesViewModel: VolumesViewModel

    /// View model driving the Networks section.
    @Bindable var networksViewModel: NetworksViewModel

    /// App-level daemon state (also surfaced in the menu bar).
    @Bindable var appViewModel: AppViewModel

    /// Service-backed view model driving the live log stream. Owned here so the
    /// streaming `Task` survives while the detail's Logs tab is shown.
    @Bindable var logsViewModel: LogsViewModel

    /// View model driving the Build section's build stream. Owned here so its
    /// streaming `Task` survives while the section is shown.
    @Bindable var buildViewModel: BuildViewModel

    /// View model driving the Activity Monitor section's stats polling. Owned
    /// here so its poll `Task` is created once and survives view re-creation.
    @Bindable var activityMonitorViewModel: ActivityMonitorViewModel

    /// Shared service, forwarded to the detail's Terminal tab so it can resolve
    /// the `container exec` invocation from Core.
    let service: any ContainerService

    @State private var selection: SidebarSection? = .containers

    /// Selected container id, driving the detail column for the Containers
    /// section. Owned here so the single split's detail column can resolve it.
    @State private var selectedContainerID: Container.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SidebarGroup.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(group.sections) { section in
                            Label(section.label, systemImage: section.systemImage)
                                .tag(section)
                        }
                    }
                }
            }
            .navigationTitle("Apple Container GUI")
            .frame(minWidth: 180)
        } detail: {
            sectionView(for: selection)
                .frame(minWidth: 480, minHeight: 360)
        }
        .task {
            // Surface daemon status as soon as the window appears so the menu
            // bar dot and any empty states reflect reality.
            await appViewModel.refreshDaemonStatus()
        }
    }

    /// The selected section's full-width view. Single-pane sections (Activity
    /// Monitor, Images, Build, Settings) fill the detail area with no trailing
    /// "No Selection" panel; only Containers is master-detail, and it splits
    /// *internally* (see `containersSection`) rather than via an app-level third
    /// column.
    @ViewBuilder
    private func sectionView(for section: SidebarSection?) -> some View {
        switch section {
        case .activityMonitor:
            ActivityMonitorView(viewModel: activityMonitorViewModel)
        case .containers:
            containersSection
        case .images:
            ImageListView(viewModel: imagesViewModel)
        case .volumes:
            VolumeListView(viewModel: volumesViewModel)
        case .networks:
            NetworkListView(viewModel: networksViewModel)
        case .build:
            BuildView(
                viewModel: buildViewModel,
                containersViewModel: containersViewModel,
                imagesViewModel: imagesViewModel
            )
        case .settings:
            ContentUnavailableView(
                "Settings",
                systemImage: SidebarSection.settings.systemImage,
                description: Text("Settings arrive in a later milestone.")
            )
        case nil:
            ContentUnavailableView(
                "Select a section",
                systemImage: "sidebar.left"
            )
        }
    }

    /// Containers is the only master-detail section: a list on the left and the
    /// selected container's details on the right, split *within* the section
    /// (an `HSplitView`, not a nested `NavigationSplitView`).
    private var containersSection: some View {
        HSplitView {
            ContainerListView(
                viewModel: containersViewModel,
                imagesViewModel: imagesViewModel,
                selectedID: $selectedContainerID
            )
            .frame(minWidth: 280, idealWidth: 340)

            Group {
                if let container = selectedContainer {
                    ContainerDetailView(container: container, logsViewModel: logsViewModel, service: service)
                } else {
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "sidebar.right",
                        description: Text("Select a container to see its details.")
                    )
                }
            }
            .frame(minWidth: 360)
        }
    }

    /// The currently selected container resolved from the live list, or nil if
    /// nothing is selected or the selection has since disappeared.
    private var selectedContainer: Container? {
        guard let selectedContainerID else { return nil }
        return containersViewModel.containers.first { $0.id == selectedContainerID }
    }
}

// MARK: - Preview

/// A `ContainerService` that returns nothing and never crashes — lets the
/// preview render without a live daemon or the real `container` binary.
private struct PreviewEmptyService: ContainerService {
    func listContainers() async throws -> [Container] { [] }
    func start(_ id: String) async throws {}
    func stop(_ id: String) async throws {}
    func remove(_ id: String) async throws {}
    func run(_ spec: RunSpec) async throws -> String { "preview-id" }
    func pruneContainers() async throws {}
    func exportContainer(_ id: String, to path: String) async throws {}
    func stats(_ ids: [String]) async throws -> [ContainerStats] { [] }
    func listImages() async throws -> [ContainerImage] { [] }
    func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func removeImage(_ id: String) async throws {}
    func pruneImages() async throws {}
    func tagImage(source: String, newRef: String) async throws {}
    func pushImage(_ ref: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func listVolumes() async throws -> [ContainerVolume] { [] }
    func createVolume(name: String, size: String?, labels: [String: String]) async throws {}
    func removeVolume(_ name: String) async throws {}
    func pruneVolumes() async throws {}
    func listNetworks() async throws -> [ContainerNetwork] { [] }
    func createNetwork(name: String, internal isInternal: Bool, subnet: String?, labels: [String: String]) async throws {}
    func removeNetwork(_ name: String) async throws {}
    func logs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func daemonStatus() async throws -> DaemonStatus {
        DaemonStatus(state: .stopped, appRoot: nil, installRoot: nil)
    }
    func startDaemon() async throws {}
    func build(dockerfile: String, context: String, tag: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// The `#Preview` macro requires the `PreviewsMacros` plugin, which only ships
// with full Xcode — not the Command Line Tools `swift build` used as this
// project's compile gate. It is therefore gated behind the `ENABLE_PREVIEWS`
// flag (off for CLT builds, set it in Xcode) so the canvas preview is available
// to developers while `swift build` stays green. The `PreviewEmptyService`
// above guarantees the preview renders with no live daemon.
#if ENABLE_PREVIEWS
#Preview {
    let service = PreviewEmptyService()
    return RootView(
        containersViewModel: ContainersViewModel(service: service),
        imagesViewModel: ImagesViewModel(service: service),
        volumesViewModel: VolumesViewModel(service: service),
        networksViewModel: NetworksViewModel(service: service),
        appViewModel: AppViewModel(service: service),
        logsViewModel: LogsViewModel(service: service),
        buildViewModel: BuildViewModel(service: service),
        activityMonitorViewModel: ActivityMonitorViewModel(service: service),
        service: service
    )
}
#endif
