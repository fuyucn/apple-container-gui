import SwiftUI
import Core
import SwiftTerm

/// In-app interactive *debug shell* for an image: spins up a throwaway container
/// from the image (`container run --rm -i -t <ref> sh`) and attaches a PTY.
///
/// Mirrors `ContainerTerminalView`: it hosts SwiftTerm's
/// `LocalProcessTerminalView` via an `NSViewRepresentable`, and the argv it hands
/// the PTY is resolved by Core (`ContainerService.imageShellInvocation(ref:)`),
/// never assembled here. The `--rm` flag means the container is removed when the
/// shell exits, so nothing is left behind.
///
/// Lifecycle: the host (`ImageDetailView`) only mounts this view while the
/// Terminal tab is active, and re-creates it (via `.id`) when the image changes.
/// The PTY process is spawned in `.task` (after the invocation resolves) and
/// terminated on `onDisappear`, so no PTY is left running for a hidden tab or a
/// stale image.
@MainActor
struct ImageTerminalView: View {
    let imageRef: String
    let service: any ContainerService

    /// Holds the live `LocalProcessTerminalView` so the PTY survives SwiftUI
    /// re-evaluation and can be torn down deterministically.
    @State private var session = ImageTerminalSession()

    /// nil while resolving the invocation; set if resolution fails so the user
    /// sees why no shell came up.
    @State private var resolveError: String?

    var body: some View {
        Group {
            if let resolveError {
                ContentUnavailableView {
                    Label("Could Not Open Shell", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(resolveError)
                }
            } else {
                ImageTerminalSurface(session: session)
            }
        }
        .task {
            // Resolve argv from Core, then start the PTY. Re-runs if the view is
            // re-created for a different image (host keys this view by ref).
            do {
                let invocation = try await service.imageShellInvocation(ref: imageRef)
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
                return stderr.isEmpty ? "The shell command failed." : stderr
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
final class ImageTerminalSession {
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
/// to SwiftUI. The PTY process is started/stopped by `ImageTerminalSession`, not
/// here, so this stays a pure view bridge.
@MainActor
private struct ImageTerminalSurface: NSViewRepresentable {
    let session: ImageTerminalSession

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
// image/daemon), so the preview shows a static, empty terminal surface to
// confirm the view hosts and lays out — it intentionally does not spawn a shell.
#if ENABLE_PREVIEWS
#Preview("Image Terminal - static surface") {
    ImageTerminalSurface(session: ImageTerminalSession())
        .frame(width: 560, height: 360)
}
#endif
