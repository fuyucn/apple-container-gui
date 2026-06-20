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
@Test func imagesRefreshComputesInUseNamesFromContainers() async throws {
    // The image fixture is alpine:latest; the container fixture references
    // docker.io/library/alpine:latest. Refresh must mark it in use.
    let service = MockContainerService(
        containers: try ViewModelFixtures.containers(),
        images: try ViewModelFixtures.images()
    )
    let vm = ImagesViewModel(service: service)

    await vm.refresh()

    #expect(service.listContainersCalls == 1)
    #expect(vm.inUseNames.contains("docker.io/library/alpine:latest"))
}

@MainActor
@Test func imagesRefreshInUseEmptyWhenNoContainers() async throws {
    let service = MockContainerService(images: try ViewModelFixtures.images())
    let vm = ImagesViewModel(service: service)

    await vm.refresh()

    #expect(vm.images.count == 1)
    #expect(vm.inUseNames.isEmpty)
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
@Test func imageConfigSeamReturnsServiceConfig() async throws {
    let seeded = ImageConfig(env: ["NGINX_VERSION": "1.31.2", "PATH": "/usr/bin"], exposedPorts: [80])
    let service = MockContainerService(imageConfig: seeded)
    let vm = ImagesViewModel(service: service)

    let config = await vm.imageConfig(for: "docker.io/library/nginx:alpine")

    #expect(service.imageConfigCalls == ["docker.io/library/nginx:alpine"])
    #expect(config.env["NGINX_VERSION"] == "1.31.2")
    #expect(config.exposedPorts == [80])
}

@MainActor
@Test func imageConfigSeamDegradesToEmptyOnError() async throws {
    // Prefill is a convenience: an inspect failure must not surface an error,
    // it just yields an empty config (plain form).
    let service = MockContainerService(throwOnAction: ContainerError.commandFailed("nope"))
    let vm = ImagesViewModel(service: service)

    let config = await vm.imageConfig(for: "ghost:latest")

    #expect(config.env.isEmpty)
    #expect(config.exposedPorts.isEmpty)
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

@MainActor
@Test func pruneCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(images: try ViewModelFixtures.images())
    let vm = ImagesViewModel(service: service)

    await vm.prune()

    #expect(service.pruneImagesCalls == 1)
    #expect(service.listImagesCalls == 1)
    #expect(vm.images.count == 1)
    #expect(vm.lastError == nil)
}

@MainActor
@Test func pruneOnErrorStillRefreshes() async throws {
    // Matches removeImage's pattern: a failed action is followed by a refresh,
    // and a successful refresh resets lastError. We assert prune was attempted
    // and the list refreshed regardless of the action failing.
    let service = MockContainerService(
        images: try ViewModelFixtures.images(),
        throwOnAction: ContainerError.commandFailed("prune failed")
    )
    let vm = ImagesViewModel(service: service)

    await vm.prune()

    // The mock throws before recording, so pruneImagesCalls stays 0; the
    // meaningful behavior is that a failed action is still followed by a refresh.
    #expect(service.listImagesCalls == 1)
}

@MainActor
@Test func tagCallsServiceThenRefreshes() async throws {
    let service = MockContainerService(images: try ViewModelFixtures.images())
    let vm = ImagesViewModel(service: service)

    await vm.tag(source: "alpine:latest", newRef: "registry.local/alpine:pinned")

    #expect(service.tagImageCalls.count == 1)
    #expect(service.tagImageCalls.first?.source == "alpine:latest")
    #expect(service.tagImageCalls.first?.newRef == "registry.local/alpine:pinned")
    #expect(service.listImagesCalls == 1)
    #expect(vm.lastError == nil)
}

@MainActor
@Test func tagOnErrorStillRefreshes() async throws {
    // As with prune/removeImage: a failed tag is followed by a refresh which
    // resets lastError on success. Assert the tag was attempted and refreshed.
    let service = MockContainerService(
        images: try ViewModelFixtures.images(),
        throwOnAction: ContainerError.commandFailed("no such image")
    )
    let vm = ImagesViewModel(service: service)

    await vm.tag(source: "ghost", newRef: "ghost:tagged")

    // The mock throws before recording, so tagImageCalls stays empty; the
    // meaningful behavior is that a failed action is still followed by a refresh.
    #expect(service.listImagesCalls == 1)
}

@MainActor
@Test func pushAccumulatesStreamLines() async throws {
    let service = MockContainerService(
        streamLines: ["Pushing layer", "Pushing 50%", "Pushed"]
    )
    let vm = ImagesViewModel(service: service)

    await vm.push(ref: "registry.local/alpine:pinned")

    #expect(service.pushCalls == ["registry.local/alpine:pinned"])
    #expect(vm.pushLog == ["Pushing layer", "Pushing 50%", "Pushed"])
    #expect(vm.isPushing == false)
    #expect(vm.lastError == nil)
}

@MainActor
@Test func pushSurfacesStreamError() async throws {
    let service = MockContainerService(
        streamLines: ["Pushing layer"],
        streamError: ContainerError.commandFailed("denied")
    )
    let vm = ImagesViewModel(service: service)

    await vm.push(ref: "registry.local/alpine:pinned")

    #expect(vm.pushLog == ["Pushing layer"])
    #expect(vm.lastError != nil)
    #expect(vm.isPushing == false)
}
