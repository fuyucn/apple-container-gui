import SwiftUI
import Core

/// A sheet that pulls an image by reference, streaming the view model's pull
/// progress lines into a live, auto-scrolling log area.
///
/// Holds no business logic: it gathers the reference into local `@State`, calls
/// the already-unit-tested `ImagesViewModel.pull`, and reflects the view model's
/// `isPulling` / `pullLog` / `lastError`. Inputs are disabled while a pull is in
/// flight. On a clean completion (no error surfaced) the sheet dismisses;
/// otherwise the error is shown inline and the sheet stays open.
@MainActor
struct PullImageView: View {
    @Bindable var viewModel: ImagesViewModel

    @Environment(\.dismiss) private var dismiss

    /// The image reference to pull, e.g. `docker.io/library/redis:alpine`.
    @State private var reference: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Reference") {
                    TextField("e.g. docker.io/library/redis:alpine", text: $reference)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isPulling)
                        .onSubmit { if canPull { Task { await pull() } } }
                }
                if !viewModel.pullLog.isEmpty || viewModel.isPulling {
                    Section("Progress") { progressLog }
                }
                if let error = viewModel.lastError, !viewModel.isPulling {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    /// The scrollable, monospaced progress body. Auto-scrolls to the newest line
    /// as lines arrive by scrolling to the last index on `pullLog.count` changes.
    private var progressLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.pullLog.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    if viewModel.isPulling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Pulling…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id(-1)
                    }
                }
                .padding(4)
            }
            .frame(minHeight: 160)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: viewModel.pullLog.count) { _, newCount in
                guard newCount > 0 else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isPulling)
            Button {
                Task { await pull() }
            } label: {
                if viewModel.isPulling {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Pull")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canPull)
        }
        .padding()
    }

    /// The Pull button is enabled only when a reference is present and no pull is
    /// currently in flight.
    private var canPull: Bool {
        !reference.trimmingCharacters(in: .whitespaces).isEmpty && !viewModel.isPulling
    }

    /// Hand the trimmed reference to the view model. The view performs no image
    /// logic itself. Dismiss on a clean completion; the view model's `lastError`
    /// (and the accumulated log) stay visible inline otherwise.
    private func pull() async {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return }
        await viewModel.pull(ref)
        if viewModel.lastError == nil {
            dismiss()
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
#Preview("Pull Image") {
    PullImageView(viewModel: ImagesViewModel(service: ImagePreviewData.pullingService))
}
#endif
