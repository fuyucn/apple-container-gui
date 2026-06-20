import SwiftUI
import UniformTypeIdentifiers
import Core

/// The Containers section's list (content) column, bound to `ContainersViewModel`.
///
/// This is the *content* column of `RootView`'s single three-column
/// `NavigationSplitView` — it introduces no `NavigationSplitView` of its own.
/// It observes the already-unit-tested view model, renders Running/Stopped
/// sections, exposes lifecycle actions (Start/Stop/Delete) that call the view
/// model, and drives the selected container id (a binding owned by `RootView`,
/// which renders the detail column). Degrades to a calm empty / unavailable
/// state when the runtime is down — it never force-unwraps and never crashes.
@MainActor
struct ContainerListView: View {
    @Bindable var viewModel: ContainersViewModel

    /// Optional source of local images for the Run form's image picker. Passed
    /// through to `RunContainerView`; the list itself never reads it.
    var imagesViewModel: ImagesViewModel?

    /// Selected container id, owned by `RootView` so its detail column can show
    /// the matching `ContainerDetailView`.
    @Binding var selectedID: Container.ID?

    /// Whether the Run Container sheet is presented.
    @State private var isPresentingRun = false

    /// Whether the "Prune Stopped" confirmation dialog is presented.
    @State private var isConfirmingPrune = false

    /// How often to poll the runtime while this view is on screen.
    private let pollInterval: Duration = .seconds(3)

    var body: some View {
        content
            .navigationTitle("Containers")
            .frame(minWidth: 280)
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItem {
                    Button {
                        isConfirmingPrune = true
                    } label: {
                        Label("Prune Stopped", systemImage: "trash.slash")
                    }
                }
                ToolbarItem {
                    Button {
                        isPresentingRun = true
                    } label: {
                        Label("Run Container", systemImage: "plus")
                    }
                }
            }
            .confirmationDialog(
                "Remove all stopped containers?",
                isPresented: $isConfirmingPrune,
                titleVisibility: .visible
            ) {
                Button("Prune Stopped", role: .destructive) {
                    Task { await viewModel.prune() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every container that is not running. This cannot be undone.")
            }
            .sheet(isPresented: $isPresentingRun) {
                RunContainerView(
                    viewModel: viewModel,
                    imagesViewModel: imagesViewModel
                )
            }
            .task {
                // Refresh immediately, then poll while visible.
                await viewModel.refresh()
                viewModel.startPolling(interval: pollInterval)
            }
            .onDisappear {
                viewModel.stopPolling()
            }
    }

    /// Present an `NSSavePanel` to choose a `.tar` destination, then export the
    /// container's filesystem there via the view model. The panel runs on the
    /// main actor; the only logic (the CLI invocation) lives in the VM.
    private func presentExportPanel(for container: Container) {
        let panel = NSSavePanel()
        panel.title = "Export Container Filesystem"
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        panel.nameFieldStringValue = "\(container.id).tar"
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.export(id: container.id, to: url.path) }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.containers.isEmpty {
            emptyState
        } else {
            List(selection: $selectedID) {
                let running = viewModel.containers.filter { $0.state == .running }
                let stopped = viewModel.containers.filter { $0.state != .running }

                if !running.isEmpty {
                    Section("Running") {
                        ForEach(running) { row(for: $0) }
                    }
                }
                if !stopped.isEmpty {
                    Section("Stopped") {
                        ForEach(stopped) { row(for: $0) }
                    }
                }
            }
        }
    }

    /// Empty state. When the last refresh failed we say the runtime is
    /// unavailable; otherwise there are simply no containers. Neither path
    /// crashes when `container` is missing or the daemon is down.
    private var emptyState: some View {
        ContentUnavailableView(
            viewModel.lastError == nil ? "No Containers" : "Container Runtime Unavailable",
            systemImage: "shippingbox",
            description: Text(
                viewModel.lastError == nil
                    ? "No containers to show yet."
                    : "Could not reach the container runtime. Make sure the service is running."
            )
        )
    }

    @ViewBuilder
    private func row(for container: Container) -> some View {
        ContainerRow(container: container)
            .tag(container.id)
            .contextMenu { actions(for: container) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                swipeActions(for: container)
            }
    }

    @ViewBuilder
    private func actions(for container: Container) -> some View {
        if container.state == .running {
            Button {
                Task { await viewModel.stop(container.id) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            Button {
                presentExportPanel(for: container)
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                Task { await viewModel.remove(container.id, stopFirst: true) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } else {
            Button {
                Task { await viewModel.start(container.id) }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            Button {
                presentExportPanel(for: container)
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                Task { await viewModel.remove(container.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func swipeActions(for container: Container) -> some View {
        if container.state == .running {
            Button {
                Task { await viewModel.stop(container.id) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .tint(.orange)
        } else {
            Button {
                Task { await viewModel.start(container.id) }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .tint(.green)
        }
        Button(role: .destructive) {
            Task { await viewModel.remove(container.id, stopFirst: container.state == .running) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// A single container row: name/id, image reference, a colored state badge and
/// the primary IPv4 if the runtime reported one.
@MainActor
struct ContainerRow: View {
    let container: Container

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(container.id)
                    .font(.headline)
                    .lineLimit(1)
                Text(container.imageReference)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let ipv4 = container.primaryIPv4 {
                    Text(ipv4)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            StateBadge(state: container.state)
        }
        .padding(.vertical, 2)
    }
}

/// A pill-shaped badge that color-codes the run state.
@MainActor
struct StateBadge: View {
    let state: RunState

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch state {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .unknown: return "Unknown"
        }
    }

    private var color: Color {
        switch state {
        case .running: return .green
        case .stopped: return .secondary
        case .unknown: return .orange
        }
    }
}

// MARK: - Preview

// The `#Preview` macro requires the `PreviewsMacros` plugin that only ships with
// full Xcode, not the Command Line Tools `swift build` compile gate. It is gated
// behind `ENABLE_PREVIEWS` (off for CLT builds; set it in Xcode) so the canvas
// preview is available to developers while `swift build` stays green. The
// fixture-backed service guarantees the preview renders with no live daemon.
#if ENABLE_PREVIEWS
#Preview("List - populated") {
    @Previewable @State var selection: Container.ID?
    NavigationStack {
        ContainerListView(
            viewModel: ContainersViewModel(service: ContainerPreviewData.populatedService),
            selectedID: $selection
        )
    }
}

#Preview("List - empty") {
    @Previewable @State var selection: Container.ID?
    NavigationStack {
        ContainerListView(
            viewModel: ContainersViewModel(service: ContainerPreviewData.emptyService),
            selectedID: $selection
        )
    }
}
#endif
