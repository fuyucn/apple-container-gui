import SwiftUI
import UniformTypeIdentifiers
import Core

/// A form for building a container image from a Dockerfile and context
/// directory, bound to `BuildViewModel`. The user picks a Dockerfile (file
/// importer), a build context directory (directory importer), and an image tag,
/// then runs `service.build(dockerfile:context:tag:)` via the view model.
///
/// Holds no business logic: it gathers input into local `@State`, kicks off the
/// view model's stored, cancellable `start(...)` Task, and renders the streamed
/// build log live in a monospaced, auto-scrolling area. The in-flight build is
/// cancelled on disappear so the underlying process is torn down.
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
            form
            Divider()
            logArea
            Divider()
            footer
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
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section("Dockerfile") {
                filePickerRow(
                    placeholder: "Choose a Dockerfile…",
                    path: viewModel.dockerfilePath,
                    systemImage: "doc.text",
                    isPresented: $showDockerfilePicker,
                    allowedContentTypes: [.item]
                ) { url in
                    viewModel.dockerfilePath = url.path
                    // Default the context to the Dockerfile's directory if unset.
                    if viewModel.contextPath.isEmpty {
                        viewModel.contextPath = url.deletingLastPathComponent().path
                    }
                }
            }

            Section("Build Context") {
                filePickerRow(
                    placeholder: "Choose a context directory…",
                    path: viewModel.contextPath,
                    systemImage: "folder",
                    isPresented: $showContextPicker,
                    allowedContentTypes: [.folder]
                ) { url in
                    viewModel.contextPath = url.path
                }
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

    /// One labelled picker row: a path/placeholder label, a Choose button, and
    /// its OWN `.fileImporter` (attached here, on a distinct view per row, so the
    /// two importers never shadow each other). `onPick` receives the chosen URL
    /// directly — no shared state to race on.
    private func filePickerRow(
        placeholder: String,
        path: String,
        systemImage: String,
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        onPick: @escaping (URL) -> Void
    ) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(path.isEmpty ? placeholder : path)
                .foregroundStyle(path.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose…") { isPresented.wrappedValue = true }
                .disabled(isRunning)
        }
        .fileImporter(
            isPresented: isPresented,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                onPick(url)
            }
        }
    }

    // MARK: - Log area

    @ViewBuilder
    private var logArea: some View {
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
                    Label("Build Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .running:
                ContentUnavailableView {
                    Label("Building…", systemImage: "hammer")
                } description: {
                    Text("Waiting for build output…")
                }
            default:
                ContentUnavailableView {
                    Label("No Build Output", systemImage: "hammer")
                } description: {
                    Text("Pick a Dockerfile and context, then Build.")
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
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: viewModel.logLines.count) { _, newCount in
                guard newCount > 0 else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            statusLabel
            if viewModel.status == .succeeded, viewModel.builtImageTag != nil {
                Button("Run Image") {
                    isRunSheetPresented = true
                }
            }
            Spacer()
            if isRunning {
                Button("Cancel", role: .cancel) {
                    viewModel.cancel()
                }
            }
            Button {
                viewModel.start(
                    dockerfile: viewModel.dockerfilePath,
                    context: viewModel.contextPath,
                    tag: viewModel.tag.trimmingCharacters(in: .whitespaces)
                )
            } label: {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Build")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canBuild)
        }
        .padding()
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.status {
        case .idle:
            EmptyView()
        case .running:
            Label("Building…", systemImage: "hammer")
                .foregroundStyle(.secondary)
        case .succeeded:
            Label("Build succeeded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("Build failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
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
    .frame(width: 620, height: 560)
}
#endif
