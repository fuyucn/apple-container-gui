import SwiftUI
import Core

/// The sidebar sections of the app. `Identifiable` + `CaseIterable` so the
/// sidebar `List` can enumerate them; each carries an SF Symbol + label.
enum SidebarSection: String, Identifiable, CaseIterable {
    case containers
    case images
    case build
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .containers: return "Containers"
        case .images: return "Images"
        case .build: return "Build"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .build: return "hammer"
        case .settings: return "gearshape"
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

    /// App-level daemon state (also surfaced in the menu bar).
    @Bindable var appViewModel: AppViewModel

    /// Service-backed view model driving the live log stream. Owned here so the
    /// streaming `Task` survives while the detail's Logs tab is shown.
    @Bindable var logsViewModel: LogsViewModel

    /// View model driving the Build section's build stream. Owned here so its
    /// streaming `Task` survives while the section is shown.
    @Bindable var buildViewModel: BuildViewModel

    /// Shared service, forwarded to the detail's Terminal tab so it can resolve
    /// the `container exec` invocation from Core.
    let service: any ContainerService

    @State private var selection: SidebarSection? = .containers

    /// Selected container id, driving the detail column for the Containers
    /// section. Owned here so the single split's detail column can resolve it.
    @State private var selectedContainerID: Container.ID?

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Apple Container GUI")
            .frame(minWidth: 180)
        } content: {
            content(for: selection)
                .frame(minWidth: 280)
        } detail: {
            detail(for: selection)
                .frame(minWidth: 360, minHeight: 320)
        }
        .task {
            // Surface daemon status as soon as the window appears so the menu
            // bar dot and any empty states reflect reality.
            await appViewModel.refreshDaemonStatus()
        }
    }

    /// The content (middle) column: the selected section's primary view.
    @ViewBuilder
    private func content(for section: SidebarSection?) -> some View {
        switch section {
        case .containers:
            ContainerListView(
                viewModel: containersViewModel,
                imagesViewModel: imagesViewModel,
                selectedID: $selectedContainerID
            )
        case .images:
            ImageListView(viewModel: imagesViewModel)
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

    /// The detail (trailing) column. Only the Containers section drives a
    /// detail; other sections show a calm placeholder.
    @ViewBuilder
    private func detail(for section: SidebarSection?) -> some View {
        switch section {
        case .containers:
            if let container = selectedContainer {
                ContainerDetailView(container: container, logsViewModel: logsViewModel, service: service)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.right",
                    description: Text("Select a container to see its details.")
                )
            }
        default:
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.right"
            )
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
    func listImages() async throws -> [ContainerImage] { [] }
    func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func removeImage(_ id: String) async throws {}
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
        appViewModel: AppViewModel(service: service),
        logsViewModel: LogsViewModel(service: service),
        buildViewModel: BuildViewModel(service: service),
        service: service
    )
}
#endif
