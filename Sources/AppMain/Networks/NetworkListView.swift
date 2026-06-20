import SwiftUI
import Core

/// The Networks section's list (content) column, bound to `NetworksViewModel`.
///
/// This is a *content* column of `RootView`'s single three-column
/// `NavigationSplitView` — it introduces no `NavigationSplitView` of its own.
/// It observes the already-unit-tested view model, renders one row per network
/// (name, mode, subnet, gateway), exposes a Delete action (swipe + context
/// menu) calling `vm.remove` — disabled for the builtin `default` network so it
/// can never be removed — and presents a `CreateNetworkView` sheet from a
/// toolbar "+" button. Refreshes on appear. Degrades to a calm empty /
/// unavailable state when the runtime is down — it never force-unwraps and
/// never crashes.
@MainActor
struct NetworkListView: View {
    @Bindable var viewModel: NetworksViewModel

    /// Whether the Create Network sheet is presented.
    @State private var isPresentingCreate = false

    /// The builtin network that ships with the runtime; deleting it is
    /// prevented (its Delete action is disabled/greyed).
    private static let builtinNetworkName = "default"

    var body: some View {
        content
            .navigationTitle("Networks")
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
                        isPresentingCreate = true
                    } label: {
                        Label("Create Network", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingCreate) {
                CreateNetworkView(viewModel: viewModel)
            }
            // Refresh both when the view first appears AND whenever it reappears
            // after a section switch. `.task` alone proved unreliable inside the
            // split's detail column, so `.onAppear` backs it up.
            .task { await viewModel.refresh() }
            .onAppear { Task { await viewModel.refresh() } }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.networks.isEmpty {
            emptyState
        } else {
            List {
                ForEach(viewModel.networks) { row(for: $0) }
            }
        }
    }

    /// Empty state. When the last refresh failed we say the runtime is
    /// unavailable; otherwise there are simply no networks. Neither path crashes
    /// when `container` is missing or the daemon is down.
    private var emptyState: some View {
        ContentUnavailableView(
            viewModel.lastError == nil ? "No Networks" : "Container Runtime Unavailable",
            systemImage: "network",
            description: Text(
                viewModel.lastError == nil
                    ? "Create a network to get started."
                    : "Could not reach the container runtime. Make sure the service is running."
            )
        )
    }

    @ViewBuilder
    private func row(for network: ContainerNetwork) -> some View {
        let isBuiltin = network.name == Self.builtinNetworkName
        NetworkListRow(network: network)
            .contextMenu {
                Button(role: .destructive) {
                    Task { await viewModel.remove(network.name) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isBuiltin)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    Task { await viewModel.remove(network.name) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isBuiltin)
            }
    }
}

/// A single network row: the name as the headline, the mode as a quiet caption,
/// and the subnet CIDR + gateway trailing (when the runtime reports them).
@MainActor
struct NetworkListRow: View {
    let network: ContainerNetwork

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(network.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(network.configuration.mode)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if !network.subnet.isEmpty {
                    Text(network.subnet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if !network.gateway.isEmpty {
                    Text(network.gateway)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

// The `#Preview` macro requires the `PreviewsMacros` plugin that only ships with
// full Xcode, not the Command Line Tools `swift build` compile gate. It is gated
// behind `ENABLE_PREVIEWS` (off for CLT builds; set it in Xcode) so the canvas
// preview is available to developers while `swift build` stays green. The
// fixture-backed service guarantees the preview renders with no live daemon.
#if ENABLE_PREVIEWS
#Preview("Networks - populated") {
    NavigationStack {
        NetworkListView(viewModel: NetworksViewModel(service: NetworkPreviewData.populatedService))
    }
}

#Preview("Networks - empty") {
    NavigationStack {
        NetworkListView(viewModel: NetworksViewModel(service: NetworkPreviewData.emptyService))
    }
}
#endif
