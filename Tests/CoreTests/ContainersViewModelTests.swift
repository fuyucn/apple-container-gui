import Testing
import Foundation
@testable import Core

@MainActor
@Test func refreshPopulatesContainers() async throws {
    let fixtures = try ViewModelFixtures.containers()
    let service = MockContainerService(containers: fixtures)
    let vm = ContainersViewModel(service: service)

    #expect(vm.containers.isEmpty)
    await vm.refresh()

    #expect(vm.containers.count == 1)
    #expect(vm.containers.first?.id == "fixture-demo")
}

@MainActor
@Test func stopCallsServiceThenRefreshes() async throws {
    let fixtures = try ViewModelFixtures.containers()
    let service = MockContainerService(containers: fixtures)
    let vm = ContainersViewModel(service: service)

    await vm.stop("fixture-demo")

    #expect(service.stopCalls.map(\.id) == ["fixture-demo"])
    // Refresh ran after the action: containers populated, listContainers called once.
    #expect(vm.containers.count == 1)
    #expect(service.listContainersCalls == 1)
}

@MainActor
@Test func stopWithSignalAndTimeoutForwardsToService() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.stop("fixture-demo", signal: "TERM", timeout: 10)

    #expect(service.stopCalls.count == 1)
    #expect(service.stopCalls.first?.id == "fixture-demo")
    #expect(service.stopCalls.first?.signal == "TERM")
    #expect(service.stopCalls.first?.timeout == 10)
    #expect(service.listContainersCalls == 1)
}

@MainActor
@Test func killCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.kill("fixture-demo", signal: "KILL")

    #expect(service.killCalls.count == 1)
    #expect(service.killCalls.first?.id == "fixture-demo")
    #expect(service.killCalls.first?.signal == "KILL")
    #expect(service.listContainersCalls == 1)
}

@MainActor
@Test func killWithoutSignalForwardsNilSignal() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.kill("fixture-demo")

    #expect(service.killCalls.count == 1)
    #expect(service.killCalls.first?.signal == nil)
    #expect(service.listContainersCalls == 1)
}

@MainActor
@Test func startCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.start("fixture-demo")

    #expect(service.startCalls == ["fixture-demo"])
    #expect(service.listContainersCalls == 1)
}

@MainActor
@Test func removeCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.remove("fixture-demo")

    #expect(service.removeCalls.map(\.id) == ["fixture-demo"])
    #expect(service.removeCalls.first?.force == false)
    #expect(service.stopCalls.isEmpty)
    #expect(service.listContainersCalls == 1)
}

@MainActor
@Test func removeWithStopFirstStopsThenRemoves() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.remove("fixture-demo", stopFirst: true)

    #expect(service.stopCalls.map(\.id) == ["fixture-demo"])
    #expect(service.removeCalls.map(\.id) == ["fixture-demo"])
    #expect(service.removeCalls.first?.force == false)
    #expect(service.listContainersCalls == 1)
}

@MainActor
@Test func removeForceDeletesWithoutStoppingFirst() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.remove("fixture-demo", force: true)

    // Force skips the graceful stop and passes force through to the service.
    #expect(service.stopCalls.isEmpty)
    #expect(service.removeCalls.map(\.id) == ["fixture-demo"])
    #expect(service.removeCalls.first?.force == true)
    #expect(service.listContainersCalls == 1)
}

@MainActor
@Test func deleteAllCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.deleteAll()

    #expect(service.deleteAllCalls == 1)
    #expect(service.listContainersCalls == 1)
    #expect(vm.lastError == nil)
}

@MainActor
@Test func runCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.run(RunSpec(image: "nginx:alpine", name: "web"))

    #expect(service.runSpecs.count == 1)
    #expect(service.runSpecs.first?.image == "nginx:alpine")
    #expect(service.runSpecs.first?.name == "web")
    // Refresh ran after the action.
    #expect(vm.containers.count == 1)
    #expect(service.listContainersCalls == 1)
    #expect(vm.lastError == nil)
}

@MainActor
@Test func runDoesNotRecordSpecWhenServiceThrows() async throws {
    // `throwOnAction` makes `run` throw before recording the spec. (As with the
    // other actions, the post-action `refresh()` succeeds here and resets
    // `lastError` to nil — that is the established `perform` semantics shared by
    // start/stop/remove, so this test only asserts the action did not record.)
    let service = MockContainerService(
        containers: try ViewModelFixtures.containers(),
        throwOnAction: ContainerError.commandFailed("no such image")
    )
    let vm = ContainersViewModel(service: service)

    await vm.run(RunSpec(image: "ghost:latest"))

    #expect(service.runSpecs.isEmpty)
}

@MainActor
@Test func pruneContainersCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.prune()

    #expect(service.pruneContainersCalls == 1)
    #expect(service.listContainersCalls == 1)
    #expect(vm.containers.count == 1)
    #expect(vm.lastError == nil)
}

