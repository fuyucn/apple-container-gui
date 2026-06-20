import SwiftUI
import AppKit
import Core

/// The launch-time setup gate, bound to `SetupCoordinator`. It renders the
/// coordinator's `SetupState` and offers the only two remediations available in
/// M3: copy the Homebrew install command / open the releases page when the
/// binary is missing, and start the daemon when it is stopped. It holds no
/// business logic — install/daemon work runs through the coordinator and the
/// injected `ContainerService`.
///
/// The app shell shows this view until the state reaches `.ready`, at which
/// point it swaps in the normal `RootView`.
@MainActor
struct SetupView: View {
    /// The setup coordinator. Owned by the host so its `check()` Task and state
    /// survive view re-creation.
    @Bindable var coordinator: SetupCoordinator

    /// The Homebrew install command surfaced (and copied) for the missing-binary
    /// case.
    private static let brewCommand = "brew install container"

    /// The upstream releases page for a manual install.
    private static let releasesURL = URL(string: "https://github.com/apple/container/releases")!

    var body: some View {
        VStack(spacing: 24) {
            content
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .checking:
            checking
        case .missingBinary:
            missingBinary
        case .daemonStopped:
            daemonStopped
        case .downloading(let fraction):
            downloading(fraction)
        case .installing:
            installing
        case .startingDaemon:
            startingDaemon
        case .failed(let message):
            failed(message)
        case .ready:
            // The host swaps to RootView at .ready; this is a brief transitional
            // frame only.
            ProgressView("Ready…")
        }
    }

    // MARK: - States

    private var checking: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Checking for the container runtime…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var missingBinary: some View {
        VStack(spacing: 20) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Container Runtime Not Found")
                .font(.title2.weight(.semibold))

            Text("Apple's `container` CLI could not be located. Install it with Homebrew, or download a release from GitHub, then re-check.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            Button {
                Task { await coordinator.runAutoSetup() }
            } label: {
                Label("Install Automatically", systemImage: "arrow.down.circle.fill")
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            Text("Downloads Apple's signed installer from GitHub, verifies its signature, and installs it (you'll be asked for your password). Or install it yourself:")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            manualFallback
        }
    }

    /// The semi-auto remediation: the Homebrew command plus the releases-page
    /// and re-check buttons. Shown beneath the auto-install offer on
    /// `.missingBinary`, and surfaced again on `.failed` so a failed full-auto
    /// run always leaves the user a manual path forward.
    private var manualFallback: some View {
        VStack(spacing: 12) {
            commandRow(Self.brewCommand)

            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.open(Self.releasesURL)
                } label: {
                    Label("Open Releases Page", systemImage: "arrow.up.right.square")
                }

                Button {
                    Task { await coordinator.check() }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func downloading(_ fraction: Double) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Downloading Container Runtime…")
                .font(.title2.weight(.semibold))
            ProgressView(value: fraction)
                .frame(maxWidth: 320)
            Text("\(Int(fraction * 100))%")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var installing: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Installing…")
                .font(.title2.weight(.semibold))
            Text("Approve the installer when macOS asks for your password.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
        }
    }

    private var startingDaemon: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Starting Service…")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var daemonStopped: some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Container Service Stopped")
                .font(.title2.weight(.semibold))

            Text("The `container` runtime is installed but its background service is not running. Start it to continue.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            Button {
                Task { await coordinator.startDaemonAndRecheck() }
            } label: {
                Label("Start Service", systemImage: "play.fill")
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Automatic Setup Failed")
                .font(.title2.weight(.semibold))

            Text(message)
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .textSelection(.enabled)

            Button {
                Task { await coordinator.runAutoSetup() }
            } label: {
                Label("Try Automatic Install Again", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            Divider()
                .frame(maxWidth: 380)

            // A failed full-auto run must never dead-end the user: surface the
            // manual install path (Homebrew + releases) prominently here too.
            Text("Or install it yourself, then re-check:")
                .font(.callout)
                .foregroundStyle(.secondary)

            manualFallback
        }
    }

    // MARK: - Pieces

    /// A monospaced, copyable command row with an explicit Copy button.
    private func commandRow(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy command")
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 380)
    }
}

// MARK: - Preview

#if ENABLE_PREVIEWS
/// A `ContainerService` that does nothing — lets previews render without a live
/// daemon or the real `container` binary.
private struct PreviewSetupService: ContainerService {
    func listContainers() async throws -> [Container] { [] }
    func start(_ id: String) async throws {}
    func stop(_ id: String) async throws {}
    func remove(_ id: String) async throws {}
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
        AsyncThrowingStream { $0.finish() }
    }
    func daemonStatus() async throws -> DaemonStatus {
        DaemonStatus(state: .stopped, appRoot: nil, installRoot: nil)
    }
    func startDaemon() async throws {}
    func build(dockerfile: String, context: String, tag: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Build a coordinator pinned to a given state for preview purposes by leaving
/// it in its initial `.checking` state, then mutating via a helper would require
/// internal access; instead each preview drives the coordinator through `check`
/// with a CLI that produces the desired branch.
@MainActor private func previewCoordinator(overridePath: String?) -> SetupCoordinator {
    let runner = ProcessCommandRunner()
    let cli = ContainerCLI(runner: runner, overridePath: overridePath)
    return SetupCoordinator(service: PreviewSetupService(), cli: cli)
}

#Preview("Checking") {
    SetupView(coordinator: previewCoordinator(overridePath: nil))
}

#Preview("Missing Binary") {
    // Bogus override → resolveBinaryPath returns nil → .missingBinary after check.
    let coordinator = previewCoordinator(overridePath: "/nonexistent/container")
    SetupView(coordinator: coordinator)
        .task { await coordinator.check() }
}

#Preview("Daemon Stopped") {
    // Real existing executable as the binary → present; PreviewSetupService
    // reports .stopped → .daemonStopped after check.
    let coordinator = previewCoordinator(overridePath: "/bin/echo")
    SetupView(coordinator: coordinator)
        .task { await coordinator.check() }
}

/// Builds a coordinator pinned directly to `state` so the auto-setup screens can
/// be rendered in isolation without driving the real download/install flow.
@MainActor private func pinnedCoordinator(_ state: SetupCoordinator.SetupState) -> SetupCoordinator {
    let cli = ContainerCLI(runner: ProcessCommandRunner(), overridePath: nil)
    return SetupCoordinator.previewPinned(state, service: PreviewSetupService(), cli: cli)
}

#Preview("Auto Install (Downloading 40%)") {
    SetupView(coordinator: pinnedCoordinator(.downloading(0.4)))
}

#Preview("Auto Install (Installing)") {
    SetupView(coordinator: pinnedCoordinator(.installing))
}

#Preview("Starting Daemon") {
    SetupView(coordinator: pinnedCoordinator(.startingDaemon))
}

#Preview("Auto Install (Failed)") {
    SetupView(coordinator: pinnedCoordinator(
        .failed("InstallerError.signatureMismatch: the downloaded package is not signed by Apple's expected Team ID.")
    ))
}
#endif
