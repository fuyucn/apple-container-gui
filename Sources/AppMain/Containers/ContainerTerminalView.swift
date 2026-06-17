import SwiftUI
import Core
import SwiftTerm

/// In-app interactive terminal for a single RUNNING container (Phase 8.3).
///
/// Hosts SwiftTerm's `LocalProcessTerminalView` (an `NSView`) via an
/// `NSViewRepresentable`. SwiftTerm owns its own PTY and child process — this is
/// the one allowed exception to the "no `Process` outside `Core/CLI`" rule, and
/// it is scoped to the terminal emulator only. The argv handed to the PTY is
/// *not* assembled here: it comes from `ContainerService.execShellInvocation`,
/// which resolves the real `container` binary path and builds
/// `exec -i -t <id> sh`.
///
/// Lifecycle: the host (`ContainerDetailView`) only mounts this view while the
/// Terminal tab is active and the container is running, and re-creates it
/// (via `.id`) when the container changes. The PTY process is spawned in
/// `.task` (after the invocation resolves) and terminated on `onDisappear`,
/// so no PTY is left running for a hidden tab or a stale container. Stopped
/// containers never reach this view — the host shows a disabled placeholder.
@MainActor
struct ContainerTerminalView: View {
    let containerID: Container.ID
    let service: any ContainerService

    /// Holds the live `LocalProcessTerminalView` so the PTY survives SwiftUI
    /// re-evaluation and can be torn down deterministically.
    @State private var session = TerminalSession()

    /// nil while resolving the invocation; set if resolution fails so the user
    /// sees why no shell came up.
    @State private var resolveError: String?

    var body: some View {
        Group {
            if let resolveError {
                ContentUnavailableView {
                    Label("Could Not Open Terminal", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(resolveError)
                }
            } else {
                TerminalSurface(session: session)
            }
        }
        .task {
            // Resolve argv from Core, then start the PTY. Re-runs if the view is
            // re-created for a different container (host keys this view by id).
            do {
                let invocation = try await service.execShellInvocation(id: containerID)
                session.start(invocation)
            } catch {
                resolveError = Self.describe(error)
            }
        }
        .onDisappear {
            session.terminate()
        }
    }

    private static func describe(_ error: Error) -> String {
        if let containerError = error as? ContainerError {
            switch containerError {
            case .binaryNotFound:
                return "The container binary could not be located."
            case .commandFailed(let stderr):
                return stderr.isEmpty ? "The exec command failed." : stderr
            case .decodingFailed(let detail):
                return detail
            }
        }
        return error.localizedDescription
    }
}

/// Owns a single `LocalProcessTerminalView` and starts/terminates its PTY
/// process. Reference type so the view instance is shared between the SwiftUI
/// `@State` and the `NSViewRepresentable` and survives re-evaluation.
@MainActor
final class TerminalSession {
    /// Created lazily so the `NSView` is only instantiated when the terminal is
    /// actually shown.
    let terminalView: LocalProcessTerminalView = {
        LocalProcessTerminalView(frame: .zero)
    }()

    private var started = false

    /// Spawn the PTY-backed process for `invocation` once. `startProcess`
    /// expects the executable path plus the argv *after* it.
    func start(_ invocation: ProcessInvocation) {
        guard !started else { return }
        started = true
        terminalView.startProcess(
            executable: invocation.executable,
            args: invocation.arguments
        )
    }

    /// Terminate the child process and its PTY. Safe to call repeatedly.
    func terminate() {
        guard started else { return }
        started = false
        terminalView.terminate()
    }
}

/// `NSViewRepresentable` bridge: hands the session's `LocalProcessTerminalView`
/// to SwiftUI. The PTY process is started/stopped by `TerminalSession`, not
/// here, so this stays a pure view bridge.
@MainActor
private struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // No reactive state flows into the terminal surface; SwiftTerm manages
        // its own rendering off the PTY.
    }
}

// MARK: - Preview

// `#Preview` requires the `PreviewsMacros` plugin that ships only with full
// Xcode, not the Command Line Tools `swift build` compile gate, so it is gated
// behind `ENABLE_PREVIEWS`. A live PTY is not meaningful in a preview (no real
// container/daemon), so the preview shows a static, empty terminal surface to
// confirm the view hosts and lays out — it intentionally does not spawn a shell.
#if ENABLE_PREVIEWS
#Preview("Terminal - static surface") {
    TerminalSurface(session: TerminalSession())
        .frame(width: 560, height: 360)
}
#endif