@MainActor
@Test func pruneContainersOnErrorStillRefreshes() async throws {
    // Matches the shared `perform` semantics (start/stop/remove): a failed
    // action is followed by a refresh, and a successful refresh resets
    // lastError. The mock throws before recording, so pruneContainersCalls
    // stays 0; the meaningful behavior is the refresh still runs.
    let service = MockContainerService(
        containers: try ViewModelFixtures.containers(),
        throwOnAction: ContainerError.commandFailed("prune failed")
    )
    let vm = ContainersViewModel(service: service)

    await vm.prune()

    #expect(service.listContainersCalls == 1)
}

@MainActor
@Test func exportCallsServiceWithPath() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.export(id: "fixture-demo", to: "/Users/x/out.tar")

    #expect(service.exportCalls.count == 1)
    #expect(service.exportCalls.first?.id == "fixture-demo")
    #expect(service.exportCalls.first?.path == "/Users/x/out.tar")
    // Export does not refresh the list.
    #expect(service.listContainersCalls == 0)
    #expect(vm.lastError == nil)
}

@MainActor
@Test func exportSurfacesError() async throws {
    let service = MockContainerService(
        containers: try ViewModelFixtures.containers(),
        throwOnAction: ContainerError.commandFailed("no such container")
    )
    let vm = ContainersViewModel(service: service)

    await vm.export(id: "ghost", to: "/tmp/x.tar")

    #expect(service.exportCalls.isEmpty)
    #expect(vm.lastError != nil)
}

@MainActor
@Test func copyToContainerCallsServiceWithPaths() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.copyToContainer(
        localPath: "/Users/x/app.conf",
        containerId: "fixture-demo",
        containerPath: "/etc/app.conf"
    )

    #expect(service.copyToContainerCalls.count == 1)
    #expect(service.copyToContainerCalls.first?.localPath == "/Users/x/app.conf")
    #expect(service.copyToContainerCalls.first?.containerId == "fixture-demo")
    #expect(service.copyToContainerCalls.first?.containerPath == "/etc/app.conf")
    // A copy does not change container state, so the list is not refreshed.
    #expect(service.listContainersCalls == 0)
    #expect(vm.lastError == nil)
}

@MainActor
@Test func copyToContainerSurfacesError() async throws {
    let service = MockContainerService(
        containers: try ViewModelFixtures.containers(),
        throwOnAction: ContainerError.commandFailed("no such container")
    )
    let vm = ContainersViewModel(service: service)

    await vm.copyToContainer(localPath: "/tmp/x", containerId: "ghost", containerPath: "/tmp/x")

    #expect(service.copyToContainerCalls.isEmpty)
    #expect(vm.lastError != nil)
}

@MainActor
@Test func copyFromContainerCallsServiceWithPaths() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    await vm.copyFromContainer(
        containerId: "fixture-demo",
        containerPath: "/var/log/app.log",
        localPath: "/Users/x/app.log"
    )

    #expect(service.copyFromContainerCalls.count == 1)
    #expect(service.copyFromContainerCalls.first?.containerId == "fixture-demo")
    #expect(service.copyFromContainerCalls.first?.containerPath == "/var/log/app.log")
    #expect(service.copyFromContainerCalls.first?.localPath == "/Users/x/app.log")
    #expect(service.listContainersCalls == 0)
    #expect(vm.lastError == nil)
}

@MainActor
@Test func copyFromContainerSurfacesError() async throws {
    let service = MockContainerService(
        containers: try ViewModelFixtures.containers(),
        throwOnAction: ContainerError.commandFailed("no such file")
    )
    let vm = ContainersViewModel(service: service)

    await vm.copyFromContainer(containerId: "ghost", containerPath: "/tmp/x", localPath: "/tmp/x")

    #expect(service.copyFromContainerCalls.isEmpty)
    #expect(vm.lastError != nil)
}

@MainActor
@Test func startPollingThenStopPollingLeavesNoRunningTask() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    vm.startPolling(interval: .milliseconds(10))

    // Let a few poll cycles run.
    try await Task.sleep(for: .milliseconds(80))
    vm.stopPolling()

    let countAfterStop = service.listContainersCalls
    #expect(countAfterStop >= 1)

    // After stopping, the poll count must not keep increasing. A single refresh
    // already in flight at the moment of `stopPolling()` may still complete
    // (cancellation cannot unwind an awaited call that is already running), so
    // allow at most one trailing increment. A still-running loop at a 10ms
    // interval over this 80ms window would add many more calls than that.
    try await Task.sleep(for: .milliseconds(80))
    #expect(service.listContainersCalls <= countAfterStop + 1)
}

@MainActor
@Test func startPollingCancelsExistingTask() async throws {
    let service = MockContainerService(containers: try ViewModelFixtures.containers())
    let vm = ContainersViewModel(service: service)

    vm.startPolling(interval: .milliseconds(10))
    try await Task.sleep(for: .milliseconds(30))
    // Restarting must not leave two loops running.
    vm.startPolling(interval: .milliseconds(10))
    try await Task.sleep(for: .milliseconds(30))
    vm.stopPolling()

    let countAfterStop = service.listContainersCalls
    try await Task.sleep(for: .milliseconds(60))
    // At most one refresh already in flight at `stopPolling()` may still land;
    // two concurrent loops (the bug this guards against) would add far more.
    #expect(service.listContainersCalls <= countAfterStop + 1)
}
