import Testing
import Foundation
@testable import Core

@MainActor
@Test func refreshDaemonStatusPopulates() async throws {
    let service = MockContainerService(
        daemonStatus: DaemonStatus(state: .running, appRoot: "/root", installRoot: nil)
    )
    let vm = AppViewModel(service: service)

    #expect(vm.daemonStatus.state == .unknown)
    await vm.refreshDaemonStatus()

    #expect(vm.daemonStatus.state == .running)
    #expect(vm.isReady)
}

@MainActor
@Test func startDaemonCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(
        daemonStatus: DaemonStatus(state: .running, appRoot: nil, installRoot: nil)
    )
    let vm = AppViewModel(service: service)

    await vm.startDaemon()

    #expect(service.startDaemonCalls == 1)
    #expect(service.daemonStatusCalls == 1)
    #expect(vm.daemonStatus.state == .running)
}

@MainActor
@Test func isReadyFalseWhenStopped() async throws {
    let service = MockContainerService(
        daemonStatus: DaemonStatus(state: .stopped, appRoot: nil, installRoot: nil)
    )
    let vm = AppViewModel(service: service)

    await vm.refreshDaemonStatus()

    #expect(vm.isReady == false)
}
