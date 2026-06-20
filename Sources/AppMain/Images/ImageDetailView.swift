import SwiftUI
import UniformTypeIdentifiers
import Core

/// Tabbed detail for a selected image. Hosts two tabs — Info and Terminal —
/// switched by a segmented `Picker` above the content (mirrors
/// `ContainerDetailView`; a `TabView` renders awkwardly inside a split's detail
/// column on macOS).
///
/// There is intentionally NO Files tab: Apple's `container` stores images as
/// content-addressable OCI blobs (a shared `content/blobs/sha256` store keyed by
/// digest, not per-image directories) and exposes no CLI to map an image to an
/// on-disk path or browse its filesystem. Show in Finder / Copy Path / a Files
/// tab are therefore not feasible and are omitted.
///
/// The Info tab is a pure projection of the image's flattened `ImageDetail`. The
/// Terminal tab hosts a throwaway debug shell (`run --rm -i -t <ref> sh`) and is
/// keyed to the selected image: it only runs while the Terminal tab is active
/// and is torn down on switch-away, image change, or disappear.
@MainActor
struct ImageDetailView: View {
    let image: ContainerImage

    /// View model owning the export action (`image save`).
    @Bindable var viewModel: ImagesViewModel

    /// Shared service, forwarded to the Terminal tab so it can resolve the
    /// `container run` debug-shell invocation from Core.
    let service: any ContainerService

    private enum Tab: String, CaseIterable, Identifiable {
        case info = "Info"
        case terminal = "Terminal"
        var id: String { rawValue }
    }

    @State private var selectedTab: Tab = .info

    private var detail: ImageDetail { image.detail }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            content
        }
        .navigationTitle(detail.name)
        .frame(minWidth: 360, minHeight: 360)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .info:
            infoTab
        case .terminal:
            // Keyed by image name so switching images tears down the old PTY and
            // spawns a fresh debug shell (the terminal terminates on disappear).
            ImageTerminalView(imageRef: detail.name, service: service)
                .id(detail.name)
        }
    }

    // MARK: - Info tab

    private var infoTab: some View {
        Form {
            Section("Image") {
                LabeledContent("Tag", value: detail.name)
                LabeledContent("ID") {
                    Text(detail.digest)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Created", value: createdDescription)
                LabeledContent("Size", value: formattedSize)
                if let platform = detail.platform {
                    LabeledContent("Platform", value: platform)
                }
            }

            Section {
                Button {
                    presentExportPanel()
                } label: {
                    Label("Export to Tar…", systemImage: "square.and.arrow.up")
                }
            }

            Section("Config") {
                LabeledContent("Command", value: displayValue(detail.commandLine))
                LabeledContent("Entrypoint", value: displayValue(detail.entrypointLine))
                LabeledContent("Working Directory", value: displayValue(detail.workingDir ?? ""))
            }

            Section("Environment") {
                if detail.environment.isEmpty {
                    Text("No environment variables.")
                        .foregroundStyle(.secondary)
                } else {
                    Table(environmentRows) {
                        TableColumn("Key", value: \.key)
                        TableColumn("Value", value: \.value)
                    }
                    .frame(minHeight: 120)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Export

    /// Present an `NSSavePanel` to choose a `.tar` destination, then export the
    /// image there via the view model. The panel runs on the main actor; the
    /// only logic (the CLI invocation) lives in the VM.
    private func presentExportPanel() {
        let panel = NSSavePanel()
        panel.title = "Export Image"
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        panel.nameFieldStringValue = "\(suggestedFileName).tar"
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await viewModel.exportImage(ref: detail.name, to: url.path) }
    }

    /// A filesystem-safe base name derived from the image's repo:tag.
    private var suggestedFileName: String {
        let repo = ImageReference.repository(of: detail.name)
        let tag = ImageReference.tag(of: detail.name)
        let last = repo.split(separator: "/").last.map(String.init) ?? repo
        return "\(last)-\(tag)".replacingOccurrences(of: "/", with: "-")
    }

    // MARK: - Formatting

    /// Created shown as a relative span plus the absolute timestamp, falling back
    /// to the raw string (or "Unknown") when no `Date` parsed.
    private var createdDescription: String {
        if let date = detail.createdDate {
            let relative = date.formatted(.relative(presentation: .named))
            let absolute = date.formatted(date: .abbreviated, time: .shortened)
            return "\(relative) (\(absolute))"
        }
        return detail.creationDateRaw ?? "Unknown"
    }

    /// `totalSize` rendered as a human-readable, binary (MiB/GiB) byte count.
    private var formattedSize: String {
        ImageSizeFormatter.string(detail.totalSize)
    }

    /// Shows an em dash for an empty value so the row reads clean.
    private func displayValue(_ value: String) -> String {
        value.isEmpty ? "—" : value
    }

    /// `ImageDetail.environment` mapped to identifiable rows for the `Table`.
    private var environmentRows: [EnvRow] {
        detail.environment.map { EnvRow(key: $0.key, value: $0.value) }
    }
}

/// An identifiable environment key/value pair for the Info tab's `Table`.
private struct EnvRow: Identifiable {
    let key: String
    let value: String
    var id: String { key }
}

// MARK: - Preview

#if ENABLE_PREVIEWS
#Preview("Image Detail - tabbed") {
    NavigationStack {
        ImageDetailView(
            image: ImagePreviewData.images[1],
            viewModel: ImagesViewModel(service: ImagePreviewData.populatedService),
            service: ImagePreviewData.populatedService
        )
    }
    .frame(width: 560, height: 480)
}
#endif
