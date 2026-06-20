import SwiftUI
import Core

/// Tabbed detail for a selected container. Hosts three tabs — Details, Logs, and
/// Inspect — switched by a segmented `Picker` above the content (a plain
/// `TabView` renders its tab bar awkwardly inside a `NavigationSplitView` detail
/// column on macOS; a segmented control reads cleanly and keeps the toolbar
/// free). Holds no business logic: the Details and Inspect tabs are pure
/// projections of the `Container` value, and the Logs tab binds to the injected
/// `LogsViewModel`.
///
/// The log stream is keyed to the selected container id and only runs while the
/// Logs tab is active: it starts when the user switches to Logs (or the
/// container changes while Logs is showing) and is cancelled when the user
/// switches away, the container changes, or the view disappears. This guarantees
/// no stream is left running for a hidden tab or a stale container.
@MainActor
struct ContainerDetailView: View {
    let container: Container

    /// Log view model, owned by the host (`RootView`) so its streaming `Task`
    /// survives view re-creation while the Logs tab is shown.
    @Bindable var logsViewModel: LogsViewModel

    /// Shared service, forwarded to the Terminal tab so it can resolve the
    /// `container exec` invocation from Core.
    let service: any ContainerService

    /// The detail tabs.
    private enum Tab: String, CaseIterable, Identifiable {
        case details = "Details"
        case logs = "Logs"
        case inspect = "Inspect"
        case terminal = "Terminal"

        var id: String { rawValue }
    }

    @State private var selectedTab: Tab = .details

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
        .navigationTitle(container.id)
        .frame(minWidth: 360, minHeight: 360)
        // Start/stop the log stream as the tab or container changes. The stream
        // only runs while the Logs tab is the active tab.
        .onChange(of: selectedTab) { _, newTab in
            syncLogStream(tab: newTab, id: container.id)
        }
        .onChange(of: container.id) { _, newID in
            // A different container was selected: the prior stream (if any) is
            // for the old id, so re-key it to the new id for the active tab.
            syncLogStream(tab: selectedTab, id: newID)
        }
        .onDisappear {
            logsViewModel.stop()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .details:
            detailsTab
        case .logs:
            LogsView(containerID: container.id, viewModel: logsViewModel, manageLifecycle: false)
        case .inspect:
            InspectView(container: container)
        case .terminal:
            terminalTab
        }
    }

    // MARK: - Terminal tab

    /// Hosts an interactive shell for a RUNNING container; shows a disabled
    /// placeholder otherwise. Keyed by container id so switching containers
    /// tears down the old PTY and spawns a fresh session (the terminal view
    /// terminates its process on `onDisappear`).
    @ViewBuilder
    private var terminalTab: some View {
        if container.state == .running {
            ContainerTerminalView(containerID: container.id, service: service)
                .id(container.id)
        } else {
            ContentUnavailableView {
                Label("Terminal Unavailable", systemImage: "terminal")
            } description: {
                Text("Start the container to open an interactive shell.")
            }
        }
    }

    /// Starts the stream for `id` when `tab` is `.logs`; otherwise stops it.
    private func syncLogStream(tab: Tab, id: Container.ID) {
        if tab == .logs {
            logsViewModel.start(id: id, follow: true)
        } else {
            logsViewModel.stop()
        }
    }

    // MARK: - Details tab

    private var detailsTab: some View {
        Form {
            Section("Status") {
                LabeledContent("Name / ID", value: container.id)
                LabeledContent("Image", value: container.imageReference)
                LabeledContent("State") {
                    StateBadge(state: container.state)
                }
                if let started = container.status.startedDate {
                    LabeledContent("Started", value: started)
                }
            }

            Section("Resources") {
                LabeledContent("CPUs", value: "\(container.configuration.resources.cpus)")
                LabeledContent("Memory", value: Self.formatBytes(container.configuration.resources.memoryInBytes))
                LabeledContent(
                    "Platform",
                    value: "\(container.configuration.platform.os)/\(container.configuration.platform.architecture)"
                )
            }

            if container.state == .running && !container.publishedPorts.isEmpty {
                Section("Published Ports") {
                    ForEach(container.publishedPorts, id: \.hostPort) { port in
                        LabeledContent("\(port.hostPort) → \(port.containerPort)") {
                            Link("localhost:\(port.hostPort)", destination: URL(string: "http://localhost:\(port.hostPort)")!)
                        }
                    }
                }
            }

            Section("Networks") {
                if container.status.networks.isEmpty {
                    Text("No active interfaces.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(container.status.networks.enumerated()), id: \.offset) { _, net in
                        networkRow(net)
                    }
                }
            }

            Section("Attached Networks") {
                let names = container.configuration.networks.compactMap(\.network)
                if names.isEmpty {
                    Text("None configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(names, id: \.self) { name in
                        LabeledContent("Network", value: name)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func networkRow(_ net: Container.NetworkStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let network = net.network {
                Text(network)
                    .font(.headline)
            }
            if let host = net.hostname {
                LabeledContent("Hostname", value: host)
            }
            if let ipv4 = net.ipv4Address {
                LabeledContent("IPv4", value: ipv4)
            }
            if let ipv6 = net.ipv6Address {
                LabeledContent("IPv6", value: ipv6)
            }
            if let mac = net.macAddress {
                LabeledContent("MAC", value: mac)
            }
        }
        .padding(.vertical, 2)
    }

    /// Human-readable byte size (binary units), e.g. `1.0 GB`.
    static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Inspect tab

/// Read-only, monospaced, scrollable view of the container's configuration as
/// pretty-printed JSON. Holds no business logic: it re-encodes the already
/// decoded `Container` value with sorted keys for a stable, diffable rendering.
@MainActor
private struct InspectView: View {
    let container: Container

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(json)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// The container re-encoded as pretty JSON. Encoding a value composed of
    /// `Codable` model types cannot realistically fail; a failure degrades to a
    /// readable message rather than crashing the read-only view.
    private var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(container),
              let text = String(data: data, encoding: .utf8) else {
            return "Unable to render container configuration."
        }
        return text
    }
}

// MARK: - Preview

#if ENABLE_PREVIEWS
#Preview("Detail - tabbed") {
    NavigationStack {
        ContainerDetailView(
            container: ContainerPreviewData.runningContainer,
            logsViewModel: LogsViewModel(service: ContainerPreviewData.populatedService),
            service: ContainerPreviewData.populatedService
        )
    }
    .frame(width: 560, height: 480)
}
#endif
