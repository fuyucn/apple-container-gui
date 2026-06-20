import Foundation

/// Result of running an external command to completion.
public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Abstraction over external process execution. All CLI invocation in the app
/// flows through this protocol so that callers can be unit-tested against a
/// mock and `Process` stays confined to `Core/CLI`.
public protocol CommandRunner: Sendable {
    /// Runs `executable` with `args` to completion, capturing stdout/stderr/exit.
    func run(_ executable: String, _ args: [String]) async throws -> CommandResult

    /// Streaming variant for logs/exec/build/pull. Each emitted element is one
    /// line of stdout (newline stripped). Implementations MUST finish the
    /// continuation: `.finish()` on clean (zero) exit, `.finish(throwing:)` on
    /// a non-zero exit or spawn failure.
    func stream(_ executable: String, _ args: [String]) -> AsyncThrowingStream<String, Error>
}

/// Error surfaced when a streamed command exits with a non-zero status.
public struct CommandStreamFailure: Error, Sendable {
    public let exitCode: Int32
    public let stderr: String
    public init(exitCode: Int32, stderr: String) {
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

/// Real `CommandRunner` backed by `Foundation.Process`.
///
/// An `actor` because it owns mutable process state. `run` bridges process
/// termination into an async continuation. `stream` is `nonisolated`: its
/// `AsyncThrowingStream` closure captures only `Sendable` locals + the
/// continuation (never isolated `self`), wires `readabilityHandler` into the
/// continuation, finishes with a `CommandStreamFailure` on non-zero exit, and
/// terminates the process via `continuation.onTermination` for cancellation.
public actor ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ args: [String]) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let result = CommandResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                )
                continuation.resume(returning: result)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated public func stream(
        _ executable: String,
        _ args: [String]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // BOTH stdout and stderr MUST be drained concurrently while the
            // process runs. Tools like `container build` (BuildKit) write all
            // their progress to stderr; if we only read stdout, the stderr pipe
            // buffer (~64KB) fills, the child blocks writing to it, and the build
            // hangs forever. So we line-buffer each stream separately and yield
            // both — merging stderr gives the user the build progress too — while
            // accumulating raw stderr text for the failure message.
            let outBuffer = LineBuffer()
            let errBuffer = LineBuffer()
            let errLog = StderrLog()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in outBuffer.append(data) {
                    continuation.yield(line)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                errLog.append(data)
                for line in errBuffer.append(data) {
                    continuation.yield(line)
                }
            }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Flush any trailing partial lines from both streams.
                if let last = outBuffer.flush() { continuation.yield(last) }
                if let last = errBuffer.flush() { continuation.yield(last) }
                let status = proc.terminationStatus
                if status == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: CommandStreamFailure(
                        exitCode: status,
                        stderr: errLog.text()
                    ))
                }
            }

            continuation.onTermination = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Splits an incoming byte stream into newline-delimited UTF-8 lines, holding
/// any trailing partial line until more bytes arrive or `flush()` is called.
/// A reference type so the `@Sendable` readability/termination handlers share
/// one buffer; the handlers are serialized by the pipe so external locking is
/// unnecessary, but we mark `@unchecked Sendable` to satisfy strict concurrency.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    /// Appends `chunk`, returning every complete line now available.
    func append(_ chunk: Data) -> [String] {
        data.append(chunk)
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        while let idx = data.firstIndex(of: newline) {
            let lineData = data[data.startIndex..<idx]
            lines.append(String(decoding: lineData, as: UTF8.self))
            data.removeSubrange(data.startIndex...idx)
        }
        return lines
    }

    /// Returns any buffered trailing line (no terminating newline), clearing it.
    func flush() -> String? {
        guard !data.isEmpty else { return nil }
        let line = String(decoding: data, as: UTF8.self)
        data.removeAll()
        return line
    }
}

/// Thread-safe accumulator of raw stderr bytes, kept so a non-zero exit can
/// report the full stderr. Locked because the stderr readability handler (one
/// queue) and the termination handler (another) both touch it.
private final class StderrLog: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
