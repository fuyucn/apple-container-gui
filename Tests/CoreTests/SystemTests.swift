import Testing
import Foundation
@testable import Core

// MARK: - Fixture loading

private enum SystemFixtureError: Error { case notFound(String) }

private func loadSystemFixture(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw SystemFixtureError.notFound(name)
    }
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - BuilderStatus decode

@Test func builderStatusDecodesRunningFixture() throws {
    let json = try loadSystemFixture("builder-status.json")
    let status = try BuilderStatus(parsingJSON: json)

    #expect(status.isRunning)
    #expect(status.image == "ghcr.io/apple/container-builder-shim/builder:0.12.0")
    #expect(status.cpus == 2)
    #expect(status.memoryInBytes == 2_147_483_648)
}

@Test func builderStatusEmptyArrayIsStopped() throws {
    let status = try BuilderStatus(parsingJSON: "[]")
    #expect(!status.isRunning)
    #expect(status.image == nil)
    #expect(status.cpus == nil)
}

@Test func builderStatusNonRunningStateIsNotRunning() throws {
    let json = #"[{"status":{"state":"stopped"},"configuration":{"resources":{"cpus":2,"memoryInBytes":1024}}}]"#
    let status = try BuilderStatus(parsingJSON: json)
    #expect(!status.isRunning)
    #expect(status.cpus == 2)
}

@Test func builderStatusMalformedThrows() {
    #expect(throws: ContainerError.self) {
        _ = try BuilderStatus(parsingJSON: "not json")
    }
}

// MARK: - BuilderStatus argv

@Test func builderStatusInvokesExactArgvAndDecodes() async throws {
    let json = try loadSystemFixture("builder-status.json")
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: json, stderr: ""))
    let service = CLIContainerService(runner: mock, binaryPath: "/opt/homebrew/bin/container")

    let status = try await service.builderStatus()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "builder", "status", "--format", "json"]])
    #expect(status.isRunning)
    #expect(status.cpus == 2)
}

@Test func builderStartInvokesExactArgvWithResources() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
    let service = CLIContainerService(runner: mock, binaryPath: "/opt/homebrew/bin/container")

    try await service.builderStart(cpus: 4, memory: "4096m")

    #expect(mock.calls == [["/opt/homebrew/bin/container", "builder", "start", "-c", "4", "-m", "4096m"]])
}

@Test func builderStartOmitsNilResources() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
    let service = CLIContainerService(runner: mock, binaryPath: "/opt/homebrew/bin/container")

    try await service.builderStart(cpus: nil, memory: nil)

    #expect(mock.calls == [["/opt/homebrew/bin/container", "builder", "start"]])
}

@Test func builderStopInvokesExactArgv() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
    let service = CLIContainerService(runner: mock, binaryPath: "/opt/homebrew/bin/container")

    try await service.builderStop()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "builder", "stop"]])
}

@Test func builderDeleteInvokesExactArgv() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
    let service = CLIContainerService(runner: mock, binaryPath: "/opt/homebrew/bin/container")

    try await service.builderDelete()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "builder", "delete", "-f"]])
}

// MARK: - SystemVersion decode

@Test func systemVersionDecodesFixture() throws {
    let json = try loadSystemFixture("system-version.json")
    let versions = try SystemVersion.parse(json: json)

    #expect(versions.count == 2)
    #expect(versions.first?.appName == "container")
    #expect(versions.first?.version == "1.0.0")
    #expect(versions.contains { $0.appName == "container-apiserver" })
}

@Test func systemVersionInvokesExactArgvAndDecodes() async throws {
    let json = try loadSystemFixture("system-version.json")
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: json, stderr: ""))
    let service = CLIContainerService(runner: mock, binaryPath: "/opt/homebrew/bin/container")

    let versions = try await service.systemVersion()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "system", "version", "--format", "json"]])
    #expect(versions.first?.appName == "container")
    #expect(versions.first?.version == "1.0.0")
}

// MARK: - stopDaemon argv

@Test func stopDaemonInvokesExactArgv() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "", stderr: ""))
    let service = CLIContainerService(runner: mock, binaryPath: "/opt/homebrew/bin/container")

    try await service.stopDaemon()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "system", "stop"]])
}

// MARK: - SystemProperties TOML parser

