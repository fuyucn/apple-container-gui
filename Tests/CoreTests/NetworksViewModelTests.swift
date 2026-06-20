import Testing
import Foundation
@testable import Core

@MainActor
@Test func networksRefreshPopulates() async throws {
    let service = MockContainerService(networks: try ViewModelFixtures.networks())
    let vm = NetworksViewModel(service: service)

    #expect(vm.networks.isEmpty)
    await vm.refresh()

    #expect(vm.networks.count == 1)
    #expect(vm.networks.first?.name == "default")
    #expect(vm.networks.first?.gateway == "192.168.64.1")
}

@MainActor
@Test func createNetworkCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(networks: try ViewModelFixtures.networks())
    let vm = NetworksViewModel(service: service)

    await vm.create(name: "net", internal: true, subnet: "10.0.0.0/24", labels: ["env": "prod"])

    #expect(service.createNetworkCalls.count == 1)
    #expect(service.createNetworkCalls.first?.name == "net")
    #expect(service.createNetworkCalls.first?.isInternal == true)
    #expect(service.createNetworkCalls.first?.subnet == "10.0.0.0/24")
    #expect(service.createNetworkCalls.first?.labels == ["env": "prod"])
    #expect(service.listNetworksCalls == 1)
    #expect(vm.networks.count == 1)
}

@MainActor
@Test func removeNetworkCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(networks: try ViewModelFixtures.networks())
    let vm = NetworksViewModel(service: service)

    await vm.remove("default")

    #expect(service.removeNetworkCalls == ["default"])
    #expect(service.listNetworksCalls == 1)
    #expect(vm.networks.count == 1)
}
