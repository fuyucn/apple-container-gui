import SwiftUI
import Core

/// A sheet that creates a network by name, with an optional internal toggle, an
/// optional subnet CIDR, and optional labels.
///
/// Holds no business logic: it gathers a name, an `internal` flag, an optional
/// subnet string (e.g. `10.0.0.0/24`), and zero or more label rows into local
/// `@State`, then calls the already-unit-tested `NetworksViewModel.create`. On a
/// clean completion (no error surfaced) the sheet dismisses; otherwise the error
/// is shown inline and the sheet stays open.
@MainActor
struct CreateNetworkView: View {
    @Bindable var viewModel: NetworksViewModel

    @Environment(\.dismiss) private var dismiss

    /// The network name (required), e.g. `backend`.
    @State private var name: String = ""

    /// Whether the network is internal (no outbound connectivity). Passed via
    /// `--internal` when true.
    @State private var isInternal: Bool = false

    /// Optional subnet CIDR, e.g. `10.0.0.0/24`. Passed via `--subnet` when
    /// non-empty.
    @State private var subnet: String = ""

    /// Optional label rows, each emitted as `--label key=value` when the key is
    /// non-empty.
    @State private var labels: [LabelRow] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Name") {
                    TextField("e.g. backend", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canCreate { Task { await create() } } }
                }
                Section("Options") {
                    Toggle("Internal (no outbound connectivity)", isOn: $isInternal)
                }
                Section("Subnet (optional)") {
                    TextField("e.g. 10.0.0.0/24", text: $subnet)
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

    /// Hand the trimmed inputs to the view model. The view performs no network
    /// logic itself. Dismiss on a clean completion; the view model's `lastError`
    /// stays visible inline otherwise.
    private func create() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let trimmedSubnet = subnet.trimmingCharacters(in: .whitespaces)
        var labelMap: [String: String] = [:]
        for row in labels {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            labelMap[key] = row.value
        }
        await viewModel.create(
            name: trimmedName,
            internal: isInternal,
            subnet: trimmedSubnet.isEmpty ? nil : trimmedSubnet,
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
#Preview("Create Network") {
    CreateNetworkView(viewModel: NetworksViewModel(service: NetworkPreviewData.emptyService))
}
#endif
