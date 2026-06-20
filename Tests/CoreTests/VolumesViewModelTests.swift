import Testing
import Foundation
@testable import Core

@MainActor
@Test func volumesRefreshPopulates() async throws {
    let service = MockContainerService(volumes: try ViewModelFixtures.volumes())
    let vm = VolumesViewModel(service: service)

    #expect(vm.volumes.isEmpty)
    await vm.refresh()

    #expect(vm.volumes.count == 1)
    #expect(vm.volumes.first?.name == "acg-v3-probe")
    #expect(vm.volumes.first?.sizeInBytes == 67_108_864)
}

@MainActor
@Test func createVolumeCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(volumes: try ViewModelFixtures.volumes())
    let vm = VolumesViewModel(service: service)

    await vm.create(name: "data", size: "64M", labels: ["env": "prod"])

    #expect(service.createVolumeCalls.count == 1)
    #expect(service.createVolumeCalls.first?.name == "data")
    #expect(service.createVolumeCalls.first?.size == "64M")
    #expect(service.createVolumeCalls.first?.labels == ["env": "prod"])
    #expect(service.listVolumesCalls == 1)
    #expect(vm.volumes.count == 1)
}

@MainActor
@Test func removeVolumeCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(volumes: try ViewModelFixtures.volumes())
    let vm = VolumesViewModel(service: service)

    await vm.remove("acg-v3-probe")

    #expect(service.removeVolumeCalls == ["acg-v3-probe"])
    #expect(service.listVolumesCalls == 1)
    #expect(vm.volumes.count == 1)
}

@MainActor
@Test func pruneVolumesCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(volumes: try ViewModelFixtures.volumes())
    let vm = VolumesViewModel(service: service)

    await vm.prune()

    #expect(service.pruneVolumesCalls == 1)
    #expect(service.listVolumesCalls == 1)
    #expect(vm.volumes.count == 1)
}
