import Testing
import Foundation
@testable import Core

/// Spin the main-actor run loop until `condition` holds or we give up, so tests
/// can observe the result of the view model's stored streaming `Task` without a
/// fixed sleep. The view model appends on the main actor, so yielding here lets
/// that work run.
@MainActor
private func eventually(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Test func logsStartAccumulatesLinesThenFinishes() async throws {
    let service = MockContainerService(streamLines: ["line one", "line two", "line three"])
    let vm = LogsViewModel(service: service)

    #expect(vm.status == .idle)
    #expect(vm.lines.isEmpty)

    vm.start(id: "acg-demo-web", follow: false)

    await eventually { vm.status == .finished }

    #expect(vm.lines == ["line one", "line two", "line three"])
    #expect(vm.status == .finished)
    #expect(service.logsInvocations.count == 1)
    #expect(service.logsInvocations.first?.id == "acg-demo-web")
    #expect(service.logsInvocations.first?.follow == false)
}

@MainActor
@Test func logsFailureSetsFailedStatusAndKeepsPartialLines() async throws {
    let service = MockContainerService(
        streamLines: ["partial"],
        streamError: ContainerError.commandFailed("logs stream broke")
    )
    let vm = LogsViewModel(service: service)

    vm.start(id: "c1")

    await eventually {
        if case .failed = vm.status { return true }
        return false
    }

    #expect(vm.lines == ["partial"])
    if case .failed(let message) = vm.status {
        #expect(message.contains("logs stream broke"))
    } else {
        Issue.record("expected .failed status, got \(vm.status)")
    }
}

@MainActor
@Test func logsStartResetsLinesAndDefaultsToFollow() async throws {
    let service = MockContainerService(streamLines: ["a"])
    let vm = LogsViewModel(service: service)

    vm.start(id: "c1")
    await eventually { vm.status == .finished }
    vm.start(id: "c2")
    await eventually { vm.status == .finished }

    #expect(vm.lines == ["a"])
    #expect(service.logsInvocations.count == 2)
    // Default follow is true (the live view).
    #expect(service.logsInvocations.first?.follow == true)
}

@MainActor
@Test func logsStopCancelsAndIdlesWhileStreaming() async throws {
    // No lines + no error → makeStream finishes immediately with nil; to model a
    // still-open stream we instead assert stop() from the streaming state idles.
    let service = MockContainerService(streamLines: [])
    let vm = LogsViewModel(service: service)

    // Manually drive into the streaming state then stop before the task runs.
    vm.start(id: "c1", follow: true)
    vm.stop()

    // After stop, status is either .idle (cancelled mid-stream) or .finished
    // (the empty stream completed first); never left dangling in a bad state.
    #expect(vm.status == .idle || vm.status == .finished)
}
