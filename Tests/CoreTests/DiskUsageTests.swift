import Testing
import Foundation
@testable import Core

// MARK: - Fixture loading

private enum DiskUsageFixtureError: Error { case notFound(String) }

private func loadDiskUsageFixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw DiskUsageFixtureError.notFound(name)
    }
    return try Data(contentsOf: url)
}

// MARK: - Decode

@Test func decodeSystemDFFixture() throws {
    let data = try loadDiskUsageFixture("system-df.json")
    let usage = try JSONDecoder().decode(DiskUsage.self, from: data)

    #expect(usage.images.total == 8)
    #expect(usage.images.active == 1)
    #expect(usage.images.reclaimable == 5_324_488_704)
    #expect(usage.images.sizeInBytes == 5_750_091_776)

    #expect(usage.containers.total == 1)
    #expect(usage.containers.active == 1)
    #expect(usage.containers.reclaimable == 0)
    #expect(usage.containers.sizeInBytes == 3_368_378_368)

    #expect(usage.volumes.total == 0)
    #expect(usage.volumes.sizeInBytes == 0)
}

// MARK: - systemDF argv

@Test func systemDFInvokesExactArgvAndDecodes() async throws {
    let json = String(data: try loadDiskUsageFixture("system-df.json"), encoding: .utf8)!
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: json, stderr: ""))
    let service = CLIContainerService(runner: mock, binaryPath: "/opt/homebrew/bin/container")

    let usage = try await service.systemDF()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "system", "df", "--format", "json"]])
    #expect(usage.images.total == 8)
    #expect(usage.images.reclaimable == 5_324_488_704)
}

@Test func systemDFThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "xpc error"))
    let service = CLIContainerService(runner: mock, binaryPath: "/opt/homebrew/bin/container")

    await #expect(throws: ContainerError.commandFailed("xpc error")) {
        try await service.systemDF()
    }
}

// MARK: - DiskUsageViewModel

@MainActor
@Test func diskUsageRefreshPopulates() async throws {
    let seeded = try JSONDecoder().decode(DiskUsage.self, from: loadDiskUsageFixture("system-df.json"))
    let service = MockContainerService(diskUsage: seeded)
    let vm = DiskUsageViewModel(service: service)

    #expect(vm.usage == nil)
    await vm.refresh()

    #expect(service.systemDFCalls == 1)
    #expect(vm.usage?.images.total == 8)
    #expect(vm.lastError == nil)
}

@MainActor
@Test func diskUsageRefreshDegradesOnError() async throws {
    let service = MockContainerService(throwOnAction: ContainerError.commandFailed("daemon down"))
    let vm = DiskUsageViewModel(service: service)

    await vm.refresh()

    #expect(vm.usage == nil)
    #expect(vm.lastError != nil)
}

@MainActor
@Test func reclaimImagesPrunesThenRefreshes() async throws {
    let seeded = try JSONDecoder().decode(DiskUsage.self, from: loadDiskUsageFixture("system-df.json"))
    let service = MockContainerService(diskUsage: seeded)
    let vm = DiskUsageViewModel(service: service)

    await vm.reclaimImages()

    #expect(service.pruneImagesCalls == 1)
    #expect(service.systemDFCalls == 1)
    #expect(vm.usage?.images.total == 8)
}

@MainActor
@Test func reclaimContainersPrunesThenRefreshes() async throws {
    let service = MockContainerService()
    let vm = DiskUsageViewModel(service: service)

    await vm.reclaimContainers()

    #expect(service.pruneContainersCalls == 1)
    #expect(service.systemDFCalls == 1)
}

@MainActor
@Test func reclaimVolumesPrunesThenRefreshes() async throws {
    let service = MockContainerService()
    let vm = DiskUsageViewModel(service: service)

    await vm.reclaimVolumes()

    #expect(service.pruneVolumesCalls == 1)
    #expect(service.systemDFCalls == 1)
}
