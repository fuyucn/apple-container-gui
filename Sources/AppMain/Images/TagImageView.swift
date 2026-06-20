import SwiftUI
import Core

/// A sheet that creates a new reference (`image tag`) for an existing image.
///
/// Holds no business logic: it shows the read-only source reference (the row the
/// user invoked "Tag…" on), gathers the new reference into local `@State`, then
/// calls the already-unit-tested `ImagesViewModel.tag`. On a clean completion
/// (no error surfaced) the sheet dismisses; otherwise the error is shown inline
/// and the sheet stays open.
@MainActor
struct TagImageView: View {
    @Bindable var viewModel: ImagesViewModel

    /// The existing image reference being tagged.
    let source: String

    @Environment(\.dismiss) private var dismiss

    /// The new reference to create, e.g. `registry.local/alpine:pinned`.
    @State private var newRef: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Source") {
                    Text(source)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section("New Reference") {
                    TextField("e.g. registry.local/alpine:pinned", text: $newRef)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canTag { Task { await tag() } } }
                }
                if let error = viewModel.lastError {
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
        .frame(minWidth: 480, minHeight: 280)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Tag") {
                Task { await tag() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canTag)
        }
        .padding()
    }

    /// The Tag button is enabled only when a new reference is present.
    private var canTag: Bool {
        !newRef.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Hand the trimmed inputs to the view model. The view performs no image
    /// logic itself. Dismiss on a clean completion; the view model's `lastError`
    /// stays visible inline otherwise.
    private func tag() async {
        let trimmed = newRef.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await viewModel.tag(source: source, newRef: trimmed)
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
#Preview("Tag Image") {
    TagImageView(
        viewModel: ImagesViewModel(service: ImagePreviewData.populatedService),
        source: "docker.io/library/alpine:latest"
    )
}
#endif
