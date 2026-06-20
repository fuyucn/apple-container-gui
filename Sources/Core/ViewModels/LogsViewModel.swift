import Foundation

/// Drives the live log stream UI for a single container: consumes
/// `service.logs(id, follow:)` as an `AsyncThrowingStream`, appending each line
/// into `lines` for a scrollable, auto-scrolling view.
///
/// `@MainActor @Observable` so SwiftUI observes `lines` and `status` directly.
/// Depends only on the `ContainerService` protocol, so it is unit-testable
/// against a mock. The streaming `Task` is stored so it can be cancelled when
/// the view disappears (cancellation tears down the underlying process via the
/// stream's `onTermination`).
@MainActor
@Observable
public final class LogsViewModel {
    /// Lifecycle of the current log stream.
    public enum Status: Sendable, Equatable {
        /// Not yet started (or stopped/reset).
        case idle
        /// Stream is open and tailing.
        case streaming
        /// Stream finished cleanly (the CLI exited zero — e.g. `follow: false`).
        case finished
        /// Stream ended with an error; carries a human-readable description.
        case failed(String)
    }

    /// Accumulated log lines from the current stream, oldest first.
    public private(set) var lines: [String] = []

    /// Current stream status.
    public private(set) var status: Status = .idle

    private let service: any ContainerService

    /// The running stream-consumer task, stored so `stop()`/`onDisappear` can
    /// cancel it — a fire-and-forget `Task {}` cannot be stopped.
    private var streamTask: Task<Void, Never>?

    public init(service: any ContainerService) {
        self.service = service
    }

    /// Begin streaming `id`'s logs, resetting prior output. Cancels any existing
    /// stream first so there is never more than one running. `boot: true` streams
    /// the VM boot log (`--boot`); `tail` (when non-nil) limits to the last N
    /// lines (`-n`). Each line is appended to `lines`; clean completion →
    /// `.finished`, an error → `.failed`.
    public func start(id: String, follow: Bool = true, boot: Bool = false, tail: Int? = nil) {
        streamTask?.cancel()
        lines = []
        status = .streaming

        let service = self.service
        streamTask = Task { [weak self] in
            do {
                for try await line in service.logs(id, follow: follow, boot: boot, tail: tail) {
                    if Task.isCancelled { break }
                    self?.lines.append(line)
                }
                if !Task.isCancelled {
                    self?.status = .finished
                }
            } catch {
                if !Task.isCancelled {
                    self?.status = .failed(String(describing: error))
                }
            }
        }
    }

    /// Cancel the stream and release the task. Idempotent; safe to call from
    /// `onDisappear`. Leaves accumulated `lines` intact.
    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        if status == .streaming {
            status = .idle
        }
    }
}
