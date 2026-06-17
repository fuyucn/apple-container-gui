import SwiftUI
import Core

/// The Images section's list (content) column, bound to `ImagesViewModel`.
///
/// This is the *content* column of `RootView`'s single three-column
/// `NavigationSplitView` — it introduces no `NavigationSplitView` of its own.
/// It observes the already-unit-tested view model, renders one row per local
/// image (name, tag, human-readable total size, platforms), exposes a Delete
/// action (swipe + context menu) calling `vm.removeImage`, and presents a
/// `PullImageView` sheet from a toolbar "+" button. Refreshes on appear.
/// Degrades to a calm empty / unavailable state when the runtime is down — it
/// never force-unwraps and never crashes.
@MainActor
struct ImageListView: View {
    @Bindable var viewModel: ImagesViewModel

    /// Whether the Pull Image sheet is presented.
    @State private var isPresentingPull = false

    var body: some View {
        content
            .navigationTitle("Images")
            .frame(minWidth: 280)
            .toolbar {
                ToolbarItem {
                    Button {
                        isPresentingPull = true
                    } label: {
                        Label("Pull Image", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingPull) {
                PullImageView(viewModel: viewModel)
            }
            .task {
                await viewModel.refresh()
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.images.isEmpty {
            emptyState
        } else {
            List {
                ForEach(viewModel.images) { row(for: $0) }
            }
        }
    }

    /// Empty state. When the last refresh failed we say the runtime is
    /// unavailable; otherwise there are simply no images. Neither path crashes
    /// when `container` is missing or the daemon is down.
    private var emptyState: some View {
        ContentUnavailableView(
            viewModel.lastError == nil ? "No Images" : "Container Runtime Unavailable",
            systemImage: "square.stack.3d.up",
            description: Text(
                viewModel.lastError == nil
                    ? "Pull an image to get started."
                    : "Could not reach the container runtime. Make sure the service is running."
            )
        )
    }

    @ViewBuilder
    private func row(for image: ContainerImage) -> some View {
        ImageRow(image: image)
            .contextMenu {
                Button(role: .destructive) {
                    Task { await viewModel.removeImage(image.name) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    Task { await viewModel.removeImage(image.name) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }
}

/// A single image row: repository (name without tag) as the headline, the tag as
/// a pill, the human-readable total size, and the distinct platform
/// architectures.
@MainActor
struct ImageRow: View {
    let image: ContainerImage

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repository)
                        .font(.headline)
                        .lineLimit(1)
                    Text(tag)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                if !image.platforms.isEmpty {
                    Text(image.platforms.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(formattedSize)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    /// The image reference without its trailing `:tag`, e.g.
    /// `docker.io/library/nginx`.
    private var repository: String {
        ImageReference.repository(of: image.name)
    }

    /// The image reference's tag, e.g. `alpine`. Defaults to `latest` when the
    /// reference carries no explicit tag.
    private var tag: String {
        ImageReference.tag(of: image.name)
    }

    /// `totalSize` rendered as a human-readable, binary (MiB/GiB) byte count.
    private var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(image.totalSize))
    }
}

/// Pure helpers for splitting an OCI image reference into repository + tag.
/// Kept in the view layer (no business logic, just string formatting): the tag
/// delimiter is the last `:` that appears after the last `/`, so registry host
/// ports (e.g. `localhost:5000/foo`) are not mistaken for tags.
enum ImageReference {
    static func repository(of reference: String) -> String {
        guard let colon = tagColonIndex(in: reference) else { return reference }
        return String(reference[reference.startIndex..<colon])
    }

    static func tag(of reference: String) -> String {
        guard let colon = tagColonIndex(in: reference) else { return "latest" }
        return String(reference[reference.index(after: colon)...])
    }

    /// Index of the `:` that separates the tag, or nil if there is none. A colon
    /// only delimits a tag when it appears after the last `/` of the reference.
    private static func tagColonIndex(in reference: String) -> String.Index? {
        let afterSlash = reference.lastIndex(of: "/").map { reference.index(after: $0) }
            ?? reference.startIndex
        let tail = reference[afterSlash...]
        guard let colon = tail.lastIndex(of: ":") else { return nil }
        return colon
    }
}

// MARK: - Preview

// The `#Preview` macro requires the `PreviewsMacros` plugin that only ships with
// full Xcode, not the Command Line Tools `swift build` compile gate. It is gated
// behind `ENABLE_PREVIEWS` (off for CLT builds; set it in Xcode) so the canvas
// preview is available to developers while `swift build` stays green. The
// fixture-backed service guarantees the preview renders with no live daemon.
#if ENABLE_PREVIEWS
#Preview("Images - populated") {
    NavigationStack {
        ImageListView(viewModel: ImagesViewModel(service: ImagePreviewData.populatedService))
    }
}

#Preview("Images - empty") {
    NavigationStack {
        ImageListView(viewModel: ImagesViewModel(service: ImagePreviewData.emptyService))
    }
}
#endif
