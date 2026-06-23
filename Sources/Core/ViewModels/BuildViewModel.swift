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

    /// Build form inputs. Held here (not as view-local `@State`) so they survive
    /// the build view being torn down and recreated when the user switches
    /// sidebar sections mid-build.
    public var dockerfilePath: String = ""
    public var contextPath: String = ""
    public var tag: String = ""

    /// Accumulated build log lines from the current/most-recent build.
    public private(set) var logLines: [String] = []

    /// Current build status.
    public private(set) var status: Status = .idle

    /// The tag/name of the image produced by the most recent successful build,
    /// usable to seed a Run sheet. Set only on success: the requested tag when
    /// non-empty, otherwise parsed from the final meaningful build log line (the
    /// CLI prints the resolved tag as its last stdout line). Reset to nil at the
    /// start of every build and nil after a failed build.
    public private(set) var builtImageTag: String?

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
    public func build(dockerfile: String, context: String, tag: String, options: BuildOptions = .init()) async {
        logLines = []
        status = .running
        builtImageTag = nil

        do {
            for try await line in service.build(dockerfile: dockerfile, context: context, tag: tag, options: options) {
                logLines.append(line)
            }
            builtImageTag = Self.resolveTag(requested: tag, logLines: logLines)
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
    public func start(dockerfile: String, context: String, tag: String, options: BuildOptions = .init()) {
        streamTask?.cancel()
        logLines = []
        status = .running
        builtImageTag = nil

        let service = self.service
        streamTask = Task { [weak self] in
            do {
                for try await line in service.build(dockerfile: dockerfile, context: context, tag: tag, options: options) {
                    if Task.isCancelled { break }
                    self?.logLines.append(line)
                }
                if !Task.isCancelled {
                    if let self {
                        self.builtImageTag = Self.resolveTag(requested: tag, logLines: self.logLines)
                    }
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

    /// Resolve the tag to seed a Run sheet after a successful build. Prefers the
    /// trimmed requested tag when non-empty; otherwise falls back to the last
    /// non-blank build log line (the CLI prints the resolved tag/name last).
    /// Returns nil when neither source yields a usable value.
    private static func resolveTag(requested: String, logLines: [String]) -> String? {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let lastMeaningful = logLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
        guard let lastMeaningful, !lastMeaningful.isEmpty else { return nil }
        return lastMeaningful
    }

    /// A suggested image tag to pre-fill when the user picks a Dockerfile, so the
    /// build doesn't fall back to an opaque UUID name. Shaped as
    /// `<package>-<5 chars>:latest`, where `<package>` is the Dockerfile's parent
    /// directory name sanitized to a valid lowercase image name and `<5 chars>`
    /// is a short unique suffix (last 5 of a UUID). The user can edit it freely.
    nonisolated public static func suggestedTag(forDockerfileAt url: URL) -> String {
        let dirName = url.deletingLastPathComponent().lastPathComponent
        let package = sanitizedImageName(dirName)
        let suffix = String(
            UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
                .suffix(5)
        )
        let base = package.isEmpty ? "image" : package
        return "\(base)-\(suffix):latest"
    }

    /// Lowercase and reduce `name` to characters valid in an OCI image name
    /// component (`a-z0-9._-`), collapsing runs of separators and trimming them.
    nonisolated private static func sanitizedImageName(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastWasSep = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSep = false
            } else if !lastWasSep, !out.isEmpty {
                out.append("-")
                lastWasSep = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
