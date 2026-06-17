import Foundation

/// Tracks the progress of a `container build` invocation: its status and the
/// accumulated build log lines streamed from the CLI.
public struct BuildJob: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case running
        case succeeded
        case failed(String)
    }

    public let tag: String
    public private(set) var status: Status
    public private(set) var logLines: [String]

    public init(tag: String) {
        self.tag = tag
        self.status = .running
        self.logLines = []
    }

    /// Append a streamed log line.
    public mutating func append(_ line: String) {
        logLines.append(line)
    }

    /// Mark the build as completed successfully.
    public mutating func markSucceeded() {
        status = .succeeded
    }

    /// Mark the build as failed with a message.
    public mutating func markFailed(_ message: String) {
        status = .failed(message)
    }
}
