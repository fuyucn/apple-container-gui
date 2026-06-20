import SwiftUI
import UniformTypeIdentifiers
import Core

/// A form for building a container image from a Dockerfile and context
/// directory, bound to `BuildViewModel`. The user picks a Dockerfile (file
/// importer), a build context directory (directory importer), and an image tag,
/// then runs `service.build(dockerfile:context:tag:)` via the view model.
///
/// Holds no business logic: it binds inputs straight onto the view model, kicks
/// off its stored, cancellable `start(...)` Task, and renders the streamed build
/// log live in a monospaced, auto-scrolling console. The in-flight build is NOT
/// cancelled on disappear — it lives on the view model (owned by `RootView`) so
/// switching sidebar sections mid-build keeps it running.
@MainActor
struct BuildView: View {
    /// The build view model. Owned by the host (`RootView`) so its streaming
    /// Task survives view re-creation while the Build section is shown.
    @Bindable var viewModel: BuildViewModel

    /// Containers view model, threaded through so a successful build can present
    /// the Run sheet prefilled with the built image tag.
    @Bindable var containersViewModel: ContainersViewModel

    /// Supplies local image suggestions to the presented Run sheet's picker.
    @Bindable var imagesViewModel: ImagesViewModel

    // MARK: - Form input state
    //
    // The Dockerfile path, context path, and tag live on `viewModel` (not as
    // view-local @State) so they survive this view being recreated when the
    // user switches sidebar sections mid-build.

    /// Whether each file importer is presented. Each `.fileImporter` is attached
    /// to its OWN row view (not stacked on one view, which would shadow), and
    /// each driven by a plain bool — a single shared importer with a computed
    /// binding raced: the dismiss niled the target before onCompletion read it,
    /// so the picked path was dropped.
    @State private var showDockerfilePicker = false
    @State private var showContextPicker = false

    /// Whether the Run sheet (seeded with the built image) is presented.
    @State private var isRunSheetPresented = false

