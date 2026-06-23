import SwiftUI
import UniformTypeIdentifiers
import Core

/// The Images section's master (list) column, bound to `ImagesViewModel`.
///
/// This is the left pane of `RootView`'s Images master-detail `HSplitView` — it
/// introduces no `NavigationSplitView` of its own and drives the selected image
/// name (a binding owned by `RootView`, which renders the detail pane). It shows
/// the total on-disk size in the header, a sort menu and a search filter, a "+"
/// Pull button and a Refresh button, and groups rows into "In Use" (images
/// referenced by an existing container), "Images" (the rest of the tagged
/// images) and "Dangling" (untagged digest/UUID images). Each row exposes a
/// trash delete button and a right-click context menu (Copy Tag, Copy ID,
/// Export, Debug Shell, Delete).
///
/// Show in Finder / Copy Path are intentionally absent: Apple's `container`
/// stores images as content-addressable OCI blobs and exposes no per-image
/// on-disk path, so those actions are not feasible (verified in the data layer).
///
/// Degrades to a calm empty / unavailable state when the runtime is down — it
/// never force-unwraps and never crashes.
@MainActor
struct ImageListView: View {
    @Bindable var viewModel: ImagesViewModel

    /// Selected image name, owned by `RootView` so its detail pane can show the
    /// matching `ImageDetailView`. The `ContainerImage.name` is the identity.
    @Binding var selectedID: String?

    /// Shared service, forwarded only so the row's Debug Shell action and the
    /// detail's Terminal tab can resolve the debug-shell invocation. (The list
    /// itself never shells out.)
    let service: any ContainerService

    /// App preferences. Drives whether the destructive Prune action confirms
    /// first.
    var settings: AppSettings?

    /// Whether the Pull Image sheet is presented.
    @State private var isPresentingPull = false

    /// Whether the "Prune Unused" confirmation dialog is presented.
    @State private var isConfirmingPrune = false

    /// The image reference currently being tagged (drives the Tag sheet), or nil.
    @State private var tagSource: ImageRef?

    /// The image reference currently being pushed (drives the Push sheet), or nil.
    @State private var pushReference: ImageRef?

    /// The image whose throwaway debug shell is presented in a sheet, or nil.
    @State private var shellImage: ImageRef?

    /// Search text; filters by image name, case-insensitive. View-local.
    @State private var searchText = ""

    /// How to order the visible images.
    @State private var sortOrder: ListSort = .name

    /// Sort key for the visible images.
    private enum ListSort: String, CaseIterable, Identifiable {
        case name = "Name"
        case size = "Size"
        case created = "Created"
        var id: Self { self }
        var label: String { "Sort by \(rawValue)" }
    }

