import SwiftUI
import Core

/// The Settings section (content column of `RootView`'s single split): a grouped
/// `Form` bound directly to the injected, already-unit-tested `AppSettings`
/// store. Holds no business logic — every control reads/writes a store property,
/// and persistence + defaults live in Core.
///
/// Sections: Appearance (theme), Behavior (confirm-before-delete), Activity
/// Monitor (poll interval), Defaults (Run CPUs/Memory), and Advanced (the
/// `container` binary path override + the currently resolved path readout). The
/// path override only takes effect after an app relaunch, which the section
/// states explicitly.
@MainActor
struct SettingsView: View {
    @Bindable var settings: AppSettings

    /// Drives the Disk Usage section: holds the latest `system df` snapshot and
    /// the per-category reclaim (prune) actions.
    @Bindable var diskUsageViewModel: DiskUsageViewModel

    /// The binary path the app resolved at launch (composed in `AppMainApp`),
    /// shown read-only so the user can see what the override is — or is not —
    /// pointing at. `nil` renders as "not found".
    let resolvedBinaryPath: String?

    /// The category whose reclaim was requested, driving the confirmation
    /// dialog when `confirmBeforeDelete` is on.
    @State private var pendingReclaim: DiskCategory?

    var body: some View {
        Form {
            appearanceSection
            behaviorSection
            diskUsageSection
            activitySection
            defaultsSection
            advancedSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 460)
        .task { await diskUsageViewModel.refresh() }
        .onAppear { Task { await diskUsageViewModel.refresh() } }
        .confirmationDialog(
            "Reclaim \(pendingReclaim?.label ?? "")?",
            isPresented: Binding(
                get: { pendingReclaim != nil },
                set: { if !$0 { pendingReclaim = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Reclaim", role: .destructive) {
                if let category = pendingReclaim {
                    pendingReclaim = nil
                    Task { await reclaim(category) }
                }
            }
            Button("Cancel", role: .cancel) { pendingReclaim = nil }
        } message: {
            Text("This prunes unused \(pendingReclaim?.label.lowercased() ?? "items") and cannot be undone.")
        }
    }

    // MARK: - Disk Usage

    /// The three reclaimable categories surfaced by `system df`.
    private enum DiskCategory: Identifiable {
        case images, containers, volumes
        var id: String { label }
        var label: String {
            switch self {
            case .images: return "Images"
            case .containers: return "Containers"
            case .volumes: return "Volumes"
            }
        }
    }

    private var diskUsageSection: some View {
        Section {
            if let usage = diskUsageViewModel.usage {
                diskRow(.images, usage.images)
                diskRow(.containers, usage.containers)
                diskRow(.volumes, usage.volumes)
            } else {
                LabeledContent("Disk usage") {
                    Text(diskUsageViewModel.lastError == nil ? "Loading…" : "Unavailable")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("Disk Usage")
                Spacer()
                Button {
                    Task { await diskUsageViewModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
            }
        } footer: {
            Text(
                diskUsageViewModel.usage == nil && diskUsageViewModel.lastError != nil
                    ? "Could not reach the container runtime. Make sure the service is running."
                    : "On-disk size per category, with the amount pruning would reclaim. Reclaim prunes unused items."
            )
        }
    }

    @ViewBuilder
    private func diskRow(_ category: DiskCategory, _ usage: DiskUsage.Category) -> some View {
        LabeledContent(category.label) {
            HStack(spacing: 12) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(usage.sizeDescription)
                        .monospacedDigit()
                    Text("\(usage.reclaimableDescription) reclaimable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Reclaim") {
                    if settings.confirmBeforeDelete {
                        pendingReclaim = category
                    } else {
                        Task { await reclaim(category) }
                    }
                }
                .disabled(usage.reclaimable == 0)
            }
        }
    }

    /// Dispatch the matching prune on the view model.
    private func reclaim(_ category: DiskCategory) async {
        switch category {
        case .images: await diskUsageViewModel.reclaimImages()
        case .containers: await diskUsageViewModel.reclaimContainers()
        case .volumes: await diskUsageViewModel.reclaimVolumes()
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $settings.colorScheme) {
                ForEach(AppColorScheme.allCases) { scheme in
                    Text(scheme.label).tag(scheme)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        Section {
            Toggle("Confirm before deleting", isOn: $settings.confirmBeforeDelete)
        } header: {
            Text("Behavior")
        } footer: {
            Text("When off, destructive actions (deleting containers and images) run without a confirmation dialog.")
        }
    }

    // MARK: - Activity Monitor

    private var activitySection: some View {
        Section {
            Slider(
                value: $settings.activityPollIntervalSeconds,
                in: 1...10,
                step: 1
            ) {
                Text("Poll interval")
            } minimumValueLabel: {
                Text("1s")
            } maximumValueLabel: {
                Text("10s")
            }
            LabeledContent("Interval") {
                Text("\(Int(settings.activityPollIntervalSeconds))s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Activity Monitor")
        } footer: {
            Text("How often the Activity Monitor samples live container stats.")
        }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        Section {
            LabeledContent("Default CPUs") {
                TextField(
                    "auto",
                    value: $settings.defaultRunCPUs,
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
                .multilineTextAlignment(.trailing)
            }
            LabeledContent("Default Memory (MiB)") {
                TextField(
                    "auto",
                    value: $settings.defaultRunMemoryMiB,
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
                .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Run Defaults")
        } footer: {
            Text("Prefilled into the Run Container sheet. Leave blank to let the runtime decide.")
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            TextField(
                "Auto-discover",
                text: Binding(
                    get: { settings.containerBinaryPathOverride ?? "" },
                    set: { settings.containerBinaryPathOverride = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            LabeledContent("Resolved path") {
                Text(resolvedBinaryPath ?? "not found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Override the path to the container binary. Leave blank to auto-discover. Changes take effect after relaunching the app.")
        }
    }
}

// MARK: - Preview

// The `#Preview` macro requires the `PreviewsMacros` plugin shipped only with
// full Xcode, not the Command Line Tools `swift build` compile gate. Gated
// behind `ENABLE_PREVIEWS` (off for CLT builds; set it in Xcode) so the canvas
// preview is available to developers while `swift build` stays green.
#if ENABLE_PREVIEWS
#Preview("Settings") {
    let service = SettingsPreviewService()
    return NavigationStack {
        SettingsView(
            settings: AppSettings(defaults: UserDefaults(suiteName: "preview.settings")!),
            diskUsageViewModel: DiskUsageViewModel(service: service),
            resolvedBinaryPath: "/opt/homebrew/opt/container/bin/container"
        )
    }
}

/// A minimal preview service supplying a fixed `DiskUsage` so the Disk Usage
/// section renders in the canvas. Inherits every other method from the
/// `ContainerService` default extensions.
private struct SettingsPreviewService: ContainerService {
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
    func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
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
    func logs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func systemDF() async throws -> DiskUsage {
        DiskUsage(
            containers: .init(active: 1, reclaimable: 0, sizeInBytes: 3_368_378_368, total: 1),
            images: .init(active: 1, reclaimable: 5_324_488_704, sizeInBytes: 5_750_091_776, total: 8),
            volumes: .init(active: 0, reclaimable: 0, sizeInBytes: 0, total: 0)
        )
    }
    func daemonStatus() async throws -> DaemonStatus { DaemonStatus(state: .running, appRoot: nil, installRoot: nil) }
    func startDaemon() async throws {}
    func build(dockerfile: String, context: String, tag: String, options: BuildOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}
#endif