    var body: some View {
        VStack(spacing: 0) {
            // Side-by-side: configuration + action on the left, the build output
            // console on the right, so the form stays fully visible while logs
            // stream (a draggable divider lets the user rebalance).
            HSplitView {
                VStack(spacing: 0) {
                    form
                    Divider()
                    footer
                }
                .frame(minWidth: 340, idealWidth: 400)

                logArea
                    .frame(minWidth: 320)
            }
        }
        .navigationTitle("Build Image")
        // NOTE: deliberately no `.onDisappear { cancel() }`. The build runs in
        // the view model's stored Task (owned by RootView), so switching sidebar
        // sections mid-build lets it keep running; returning shows live progress.
        // The build is only stopped via the explicit Cancel button.
        .sheet(isPresented: $isRunSheetPresented) {
            RunContainerView(
                viewModel: containersViewModel,
                imagesViewModel: imagesViewModel,
                initialImage: viewModel.builtImageTag
            )
        }
        // A finished build produces a new image; refresh the shared images view
        // model so the Images section reflects it immediately (it's the same
        // instance shown there).
        .onChange(of: viewModel.status) { _, newStatus in
            if newStatus == .succeeded {
                Task { await imagesViewModel.refresh() }
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                filePickerRow(
                    label: "Dockerfile",
                    placeholder: "No Dockerfile chosen",
                    path: viewModel.dockerfilePath,
                    systemImage: "doc.text.fill",
                    isPresented: $showDockerfilePicker,
                    allowedContentTypes: [.item]
                ) { url in
                    viewModel.dockerfilePath = url.path
                    // Default the context to the Dockerfile's directory if unset.
                    if viewModel.contextPath.isEmpty {
                        viewModel.contextPath = url.deletingLastPathComponent().path
                    }
                    // Suggest an editable tag so the build doesn't fall back to a
                    // bare UUID name; the user can change it.
                    if viewModel.tag.isEmpty {
                        viewModel.tag = BuildViewModel.suggestedTag(forDockerfileAt: url)
                    }
                }

                filePickerRow(
                    label: "Build context",
                    placeholder: "No context directory chosen",
                    path: viewModel.contextPath,
                    systemImage: "folder.fill",
                    isPresented: $showContextPicker,
                    allowedContentTypes: [.folder]
                ) { url in
                    viewModel.contextPath = url.path
                }
            } header: {
                Text("Source")
            } footer: {
                Text("Pick the Dockerfile to build and the directory sent as its build context.")
            }

            Section {
                TextField("e.g. myapp:latest", text: $viewModel.tag)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isRunning)
            } header: {
                Text("Image Tag")
            } footer: {
                Text("Passed as --tag; leave empty to let container assign one.")
            }
        }
        .formStyle(.grouped)
    }

    /// One labelled picker row: an icon, a bold label with the chosen path (or a
    /// dimmed "required" hint when empty) beneath it, a Choose button, and its
    /// OWN `.fileImporter` (attached here, on a distinct view per row, so the two
    /// importers never shadow each other). `onPick` receives the chosen URL
    /// directly — no shared state to race on. Each row also accepts a drag-and-
    /// drop of a matching file/folder as a convenience that funnels through the
    /// same `onPick`, so it never touches the importer's state.
    private func filePickerRow(
        label: String,
        placeholder: String,
        path: String,
        systemImage: String,
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        onPick: @escaping (URL) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(path.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout.weight(.medium))
                if path.isEmpty {
                    Text("Required")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Choose…") { isPresented.wrappedValue = true }
                .disabled(isRunning)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .fileImporter(
            isPresented: isPresented,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                onPick(url)
            }
        }
        // Drag-and-drop convenience: a dropped file/folder URL is delivered on
        // the main actor by `dropDestination`, so it funnels through the same
        // `onPick` as the importer without touching the importer's bool state.
        .dropDestination(for: URL.self) { urls, _ in
            guard !isRunning, let url = urls.first else { return false }
            onPick(url)
            return true
        }
    }

    // MARK: - Log area

    /// The build console. Always rendered as a bordered, terminal-like panel so
    /// the page never collapses to a blank area; it shows a calm placeholder when
    /// there is no output yet and the streamed lines once a build runs.
    private var logArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            consoleHeader
            Divider()
            consoleBody
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .frame(minHeight: 220, maxHeight: .infinity)
        .padding(20)
    }

    /// A small title bar over the console so it reads as a deliberate output pane.
    private var consoleHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("Build Output")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            if !viewModel.logLines.isEmpty {
                Text("\(viewModel.logLines.count) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    @ViewBuilder
    private var consoleBody: some View {
        if viewModel.logLines.isEmpty {
            emptyLog
        } else {
            logScroll
        }
    }

    private var emptyLog: some View {
        Group {
            switch viewModel.status {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Build Failed", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    ScrollView {
                        Text(message)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                    .frame(maxHeight: 160)
                }
            case .running:
                ContentUnavailableView {
                    Label("Building…", systemImage: "hammer.fill")
                } description: {
                    Text("Waiting for build output…")
                }
            default:
                ContentUnavailableView {
                    Label("No Build Output", systemImage: "terminal")
                } description: {
                    Text("Choose a Dockerfile and a build context, then press Build.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The scrollable, monospaced build log. Auto-scrolls to the newest line as
    /// lines arrive by scrolling to the last index on `logLines.count` changes.
    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(12)
            }
            .onChange(of: viewModel.logLines.count) { _, newCount in
                guard newCount > 0 else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            statusLabel
            Spacer()
            if viewModel.status == .succeeded, viewModel.builtImageTag != nil {
                Button {
                    isRunSheetPresented = true
                } label: {
                    Label("Run Image", systemImage: "play.fill")
                }
                .controlSize(.large)
            }
            if isRunning {
                Button(role: .cancel) {
                    viewModel.cancel()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .controlSize(.large)
            }
            Button {
                viewModel.start(
                    dockerfile: viewModel.dockerfilePath,
                    context: viewModel.contextPath,
                    tag: viewModel.tag.trimmingCharacters(in: .whitespaces)
                )
            } label: {
                if isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Building…")
                    }
                } else {
                    Label("Build", systemImage: "hammer.fill")
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canBuild)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    /// A status pill reflecting the current build lifecycle, sized to its content
    /// so it reads as a quiet badge rather than a banner. The failed case shows
    /// only a compact label; the full, scrollable error lives in the console.
    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.status {
        case .idle:
            statusPill("Ready", systemImage: "circle", tint: .secondary)
        case .running:
            statusPill("Building…", systemImage: "hammer.fill", tint: .accentColor)
        case .succeeded:
            if let tag = viewModel.builtImageTag {
                statusPill("Built \(tag)", systemImage: "checkmark.circle.fill", tint: .green)
            } else {
                statusPill("Build succeeded", systemImage: "checkmark.circle.fill", tint: .green)
            }
        case .failed:
            statusPill("Build failed", systemImage: "xmark.circle.fill", tint: .red)
        }
    }

    private func statusPill(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }

    // MARK: - Derived

    /// True while a build is in flight.
    private var isRunning: Bool {
        viewModel.status == .running
    }

    /// Build is enabled when both paths are chosen and no build is in flight.
    private var canBuild: Bool {
        !viewModel.dockerfilePath.isEmpty && !viewModel.contextPath.isEmpty && !isRunning
    }
}

// MARK: - Preview

// The `#Preview` macro requires the `PreviewsMacros` plugin that only ships with
// full Xcode, not the Command Line Tools `swift build` compile gate. It is gated
// behind `ENABLE_PREVIEWS` (off for CLT builds; set it in Xcode) so the canvas
// preview is available to developers while `swift build` stays green. The
// canned-line service guarantees the preview renders with no live daemon.
#if ENABLE_PREVIEWS
/// A `ContainerService` whose `build` stream yields a few canned lines then
/// finishes, so the preview renders the populated, scrolling build log.
private struct CannedBuildService: ContainerService {
    func listContainers() async throws -> [Container] { [] }
    func start(_ id: String) async throws {}
    func stop(_ id: String) async throws {}
    func remove(_ id: String) async throws {}
    func run(_ spec: RunSpec) async throws -> String { "preview-id" }
    func stats(_ ids: [String]) async throws -> [ContainerStats] { [] }
    func listImages() async throws -> [ContainerImage] { [] }
    func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func removeImage(_ id: String) async throws {}
    func listVolumes() async throws -> [ContainerVolume] { [] }
    func createVolume(name: String, size: String?, labels: [String: String]) async throws {}
    func removeVolume(_ name: String) async throws {}
    func pruneVolumes() async throws {}
    func logs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func daemonStatus() async throws -> DaemonStatus {
        DaemonStatus(state: .running, appRoot: nil, installRoot: nil)
    }
    func startDaemon() async throws {}
    func build(dockerfile: String, context: String, tag: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("[+] Building 0.1s")
            continuation.yield(" => [internal] load build definition from Dockerfile")
            continuation.yield(" => => transferring dockerfile: 92B")
            continuation.yield(" => [1/2] FROM docker.io/library/alpine:latest")
            continuation.yield(" => [2/2] RUN echo hi")
            continuation.yield(" => exporting to image")
            continuation.yield("Successfully built myapp:latest")
            continuation.finish()
        }
    }
}

#Preview("Build") {
    let service = CannedBuildService()
    return NavigationStack {
        BuildView(
            viewModel: BuildViewModel(service: service),
            containersViewModel: ContainersViewModel(service: service),
            imagesViewModel: ImagesViewModel(service: service)
        )
    }
    .frame(width: 620, height: 640)
}
#endif
