import Testing
import Foundation
@testable import Core

@MainActor
@Test func imagesRefreshPopulates() async throws {
    let service = MockContainerService(images: try ViewModelFixtures.images())
    let vm = ImagesViewModel(service: service)

    #expect(vm.images.isEmpty)
    await vm.refresh()

    #expect(vm.images.count == 1)
    #expect(vm.images.first?.name == "docker.io/library/alpine:latest")
}

@MainActor
@Test func removeImageCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(images: try ViewModelFixtures.images())
    let vm = ImagesViewModel(service: service)

    await vm.removeImage("docker.io/library/alpine:latest")

    #expect(service.removeImageCalls == ["docker.io/library/alpine:latest"])
    #expect(service.listImagesCalls == 1)
    #expect(vm.images.count == 1)
}

@MainActor
@Test func pullAccumulatesStreamLines() async throws {
    let service = MockContainerService(
        images: try ViewModelFixtures.images(),
        streamLines: ["Pulling fs layer", "Downloading 50%", "Pull complete"]
    )
    let vm = ImagesViewModel(service: service)

    await vm.pull("docker.io/library/alpine:latest")

    #expect(vm.pullLog == ["Pulling fs layer", "Downloading 50%", "Pull complete"])
    // After a successful pull the list refreshes.
    #expect(service.listImagesCalls == 1)
    #expect(vm.images.count == 1)
}