@Test func systemPropertiesParsesFixture() throws {
    let toml = try loadSystemFixture("system-property.toml")
    let props = SystemProperties(parsingTOML: toml)

    #expect(props.buildCPUs == 2)
    #expect(props.buildMemory == "2048mb")
    #expect(props.containerCPUs == 4)
    #expect(props.containerMemory == "1gb")
    // Quoted string value has quotes stripped.
    #expect(props.value(section: "build", key: "image") == "ghcr.io/apple/container-builder-shim/builder:0.12.0")
    // Bare boolean kept as a string.
    #expect(props.value(section: "build", key: "rosetta") == "true")
    // Other sections present.
    #expect(props.value(section: "machine", key: "cpus") == "5")
    #expect(props.value(section: "registry", key: "domain") == "docker.io")
    // Empty section header round-trips as an empty dictionary.
    #expect(props.sections["dns"]?.isEmpty == true)
}

@Test func systemPropertiesToleratesCommentsAndBlankLines() {
    let toml = """
    # a comment

    [build]
    cpus = 8
      memory = "16gb"

    # trailing comment
    """
    let props = SystemProperties(parsingTOML: toml)
    #expect(props.buildCPUs == 8)
    #expect(props.buildMemory == "16gb")
}

@Test func systemPropertiesInvokesExactArgvAndParses() async throws {
    let toml = try loadSystemFixture("system-property.toml")
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: toml, stderr: ""))
    let service = CLIContainerService(runner: mock, binaryPath: "/opt/homebrew/bin/container")

    let props = try await service.systemProperties()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "system", "property", "list"]])
    #expect(props.buildCPUs == 2)
    #expect(props.containerCPUs == 4)
}

// MARK: - SystemViewModel

@MainActor
@Test func systemViewModelRefreshPopulates() async throws {
    let versions = try SystemVersion.parse(json: loadSystemFixture("system-version.json"))
    let builder = try BuilderStatus(parsingJSON: loadSystemFixture("builder-status.json"))
    let props = SystemProperties(parsingTOML: try loadSystemFixture("system-property.toml"))
    let service = MockContainerService(
        daemonStatus: DaemonStatus(state: .running, appRoot: nil, installRoot: nil),
        versions: versions,
        properties: props,
        builderStatus: builder
    )
    let vm = SystemViewModel(service: service)

    #expect(vm.daemonStatus == nil)
    await vm.refresh()

    #expect(service.daemonStatusCalls == 1)
    #expect(service.systemVersionCalls == 1)
    #expect(service.builderStatusCalls == 1)
    #expect(service.systemPropertiesCalls == 1)
    #expect(vm.daemonStatus?.state == .running)
    #expect(vm.versions.count == 2)
    #expect(vm.builderStatus?.isRunning == true)
    #expect(vm.properties?.buildCPUs == 2)
    #expect(vm.lastError == nil)
}

@MainActor
@Test func systemViewModelStartBuilderThenRefreshes() async throws {
    let service = MockContainerService(builderStatus: .stopped)
    let vm = SystemViewModel(service: service)

    await vm.startBuilder(cpus: 4, memory: "4096m")

    #expect(service.builderStartCalls.count == 1)
    #expect(service.builderStartCalls.first?.cpus == 4)
    #expect(service.builderStartCalls.first?.memory == "4096m")
    #expect(service.builderStatusCalls == 1)
}

@MainActor
@Test func systemViewModelStopBuilderThenRefreshes() async {
    let service = MockContainerService()
    let vm = SystemViewModel(service: service)

    await vm.stopBuilder()

    #expect(service.builderStopCalls == 1)
    #expect(service.builderStatusCalls == 1)
}

@MainActor
@Test func systemViewModelDeleteBuilderThenRefreshes() async {
    let service = MockContainerService()
    let vm = SystemViewModel(service: service)

    await vm.deleteBuilder()

    #expect(service.builderDeleteCalls == 1)
    #expect(service.builderStatusCalls == 1)
}

@MainActor
@Test func systemViewModelStopDaemonThenRefreshes() async {
    let service = MockContainerService()
    let vm = SystemViewModel(service: service)

    await vm.stopDaemon()

    #expect(service.stopDaemonCalls == 1)
    #expect(service.daemonStatusCalls == 1)
}

@MainActor
@Test func systemViewModelRefreshDegradesOnError() async {
    let service = MockContainerService(throwOnAction: ContainerError.commandFailed("daemon down"))
    let vm = SystemViewModel(service: service)

    await vm.refresh()

    #expect(vm.lastError != nil)
}
