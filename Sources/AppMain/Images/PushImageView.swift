import SwiftUI
import Core

/// A sheet that pushes an image by reference, streaming the view model's push
/// progress lines into a live, auto-scrolling log area.
///
/// Mirrors `PullImageView`: it holds no business logic, calls the already
/// unit-tested `ImagesViewModel.push`, and reflects the view model's
/// `isPushing` / `pushLog` / `lastError`. The reference is fixed (the row the
/// user invoked "Push…" on) and shown read-only. On a clean completion (no
/// error surfaced) the sheet dismisses; otherwise the error is shown inline and
/// the sheet stays open.
@MainActor
struct PushImageView: View {
    @Bindable var viewModel: ImagesViewModel

    /// The image reference to push, e.g. `registry.local/alpine:pinned`.
    let reference: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Reference") {
                    Text(reference)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                if !viewModel.pushLog.isEmpty || viewModel.isPushing {
                    Section("Progress") { progressLog }
                }
                if let error = viewModel.lastError, !viewModel.isPushing {
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
    /// as lines arrive by scrolling to the last index on `pushLog.count` changes.
    private var progressLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.pushLog.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    if viewModel.isPushing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Pushing…")
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
            .onChange(of: viewModel.pushLog.count) { _, newCount in
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
                .disabled(viewModel.isPushing)
            Button {
                Task { await push() }
            } label: {
                if viewModel.isPushing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Push")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.isPushing)
        }
        .padding()
    }

    /// Hand the reference to the view model. The view performs no image logic
    /// itself. Dismiss on a clean completion; the view model's `lastError` (and
    /// the accumulated log) stay visible inline otherwise.
    private func push() async {
        await viewModel.push(ref: reference)
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
#Preview("Push Image") {
    PushImageView(
        viewModel: ImagesViewModel(service: ImagePreviewData.pushingService),
        reference: "docker.io/library/redis:alpine"
    )
}
#endif