    var body: some View {
        content
            .navigationTitle("Images")
            .frame(minWidth: 280)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Filter by name")
            .toolbar {
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
                        if settings?.confirmBeforeDelete ?? true {
                            isConfirmingPrune = true
                        } else {
                            Task { await viewModel.prune() }
                        }
                    } label: {
                        Label("Prune Unused", systemImage: "trash.slash")
                    }
                }
                ToolbarItem {
                    Button {
                        isPresentingPull = true
                    } label: {
                        Label("Pull Image", systemImage: "plus")
                    }
                }
            }
            .confirmationDialog(
                "Remove all unused images?",
                isPresented: $isConfirmingPrune,
                titleVisibility: .visible
            ) {
                Button("Prune Unused", role: .destructive) {
                    Task { await viewModel.prune() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes every image not referenced by a container. This cannot be undone.")
            }
            .sheet(isPresented: $isPresentingPull) {
                PullImageView(viewModel: viewModel)
            }
            .sheet(item: $tagSource) { source in
                TagImageView(viewModel: viewModel, source: source.ref)
            }
            .sheet(item: $pushReference) { reference in
                PushImageView(viewModel: viewModel, reference: reference.ref)
            }
            .sheet(item: $shellImage) { image in
                debugShellSheet(for: image.ref)
            }
            // Refresh both when the view first appears AND whenever it reappears
            // after a section switch — `.task` alone proved unreliable inside the
            // split's detail column, so `.onAppear` backs it up.
            .task { await viewModel.refresh() }
            .onAppear { Task { await viewModel.refresh() } }
    }

    // MARK: - Derived groups

    /// `viewModel.images` after the search filter, sorted by the chosen order.
    private var visibleImages: [ContainerImage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? viewModel.images
            : viewModel.images.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return filtered.sorted(by: ordering)
    }

    /// Comparator for `sortOrder`. Name uses a localized, case-insensitive
    /// compare; size sorts largest first; created sorts newest first by the
    /// runtime's raw creation string (ISO8601 sorts correctly lexically; missing
    /// dates sort last), tie-breaking on name.
    private func ordering(_ a: ContainerImage, _ b: ContainerImage) -> Bool {
        switch sortOrder {
        case .name:
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        case .size:
            if a.totalSize != b.totalSize { return a.totalSize > b.totalSize }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        case .created:
            let dateA = a.configuration.creationDate ?? ""
            let dateB = b.configuration.creationDate ?? ""
            if dateA != dateB { return dateA > dateB }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The total on-disk size across every (unfiltered) image, human-readable.
    private var totalSizeText: String {
        let total = viewModel.images.map(\.totalSize).reduce(0, +)
        return ImageSizeFormatter.string(total)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.images.isEmpty {
            emptyState
        } else if visibleImages.isEmpty {
            noMatchesState
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                imageList
            }
        }
    }

    /// The OrbStack-style header: "Images" + total size.
    private var header: some View {
        HStack {
            Text("Images")
                .font(.title3.weight(.semibold))
            Spacer()
            Text("\(totalSizeText) total")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The grouped, selection-bound list, distinguishing images by use:
    /// "In Use" (referenced by an existing container) and "Idle" (not). Untagged
    /// digest/UUID images are split out under "Dangling" within the idle set,
    /// since they are the cleanup candidates. Each section header shows its count.
    private var imageList: some View {
        let inUse = visibleImages.filter { viewModel.inUseNames.contains($0.name) }
        let idle = visibleImages.filter { !viewModel.inUseNames.contains($0.name) }
        let idleTagged = idle.filter { !ImageGrouping.isDangling($0.name) }
        let dangling = idle.filter { ImageGrouping.isDangling($0.name) }

        return List(selection: $selectedID) {
            if !inUse.isEmpty {
                Section("In Use — \(inUse.count)") {
                    ForEach(inUse) { row(for: $0) }
                }
            }
            if !idleTagged.isEmpty {
                Section("Idle — \(idleTagged.count)") {
                    ForEach(idleTagged) { row(for: $0) }
                }
            }
            if !dangling.isEmpty {
                Section("Dangling — \(dangling.count)") {
                    ForEach(dangling) { row(for: $0) }
                }
            }
        }
    }

    /// Empty state. When the last refresh failed we say the runtime is
    /// unavailable; otherwise there are simply no images.
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

    /// Shown when there *are* images but the search hides them all.
    private var noMatchesState: some View {
        ContentUnavailableView(
            "No Matches",
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text("No images match “\(searchText)”.")
        )
    }

    @ViewBuilder
    private func row(for image: ContainerImage) -> some View {
        ImageRow(image: image) {
            Task { await viewModel.removeImage(image.name) }
        }
        .tag(image.name)
        .contextMenu { contextActions(for: image) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await viewModel.removeImage(image.name) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func contextActions(for image: ContainerImage) -> some View {
        Button {
            copyToPasteboard(image.name)
        } label: {
            Label("Copy Tag", systemImage: "tag")
        }
        Button {
            copyToPasteboard(image.configuration.descriptor.digest)
        } label: {
            Label("Copy ID", systemImage: "number")
        }
        Divider()
        Button {
            presentExportPanel(for: image)
        } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
        }
        Button {
            shellImage = ImageRef(ref: image.name)
        } label: {
            Label("Debug Shell", systemImage: "terminal")
        }
        Button {
            tagSource = ImageRef(ref: image.name)
        } label: {
            Label("Tag…", systemImage: "tag")
        }
        Button {
            pushReference = ImageRef(ref: image.name)
        } label: {
            Label("Push…", systemImage: "arrow.up.circle")
        }
        Divider()
        // NOTE: Show in Finder / Copy Path are intentionally omitted — Apple's
        // `container` exposes no per-image on-disk path (content-addressable OCI
        // blobs keyed by digest), so there is nothing to reveal or copy.
        Button(role: .destructive) {
            Task { await viewModel.removeImage(image.name) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Present an `NSSavePanel` to choose a `.tar` destination, then export the
    /// image there via the view model.
    private func presentExportPanel(for image: ContainerImage) {
        let panel = NSSavePanel()
        panel.title = "Export Image"
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        let repo = ImageReference.repository(of: image.name)
        let tag = ImageReference.tag(of: image.name)
        let last = repo.split(separator: "/").last.map(String.init) ?? repo
        panel.nameFieldStringValue = "\(last)-\(tag).tar".replacingOccurrences(of: "/", with: "-")
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.exportImage(ref: image.name, to: url.path) }
    }

    /// A debug-shell sheet hosting the throwaway-container terminal for `ref`.
    private func debugShellSheet(for ref: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Debug Shell — \(ref)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Close") { shellImage = nil }
            }
            .padding(12)
            Divider()
            ImageTerminalView(imageRef: ref, service: service)
                .id(ref)
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}

/// A wrapper making an image reference `Identifiable` so it can drive the
/// `.sheet(item:)` presentations. The reference string itself is the identity.
private struct ImageRef: Identifiable {
    let ref: String
    var id: String { ref }
}

/// Pure helper for the "Dangling" grouping: an image is dangling when its name
/// has no real `repo:tag` — i.e. it is a bare hex digest or UUID with no tag.
/// Kept in the view layer (presentation grouping only, no Core behavior).
enum ImageGrouping {
    static func isDangling(_ name: String) -> Bool {
        // A real reference carries a tag delimiter (the last `:` after the last
        // `/`); names without one and shaped like a bare digest/UUID are dangling.
        let last = name.split(separator: "/").last.map(String.init) ?? name
        if last.contains(":") { return false }
        // Bare hex digest (sha256 content id) or UUID → dangling.
        let hex = last.replacingOccurrences(of: "-", with: "")
        let isHex = !hex.isEmpty && hex.allSatisfy { $0.isHexDigit }
        return isHex && hex.count >= 12
    }
}

/// A single image row: repository (name without tag) as the headline, the tag as
/// a pill, a "<size>, <relative> ago" subtitle, and a trailing trash button.
@MainActor
struct ImageRow: View {
    let image: ContainerImage
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repository)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(tag)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete image")
            .opacity(isHovering ? 1 : 0.45)
        }
        .padding(.vertical, 2)
        .onHover { isHovering = $0 }
    }

    /// The image reference without its trailing `:tag`.
    private var repository: String {
        ImageReference.repository(of: image.name)
    }

    /// The image reference's tag (defaults to `latest`).
    private var tag: String {
        ImageReference.tag(of: image.name)
    }

    /// "<size>, <relative> ago", e.g. "22.1 MB, 3 days ago". Omits the relative
    /// span when the runtime did not report a creation date.
    private var subtitle: String {
        let size = ImageSizeFormatter.string(image.totalSize)
        if let date = image.createdDate {
            return "\(size), \(date.formatted(.relative(presentation: .named)))"
        }
        return size
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

/// Shared human-readable byte formatter for images (binary MiB/GiB units).
enum ImageSizeFormatter {
    static func string(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
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
    @Previewable @State var selection: String?
    NavigationStack {
        ImageListView(
            viewModel: ImagesViewModel(service: ImagePreviewData.populatedService),
            selectedID: $selection,
            service: ImagePreviewData.populatedService
        )
    }
}

#Preview("Images - empty") {
    @Previewable @State var selection: String?
    NavigationStack {
        ImageListView(
            viewModel: ImagesViewModel(service: ImagePreviewData.emptyService),
            selectedID: $selection,
            service: ImagePreviewData.emptyService
        )
    }
}
#endif
