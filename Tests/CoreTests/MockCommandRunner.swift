import Foundation
@testable import Core

/// Test-support mock implementing `CommandRunner`.
///
/// Records every `run`/`stream` invocation's argv (`[executable] + args`) and
/// returns a pre-seeded `CommandResult` from `run`. For `stream`, it yields a
/// finite, pre-seeded `[String]` then finishes the continuation — `.finish()`
/// on success or `.finish(throwing:)` when `streamError` is set. Honors
/// cancellation by checking `Task.isCancelled` before each yield.
///
/// A reference type (`final class`) so tests can read `calls` after invoking;
/// guarded by a lock to satisfy `Sendable` under strict concurrency.
final class MockCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private let result: CommandResult
    private let streamLines: [String]
    private let streamError: Error?

    /// Recorded invocations, each as `[executable] + args`.
    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    init(
        result: CommandResult = .init(exitCode: 0, stdout: "", stderr: ""),
        streamLines: [String] = [],
        streamError: Error? = nil
    ) {
        self.result = result
        self.streamLines = streamLines
        self.streamError = streamError
    }

    private func record(_ executable: String, _ args: [String]) {
        lock.lock(); defer { lock.unlock() }
        _calls.append([executable] + args)
    }

    func run(_ executable: String, _ args: [String]) async throws -> CommandResult {
        record(executable, args)
        return result
    }

    func stream(_ executable: String, _ args: [String]) -> AsyncThrowingStream<String, Error> {
        record(executable, args)
        let lines = streamLines
        let error = streamError
        return AsyncThrowingStream { continuation in
            for line in lines {
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.yield(line)
            }
            continuation.finish(throwing: error)
        }
    }
}
