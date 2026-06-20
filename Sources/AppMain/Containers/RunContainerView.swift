import SwiftUI
import Core

/// A form (presented as a `.sheet`) that collects input for creating + running a
/// new container, builds a `RunSpec`, and hands it to `ContainersViewModel.run`.
///
/// Holds no business logic: it only gathers user input into local `@State`,
/// assembles a `RunSpec`, and calls the already-unit-tested view model. The image
/// field is free text but is assisted by a menu of locally available images
/// supplied by an optional `ImagesViewModel`. On a successful run (no new error
/// surfaced by the view model) the sheet dismisses; otherwise the view model's
/// `lastError` is shown inline and the sheet stays open.
@MainActor
struct RunContainerView: View {
    /// The containers view model that performs the run + list refresh.
    @Bindable var viewModel: ContainersViewModel

    /// Optional source of local image names for the picker menu. When nil (or
    /// empty) the image field is plain free text.
    var imagesViewModel: ImagesViewModel?

    /// Optional image reference to prefill the image field with (e.g. a freshly
    /// built tag), seeded into `image` on first appearance when it is still empty.
    var initialImage: String? = nil

    @Environment(\.dismiss) private var dismiss

    // MARK: - Form input state

    @State private var image: String = ""
    @State private var name: String = ""
    @State private var detached: Bool = true
    @State private var ports: [PortRow] = []
    @State private var envVars: [EnvRow] = []
    @State private var volumes: [VolumeRow] = []
    @State private var command: String = ""

    /// Index of the volume row whose host path the directory importer is filling,
    /// or nil when the importer is closed. A single `.fileImporter` keyed by row
    /// index avoids the "only one importer per view" limitation.
    @State private var pickingVolumeIndex: Int?

    /// True while a run is in flight, to disable the form + show progress.
    @State private var isRunning = false

