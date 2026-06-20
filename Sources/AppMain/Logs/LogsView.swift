import SwiftUI
import Core

/// A live, auto-scrolling log stream for a single container, bound to
/// `LogsViewModel`. Holds no business logic and performs no I/O of its own — it
/// starts the view model's stream on appear (in the view model's stored `Task`)
/// and cancels it on disappear. Renders lines in a monospaced, scrollable view
/// that pins to the newest line as output arrives.
@MainActor
struct LogsView: View {
    /// Container id whose logs to stream.
    let containerID: Container.ID

    /// The log view model. Owned by the presenter (a `@State` in the host) so it
    /// survives view re-creation while the sheet is open.
    @Bindable var viewModel: LogsViewModel

    /// Whether to follow (tail) new output. `true` for the live view.
    var follow: Bool = true

    /// When `true` (the default), this view starts the stream on appear and
    /// cancels it on disappear. When `false`, the host owns the stream lifecycle
    /// (e.g. the tabbed detail starts/stops it on tab switch and container
    /// change), and this view is a pure renderer of `viewModel`.
    var manageLifecycle: Bool = true

    var body: some View {
        content
            .navigationTitle("Logs — \(containerID)")
            .task {
                // Start the stream when the view appears; the view model stores
                // the consuming Task so it can be cancelled on disappear. Skipped
                // when the host manages the stream lifecycle.
                if manageLifecycle {
                    viewModel.start(id: containerID, follow: follow)
                }
            }
            .onDisappear {
                if manageLifecycle {
                    viewModel.stop()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.lines.isEmpty {
            placeholder
        } else {
            logScroll
        }
    }

    /// Empty/loading state: streaming-but-silent vs an error vs a clean finish.
    private var placeholder: some View {
        Group {
            switch viewModel.status {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could Not Stream Logs", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .finished:
                ContentUnavailableView(
                    "No Log Output",
                    systemImage: "doc.plaintext",
                    description: Text("This container produced no log output.")
                )
            default:
                ContentUnavailableView {
                    Label("Waiting for Output", systemImage: "ellipsis")
                } description: {
                    Text("Streaming logs for \(containerID)…")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The scrollable, monospaced log body. Auto-scrolls to the newest line as
    /// lines arrive by scrolling to the last index on `lines.count` changes.
    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.lines.enumerated()), id: \.offset) { index, line in
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
            .onChange(of: viewModel.lines.count) { _, newCount in
                guard newCount > 0 else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Preview

// `#Preview` requires the `PreviewsMacros` plugin that ships only with full
// Xcode, not the Command Line Tools `swift build` compile gate, so it is gated
// behind `ENABLE_PREVIEWS`. The canned-line service guarantees the preview
// renders with no live daemon or real `container` binary.
#if ENABLE_PREVIEWS
/// A `ContainerService` whose `logs` stream yields a few canned lines then
/// finishes, so the preview renders the populated, scrolling log body.
private struct CannedLogsService: ContainerService {
    func listContainers() async throws -> [Container] { [] }
    func start(_ id: String) async throws {}
    func stop(_ id: String, signal: String?, timeout: Int?) async throws {}
    func kill(_ id: String, signal: String?) async throws {}
    func remove(_ id: String, force: Bool) async throws {}
    func deleteAll() async throws {}
    func run(_ spec: RunSpec) async throws -> String { "preview-id" }
    func pruneContainers() async throws {}
    func exportContainer(_ id: String, to path: String) async throws {}
    func stats(_ ids: [String]) async throws -> [ContainerStats] { [] }
    func listImages() async throws -> [ContainerImage] { [] }
    func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func removeImage(_ id: String) async throws {}
    func pruneImages() async throws {}
    func tagImage(source: String, newRef: String) async throws {}
    func pushImage(_ ref: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func listVolumes() async throws -> [ContainerVolume] { [] }
    func createVolume(name: String, size: String?, labels: [String: String]) async throws {}
    func removeVolume(_ name: String) async throws {}
    func pruneVolumes() async throws {}
    func listNetworks() async throws -> [ContainerNetwork] { [] }
    func createNetwork(name: String, internal isInternal: Bool, subnet: String?, labels: [String: String]) async throws {}
    func removeNetwork(_ name: String) async throws {}
    func logs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("2026/06/17 19:33:38 [notice] nginx/1.27.0")
            continuation.yield("2026/06/17 19:33:38 [notice] using the \"epoll\" event method")
            continuation.yield("192.168.64.1 - - [17/Jun/2026:19:34:01] \"GET / HTTP/1.1\" 200 615")
            continuation.yield("192.168.64.1 - - [17/Jun/2026:19:34:02] \"GET /favicon.ico HTTP/1.1\" 404 153")
            continuation.finish()
        }
    }
    func daemonStatus() async throws -> DaemonStatus {
        DaemonStatus(state: .running, appRoot: nil, installRoot: nil)
    }
    func startDaemon() async throws {}
    func build(dockerfile: String, context: String, tag: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

#Preview("Logs - populated") {
    NavigationStack {
        LogsView(
            containerID: "acg-demo-web",
            viewModel: LogsViewModel(service: CannedLogsService()),
            follow: false
        )
    }
    .frame(width: 560, height: 360)
}
#endif
