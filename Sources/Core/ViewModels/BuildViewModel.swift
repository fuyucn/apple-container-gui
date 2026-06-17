import Foundation

/// Drives the build UI: runs a `container build` stream, accumulating log lines
/// and tracking status.
@MainActor
@Observable
public final class BuildViewModel {
    /// Lifecycle of the current build.
    public enum Status: Sendable, Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    /// Accumulated build log lines from the current/most-recent build.
    public private(set) var logLines: [String] = []

    /// Current build status.
    public private(set) var status: Status = .idle

    private let service: any ContainerService

    /// The running stream-consumer task, stored so `cancel()` can stop it — a
    /// fire-and-forget `Task {}` cannot be stopped. Used by `start(...)`.
    private var streamTask: Task<Void, Never>?

    public init(service: any ContainerService) {
        self.service = service
    }

    /// Run a build, resetting the log, streaming each line into `logLines`, and
    /// transitioning `status` to `.succeeded` on clean completion or `.failed`
    /// on stream error.
    public func build(dockerfile: String, context: String, tag: String) async {
        logLines = []
        status = .running

        do {
            for try await line in service.build(dockerfile: dockerfile, context: context, tag: tag) {
                logLines.append(line)
            }
            status = .succeeded
        } catch {
            status = .failed(String(describing: error))
        }
    }

    /// Begin a build in a stored, cancellable `Task`, resetting prior output.
    /// Cancels any existing build first so there is never more than one running.
    /// Each streamed line is appended to `logLines`; clean completion →
    /// `.succeeded`, an error → `.failed`. Cancellation leaves status unchanged
    /// (the caller drives it via `cancel()`).
    public func start(dockerfile: String, context: String, tag: String) {
        streamTask?.cancel()
        logLines = []
        status = .running

        let service = self.service
        streamTask = Task { [weak self] in
            do {
                for try await line in service.build(dockerfile: dockerfile, context: context, tag: tag) {
                    if Task.isCancelled { break }
                    self?.logLines.append(line)
                }
                if !Task.isCancelled {
                    self?.status = .succeeded
                }
            } catch {
                if !Task.isCancelled {
                    self?.status = .failed(String(describing: error))
                }
            }
        }
    }

    /// Cancel an in-flight build and release the task. Idempotent; safe to call
    /// from `onDisappear`. Cancelling tears down the underlying process via the
    /// stream's `onTermination`. Resets a `.running` status back to `.idle` and
    /// leaves accumulated `logLines` intact.
    public func cancel() {
        streamTask?.cancel()
        streamTask = nil
        if status == .running {
            status = .idle
        }
    }
}
