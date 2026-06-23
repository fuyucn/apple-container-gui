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

    /// The binary path the app resolved at launch (composed in `AppMainApp`),
    /// shown read-only so the user can see what the override is — or is not —
    /// pointing at. `nil` renders as "not found".
    let resolvedBinaryPath: String?

    var body: some View {
        Form {
            appearanceSection
            behaviorSection
            activitySection
            defaultsSection
            advancedSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 460)
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
    NavigationStack {
        SettingsView(
            settings: AppSettings(defaults: UserDefaults(suiteName: "preview.settings")!),
            resolvedBinaryPath: "/opt/homebrew/opt/container/bin/container"
        )
    }
}
#endif
