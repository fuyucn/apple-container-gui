import SwiftUI
import Core

/// A sheet that creates a volume by name, with an optional provisioned size and
/// optional labels.
///
/// Holds no business logic: it gathers a name, an optional size string (e.g.
/// `256M`), and zero or more label rows into local `@State`, then calls the
/// already-unit-tested `VolumesViewModel.create`. On a clean completion (no
/// error surfaced) the sheet dismisses; otherwise the error is shown inline and
/// the sheet stays open.
@MainActor
struct CreateVolumeView: View {
    @Bindable var viewModel: VolumesViewModel

    @Environment(\.dismiss) private var dismiss

    /// The volume name (required), e.g. `my-data`.
    @State private var name: String = ""

    /// Optional provisioned size, e.g. `256M`. Passed via `-s` when non-empty.
    @State private var size: String = ""

    /// Optional label rows, each emitted as `--label key=value` when the key is
    /// non-empty.
    @State private var labels: [LabelRow] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Name") {
                    TextField("e.g. my-data", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canCreate { Task { await create() } } }
                }
                Section("Size (optional)") {
                    TextField("e.g. 256M", text: $size)
                        .textFieldStyle(.roundedBorder)
                }
                labelsSection
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
        .frame(minWidth: 480, minHeight: 360)
    }

    private var labelsSection: some View {
        Section {
            ForEach($labels) { $row in
                HStack {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                    Text("=")
                    TextField("value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        labels.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                labels.append(LabelRow())
            } label: {
                Label("Add Label", systemImage: "plus")
            }
        } header: {
            Text("Labels")
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") {
                Task { await create() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
        .padding()
    }

    /// The Create button is enabled only when a name is present.
    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Hand the trimmed inputs to the view model. The view performs no volume
    /// logic itself. Dismiss on a clean completion; the view model's `lastError`
    /// stays visible inline otherwise.
    private func create() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let trimmedSize = size.trimmingCharacters(in: .whitespaces)
        var labelMap: [String: String] = [:]
        for row in labels {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            labelMap[key] = row.value
        }
        await viewModel.create(
            name: trimmedName,
            size: trimmedSize.isEmpty ? nil : trimmedSize,
            labels: labelMap
        )
        if viewModel.lastError == nil {
            dismiss()
        }
    }
}

/// One editable label row. `Identifiable` so SwiftUI's `ForEach` can track and
/// reorder/remove rows.
private struct LabelRow: Identifiable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

// MARK: - Preview

// The `#Preview` macro requires the `PreviewsMacros` plugin that only ships with
// full Xcode, not the Command Line Tools `swift build` compile gate. It is gated
// behind `ENABLE_PREVIEWS` (off for CLT builds; set it in Xcode) so the canvas
// preview is available to developers while `swift build` stays green. The
// fixture-backed service guarantees the preview renders with no live daemon.
#if ENABLE_PREVIEWS
#Preview("Create Volume") {
    CreateVolumeView(viewModel: VolumesViewModel(service: VolumePreviewData.emptyService))
}
#endif
