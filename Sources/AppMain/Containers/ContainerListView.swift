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

    /// App preferences. Drives whether destructive actions confirm first and
    /// seeds the Run sheet's CPU/memory defaults.
    var settings: AppSettings?

    /// Selected container id, owned by `RootView` so its detail column can show
    /// the matching `ContainerDetailView`.
    @Binding var selectedID: Container.ID?

    /// Whether the Run Container sheet is presented.
    @State private var isPresentingRun = false

    /// Whether the "Prune Stopped" confirmation dialog is presented.
    @State private var isConfirmingPrune = false

    /// Whether the "Delete All" confirmation dialog is presented.
    @State private var isConfirmingDeleteAll = false

    /// Search text; filters the list by container name (id) or image reference,
    /// case-insensitive. Empty means no name/image filtering. View-local — pure
    /// presentation, no Core change.
    @State private var searchText = ""

    /// Which containers to show: only running, or all (running + stopped). The
    /// view model already lists `--all`; this filters client-side.
    @State private var scope: ListScope = .all

    /// How to order the visible containers.
    @State private var sortOrder: ListSort = .name

    /// How often to poll the runtime while this view is on screen.
    private let pollInterval: Duration = .seconds(3)

    /// Visibility filter applied client-side over `viewModel.containers`.
    private enum ListScope: String, CaseIterable, Identifiable {
        case running = "Running"
        case all = "All"
        var id: Self { self }
    }

    /// Sort key for the visible containers.
    private enum ListSort: String, CaseIterable, Identifiable {
        case name = "Name"
        case state = "State"
        case created = "Created"
        var id: Self { self }
        var label: String { "Sort by \(rawValue)" }
    }

    /// `viewModel.containers` after applying the scope toggle, the search text
    /// and the chosen sort order. Pure presentation: derives a new array, never
    /// mutates the model. Recomputed on each render from observed state.
    private var visibleContainers: [Container] {
        let scoped = viewModel.containers.filter { container in
            scope == .all || container.state == .running
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? scoped
            : scoped.filter { container in
                container.id.localizedCaseInsensitiveContains(query)
                    || container.imageReference.localizedCaseInsensitiveContains(query)
            }
        return filtered.sorted(by: ordering)
    }

    /// Comparator for `sortOrder`. Name and image use a localized,
    /// case-insensitive compare; state groups Running first then Stopped/Unknown;
    /// created sorts newest first by the runtime's `startedDate` string
    /// (ISO8601 sorts correctly lexically; missing dates sort last).
    private func ordering(_ a: Container, _ b: Container) -> Bool {
        switch sortOrder {
        case .name:
            return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
        case .state:
            let rankA = stateRank(a.state), rankB = stateRank(b.state)
            if rankA != rankB { return rankA < rankB }
            return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
        case .created:
            let dateA = a.status.startedDate ?? ""
            let dateB = b.status.startedDate ?? ""
            if dateA != dateB { return dateA > dateB }
            return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
        }
    }

    /// Whether destructive actions confirm first. Defaults to true when no
    /// settings store is injected (previews), matching the store's own default.
    private var confirmBeforeDelete: Bool {
        settings?.confirmBeforeDelete ?? true
    }

    /// Sort rank for `.state`: Running before everything else.
    private func stateRank(_ state: RunState) -> Int {
        switch state {
        case .running: return 0
        case .stopped: return 1
        case .unknown: return 2
        }
    }

    var body: some View {
        content
            .navigationTitle("Containers")
            .frame(minWidth: 280)
            .searchable(text: $searchText, placement: .automatic, prompt: "Filter by name or image")
            .toolbar {
                ToolbarItem {
                    Picker("Show", selection: $scope) {
                        ForEach(ListScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(ListSort.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
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
                    Button(role: .destructive) {
                        if confirmBeforeDelete {
                            isConfirmingDeleteAll = true
                        } else {
                            Task { await viewModel.deleteAll() }
                        }
                    } label: {
                        Label("Delete All", systemImage: "trash")
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
            .confirmationDialog(
                "Delete all containers?",
                isPresented: $isConfirmingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    Task { await viewModel.deleteAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This force-deletes every container, including running ones. This cannot be undone.")
            }
            .sheet(isPresented: $isPresentingRun) {
                RunContainerView(
                    viewModel: viewModel,
                    imagesViewModel: imagesViewModel,
                    settings: settings
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
        } else if visibleContainers.isEmpty {
            noMatchesState
        } else {
            List(selection: $selectedID) {
                let running = visibleContainers.filter { $0.state == .running }
                let stopped = visibleContainers.filter { $0.state != .running }

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

    /// Shown when there *are* containers but the current search/scope hides them
    /// all — distinct from the no-containers state so the user knows the filter,
    /// not the runtime, is responsible.
    private var noMatchesState: some View {
        ContentUnavailableView(
            "No Matches",
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text(
                searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No containers match the current filter."
                    : "No containers match “\(searchText)”."
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

    /// Signals exposed by the Kill submenu, matching the `container` CLI's
    /// accepted `-s` values. View-local presentation only.
    private static let killSignals = ["KILL", "TERM", "HUP", "INT", "USR1"]

    @ViewBuilder
    private func actions(for container: Container) -> some View {
        if container.state == .running {
            Button {
                Task { await viewModel.stop(container.id) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            Menu {
                ForEach(Self.killSignals, id: \.self) { signal in
                    Button(role: .destructive) {
                        Task { await viewModel.kill(container.id, signal: signal) }
                    } label: {
                        Text("SIG\(signal)")
                    }
                }
            } label: {
                Label("Kill", systemImage: "bolt.fill")
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
            Button(role: .destructive) {
                Task { await viewModel.remove(container.id, force: true) }
            } label: {
                Label("Force Delete", systemImage: "trash.fill")
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
