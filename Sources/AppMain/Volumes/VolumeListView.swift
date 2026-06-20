import SwiftUI
import Core

/// The Volumes section's list (content) column, bound to `VolumesViewModel`.
///
/// This is a *content* column of `RootView`'s single three-column
/// `NavigationSplitView` — it introduces no `NavigationSplitView` of its own.
/// It observes the already-unit-tested view model, renders one row per volume
/// (name, human-readable size, driver/format), exposes a Delete action (swipe +
/// context menu) calling `vm.remove`, a Prune action, and presents a
/// `CreateVolumeView` sheet from a toolbar "+" button. Refreshes on appear.
/// Degrades to a calm empty / unavailable state when the runtime is down — it
/// never force-unwraps and never crashes.
@MainActor
struct VolumeListView: View {
    @Bindable var viewModel: VolumesViewModel

    /// Whether the Create Volume sheet is presented.
    @State private var isPresentingCreate = false

    var body: some View {
        content
            .navigationTitle("Volumes")
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
                        Task { await viewModel.prune() }
                    } label: {
                        Label("Prune", systemImage: "trash.slash")
                    }
                }
                ToolbarItem {
                    Button {
                        isPresentingCreate = true
                    } label: {
                        Label("Create Volume", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingCreate) {
                CreateVolumeView(viewModel: viewModel)
            }
            // Refresh both when the view first appears AND whenever it reappears
            // after a section switch. `.task` alone proved unreliable inside the
            // split's detail column, so `.onAppear` backs it up.
            .task { await viewModel.refresh() }
            .onAppear { Task { await viewModel.refresh() } }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.volumes.isEmpty {
            emptyState
        } else {
            List {
                ForEach(viewModel.volumes) { row(for: $0) }
            }
        }
    }

    /// Empty state. When the last refresh failed we say the runtime is
    /// unavailable; otherwise there are simply no volumes. Neither path crashes
    /// when `container` is missing or the daemon is down.
    private var emptyState: some View {
        ContentUnavailableView(
            viewModel.lastError == nil ? "No Volumes" : "Container Runtime Unavailable",
            systemImage: "externaldrive",
            description: Text(
                viewModel.lastError == nil
                    ? "Create a volume to get started."
                    : "Could not reach the container runtime. Make sure the service is running."
            )
        )
    }

    @ViewBuilder
    private func row(for volume: ContainerVolume) -> some View {
        VolumeListRow(volume: volume)
            .contextMenu {
                Button(role: .destructive) {
                    Task { await viewModel.remove(volume.name) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    Task { await viewModel.remove(volume.name) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }
}

/// A single volume row: the name as the headline, the driver/format as a quiet
/// caption, and the human-readable provisioned size trailing.
@MainActor
struct VolumeListRow: View {
    let volume: ContainerVolume

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(driverFormat)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(formattedSize)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    /// The driver and on-disk format, e.g. `local · ext4`.
    private var driverFormat: String {
        let format = volume.configuration.format
        return format.isEmpty ? volume.driver : "\(volume.driver) · \(format)"
    }

    /// `sizeInBytes` rendered as a human-readable, file-style byte count.
    private var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(volume.sizeInBytes))
    }
}

// MARK: - Preview

// The `#Preview` macro requires the `PreviewsMacros` plugin that only ships with
// full Xcode, not the Command Line Tools `swift build` compile gate. It is gated
// behind `ENABLE_PREVIEWS` (off for CLT builds; set it in Xcode) so the canvas
// preview is available to developers while `swift build` stays green. The
// fixture-backed service guarantees the preview renders with no live daemon.
#if ENABLE_PREVIEWS
#Preview("Volumes - populated") {
    NavigationStack {
        VolumeListView(viewModel: VolumesViewModel(service: VolumePreviewData.populatedService))
    }
}

#Preview("Volumes - empty") {
    NavigationStack {
        VolumeListView(viewModel: VolumesViewModel(service: VolumePreviewData.emptyService))
    }
}
#endif