    /// The error captured from the view model after the most recent run attempt.
    @State private var runError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                imageSection
                optionsSection
                portsSection
                envSection
                volumesSection
                commandSection
                if let runError {
                    Section {
                        Label(runError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 520)
        .task {
            // Seed the image field from the prefill, only when the user has not
            // already typed something, so reopening never clobbers input.
            if image.isEmpty, let initialImage, !initialImage.isEmpty {
                image = initialImage
            }
            // Populate the image suggestion menu if a source was provided.
            await imagesViewModel?.refresh()
        }
        .fileImporter(
            isPresented: Binding(
                get: { pickingVolumeIndex != nil },
                set: { if !$0 { pickingVolumeIndex = nil } }
            ),
            allowedContentTypes: [.folder]
        ) { result in
            defer { pickingVolumeIndex = nil }
            guard
                let index = pickingVolumeIndex,
                volumes.indices.contains(index),
                case let .success(url) = result
            else { return }
            volumes[index].host = url.path
        }
    }

    // MARK: - Sections

    private var imageSection: some View {
        Section("Image") {
            HStack {
                TextField("e.g. docker.io/library/nginx:latest", text: $image)
                    .textFieldStyle(.roundedBorder)
                if !imageSuggestions.isEmpty {
                    Menu {
                        ForEach(imageSuggestions, id: \.self) { ref in
                            Button(ref) { image = ref }
                        }
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose a local image")
                }
            }
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            TextField("Name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
            Toggle("Run detached", isOn: $detached)
        }
    }

    private var portsSection: some View {
        Section {
            ForEach($ports) { $row in
                HStack {
                    TextField("Host", text: $row.host)
                        .textFieldStyle(.roundedBorder)
                    Text(":")
                    TextField("Container", text: $row.container)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        ports.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                ports.append(PortRow())
            } label: {
                Label("Add Port Mapping", systemImage: "plus")
            }
        } header: {
            Text("Port Mappings")
        } footer: {
            Text("host-port : container-port")
        }
    }

    private var envSection: some View {
        Section {
            ForEach($envVars) { $row in
                HStack {
                    TextField("KEY", text: $row.key)
                        .textFieldStyle(.roundedBorder)
                    Text("=")
                    TextField("value", text: $row.value)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        envVars.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                envVars.append(EnvRow())
            } label: {
                Label("Add Environment Variable", systemImage: "plus")
            }
        } header: {
            Text("Environment")
        }
    }

    private var volumesSection: some View {
        Section {
            ForEach(Array($volumes.enumerated()), id: \.element.id) { index, $row in
                VStack(spacing: 6) {
                    HStack {
                        TextField("Host path (absolute)", text: $row.host)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            pickingVolumeIndex = index
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Choose a host directory")
                    }
                    HStack {
                        Text(":")
                        TextField("Container path", text: $row.container)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Read-only", isOn: $row.readOnly)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                        Button(role: .destructive) {
                            volumes.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button {
                volumes.append(VolumeRow())
            } label: {
                Label("Add Volume", systemImage: "plus")
            }
        } header: {
            Text("Volumes")
        } footer: {
            Text("host-path : container-path — bind mounts for persistent data.")
        }
    }

    private var commandSection: some View {
        Section {
            TextField("Command (optional)", text: $command)
                .textFieldStyle(.roundedBorder)
        } header: {
            Text("Command")
        } footer: {
            Text("Space-separated; appended after the image.")
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await run() }
            } label: {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Run")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canRun)
        }
        .padding()
    }

    // MARK: - Derived

    /// Local image names offered in the suggestion menu, de-duplicated + sorted.
    private var imageSuggestions: [String] {
        guard let imagesViewModel else { return [] }
        return Array(Set(imagesViewModel.images.map(\.name))).sorted()
    }

    /// The Run button is enabled only when an image reference is present and no
    /// run is currently in flight.
    private var canRun: Bool {
        !image.trimmingCharacters(in: .whitespaces).isEmpty && !isRunning
    }

    // MARK: - Actions

    /// Assemble a `RunSpec` from the form and hand it to the view model. The view
    /// performs no container logic itself. Dismiss on success; surface the view
    /// model's error inline otherwise.
    private func run() async {
        isRunning = true
        runError = nil
        defer { isRunning = false }

        await viewModel.run(buildSpec())

        if let error = viewModel.lastError {
            runError = error
        } else {
            dismiss()
        }
    }

    /// Translate the form input into a `RunSpec`, dropping empty rows/fields.
    func buildSpec() -> RunSpec {
        let trimmedImage = image.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        var env: [String: String] = [:]
        for row in envVars {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = row.value
        }

        let mappings: [PortMapping] = ports.compactMap { row in
            guard
                let host = Int(row.host.trimmingCharacters(in: .whitespaces)),
                let container = Int(row.container.trimmingCharacters(in: .whitespaces))
            else { return nil }
            return PortMapping(hostPort: host, containerPort: container)
        }

        let mounts: [VolumeMount] = volumes.compactMap { row in
            let host = row.host.trimmingCharacters(in: .whitespaces)
            let container = row.container.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !container.isEmpty else { return nil }
            return VolumeMount(hostPath: host, containerPath: container, readOnly: row.readOnly)
        }

        let commandParts = command
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        return RunSpec(
            image: trimmedImage,
            name: trimmedName.isEmpty ? nil : trimmedName,
            detached: detached,
            ports: mappings,
            env: env,
            volumes: mounts,
            command: commandParts
        )
    }
}

// MARK: - Row models

/// One editable port-mapping row. `Identifiable` so SwiftUI's `ForEach` can track
/// it across add/remove without index churn.
private struct PortRow: Identifiable {
    let id = UUID()
    var host: String = ""
    var container: String = ""
}

/// One editable environment-variable row.
private struct EnvRow: Identifiable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

/// One editable volume (bind-mount) row.
private struct VolumeRow: Identifiable {
    let id = UUID()
    var host: String = ""
    var container: String = ""
    var readOnly: Bool = false
}

// MARK: - Preview

// The `#Preview` macro requires the `PreviewsMacros` plugin that only ships with
// full Xcode, not the Command Line Tools `swift build` compile gate. It is gated
// behind `ENABLE_PREVIEWS` (off for CLT builds; set it in Xcode) so the canvas
// preview is available to developers while `swift build` stays green. The
// fixture-backed service guarantees the preview renders with no live daemon.
#if ENABLE_PREVIEWS
#Preview("Run Container") {
    RunContainerView(
        viewModel: ContainersViewModel(service: ContainerPreviewData.populatedService),
        imagesViewModel: ImagesViewModel(service: ContainerPreviewData.populatedService)
    )
}
#endif
