import Testing
import Foundation
@testable import Core

// MARK: - Task 1.1: MockCommandRunner

@Test func mockRunnerReturnsCanned() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "ok", stderr: ""))
    let r = try await mock.run("container", ["ls"])
    #expect(r.stdout == "ok")
    #expect(r.exitCode == 0)
    #expect(mock.calls == [["container", "ls"]])
}

@Test func mockRunnerRecordsMultipleCalls() async throws {
    let mock = MockCommandRunner()
    _ = try await mock.run("container", ["start", "abc"])
    _ = try await mock.run("container", ["stop", "abc"])
    #expect(mock.calls == [["container", "start", "abc"], ["container", "stop", "abc"]])
}

@Test func mockRunnerStreamYieldsAllLinesThenFinishes() async throws {
    let mock = MockCommandRunner(streamLines: ["a", "b", "c"])
    var got: [String] = []
    for try await line in mock.stream("container", ["logs", "x"]) {
        got.append(line)
    }
    #expect(got == ["a", "b", "c"])
    #expect(mock.calls == [["container", "logs", "x"]])
}

@Test func mockRunnerStreamErrorTerminatesLoop() async {
    struct Boom: Error {}
    let mock = MockCommandRunner(streamLines: ["a"], streamError: Boom())
    var got: [String] = []
    var threw = false
    do {
        for try await line in mock.stream("container", ["logs", "x"]) {
            got.append(line)
        }
    } catch {
        threw = true
    }
    #expect(got == ["a"])
    #expect(threw)
}

// MARK: - Task 1.2: ProcessCommandRunner

@Test func processRunnerRunsEcho() async throws {
    let runner = ProcessCommandRunner()
    let r = try await runner.run("/bin/echo", ["hello"])
    #expect(r.exitCode == 0)
    #expect(r.stdout == "hello\n")
    #expect(r.stderr == "")
}

@Test func processRunnerCapturesNonZeroExit() async throws {
    let runner = ProcessCommandRunner()
    let r = try await runner.run("/bin/sh", ["-c", "exit 3"])
    #expect(r.exitCode == 3)
}

@Test func processRunnerStreamsLines() async throws {
    let runner = ProcessCommandRunner()
    var got: [String] = []
    for try await line in runner.stream("/bin/sh", ["-c", "printf 'a\\nb\\n'"]) {
        got.append(line)
    }
    #expect(got == ["a", "b"])
}

@Test func processRunnerStreamThrowsOnNonZeroExit() async {
    let runner = ProcessCommandRunner()
    var threw = false
    do {
        for try await _ in runner.stream("/bin/sh", ["-c", "printf 'x\\n'; exit 2"]) {}
    } catch {
        threw = true
    }
    #expect(threw)
}

@Test func processRunnerStreamCancellationStops() async throws {
    let runner = ProcessCommandRunner()
    // Emits a line every ~50ms forever; we cancel after collecting a couple.
    let stream = runner.stream("/bin/sh", ["-c", "while true; do echo tick; sleep 0.05; done"])
    let task = Task { () -> Int in
        var count = 0
        for try await _ in stream {
            count += 1
            if count >= 2 { break }  // stop consuming → triggers onTermination
        }
        return count
    }
    let count = try await task.value
    #expect(count == 2)
    // If onTermination did not kill the process, the test process would leak a
    // shell, but the stream loop has already exited cleanly here.
}
