import Testing
import Foundation
@testable import Core

// MARK: - Fixture loading

private enum ServiceFixtureError: Error { case notFound(String) }

private func loadFixtureString(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw ServiceFixtureError.notFound(name)
    }
    return try String(contentsOf: url, encoding: .utf8)
}

/// Builds a `CLIContainerService` whose binary path resolves to a fixed value
/// (no filesystem lookup), wired to the given mock runner.
private func makeService(_ mock: MockCommandRunner) -> CLIContainerService {
    CLIContainerService(runner: mock, binaryPath: "/opt/homebrew/bin/container")
}

// MARK: - 3.2 listContainers

@Test func listContainersInvokesExactArgvAndDecodes() async throws {
    let json = try loadFixtureString("container-list.json")
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: json, stderr: ""))
    let service = makeService(mock)

    let containers = try await service.listContainers()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "list", "--all", "--format", "json"]])
    #expect(containers.count == 1)
    #expect(containers.first?.id == "fixture-demo")
    #expect(containers.first?.imageReference == "docker.io/library/alpine:latest")
    #expect(containers.first?.state == .running)
}

@Test func listContainersThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "boom"))
    let service = makeService(mock)

    await #expect(throws: ContainerError.commandFailed("boom")) {
        try await service.listContainers()
    }
}

// MARK: - stats

@Test func statsInvokesExactArgvWithIdsAndDecodes() async throws {
    let json = try loadFixtureString("stats.json")
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: json, stderr: ""))
    let service = makeService(mock)

    let stats = try await service.stats(["v2-stats", "other"])

    #expect(mock.calls == [["/opt/homebrew/bin/container", "stats", "--no-stream", "--format", "json", "v2-stats", "other"]])
    #expect(stats.count == 1)
    #expect(stats.first?.id == "v2-stats")
    #expect(stats.first?.cpuUsageUsec == 2071)
    #expect(stats.first?.memoryUsageBytes == 5_148_672)
}

@Test func statsWithEmptyIdsOmitsIdArgs() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "[]", stderr: ""))
    let service = makeService(mock)

    let stats = try await service.stats([])

    #expect(mock.calls == [["/opt/homebrew/bin/container", "stats", "--no-stream", "--format", "json"]])
    #expect(stats.isEmpty)
}

@Test func statsThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "stats boom"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("stats boom")) {
        try await service.stats([])
    }
}

// MARK: - 3.3 start / stop / remove

@Test func startInvokesExactArgv() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)
    try await service.start("abc123")
    #expect(mock.calls == [["/opt/homebrew/bin/container", "start", "abc123"]])
}

@Test func stopInvokesExactArgv() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)
    try await service.stop("abc123")
    #expect(mock.calls == [["/opt/homebrew/bin/container", "stop", "abc123"]])
}

@Test func removeInvokesDeleteArgv() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)
    try await service.remove("abc123")
    #expect(mock.calls == [["/opt/homebrew/bin/container", "delete", "abc123"]])
}


@Test func startThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "no such container"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("no such container")) {
        try await service.start("ghost")
    }
}

@Test func stopThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 2, stdout: "", stderr: "stop failed"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("stop failed")) {
        try await service.stop("ghost")
    }
}

@Test func removeThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "delete failed"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("delete failed")) {
        try await service.remove("ghost")
    }
}

// MARK: - 3.3b run

@Test func runWithPopulatedSpecBuildsExactArgvAndReturnsId() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "abc123def\n", stderr: ""))
    let service = makeService(mock)

    let spec = RunSpec(
        image: "nginx:alpine",
        name: "web",
        detached: true,
        ports: [PortMapping(hostPort: 8080, containerPort: 80)]
    )
    let id = try await service.run(spec)

    #expect(mock.calls == [[
        "/opt/homebrew/bin/container", "run",
        "-d", "--name", "web", "-p", "8080:80", "nginx:alpine",
    ]])
    #expect(id == "abc123def")
}

@Test func runWithMinimalSpecBuildsDetachedArgv() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "  xyz789  \n", stderr: ""))
    let service = makeService(mock)

    let id = try await service.run(RunSpec(image: "nginx:alpine"))

    #expect(mock.calls == [["/opt/homebrew/bin/container", "run", "-d", "nginx:alpine"]])
    #expect(id == "xyz789")
}

@Test func runWithEnvCpusMemoryAndCommandBuildsFullArgv() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "id\n", stderr: ""))
    let service = makeService(mock)

    let spec = RunSpec(
        image: "alpine:latest",
        name: "job",
        detached: false,
        ports: [PortMapping(hostPort: 5432, containerPort: 5432)],
        env: ["FOO": "bar", "ABC": "1"],
        command: ["sh", "-c", "echo hi"],
        cpus: 2,
        memoryMiB: 512
    )
    _ = try await service.run(spec)

    // Detached false omits -d; env emitted in sorted-key order (ABC before FOO).
    #expect(mock.calls == [[
        "/opt/homebrew/bin/container", "run",
        "--name", "job",
        "-e", "ABC=1", "-e", "FOO=bar",
        "-p", "5432:5432",
        "-c", "2", "-m", "512",
        "alpine:latest",
        "sh", "-c", "echo hi",
    ]])
}

@Test func runWithSingleVolumeAppendsBindMountArgv() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "id\n", stderr: ""))
    let service = makeService(mock)

    let spec = RunSpec(
        image: "alpine:latest",
        volumes: [VolumeMount(hostPath: "/Users/x/data", containerPath: "/data", readOnly: false)]
    )
    _ = try await service.run(spec)

    #expect(mock.calls == [[
        "/opt/homebrew/bin/container", "run", "-d",
        "-v", "/Users/x/data:/data",
        "alpine:latest",
    ]])
}

@Test func runWithReadOnlyVolumeAppendsRoSuffix() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "id\n", stderr: ""))
    let service = makeService(mock)

    let spec = RunSpec(
        image: "alpine:latest",
        volumes: [VolumeMount(hostPath: "/Users/x/data", containerPath: "/data", readOnly: true)]
    )
    _ = try await service.run(spec)

    #expect(mock.calls == [[
        "/opt/homebrew/bin/container", "run", "-d",
        "-v", "/Users/x/data:/data:ro",
        "alpine:latest",
    ]])
}

@Test func runWithMultipleVolumesEachGetDashV() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "id\n", stderr: ""))
    let service = makeService(mock)

    let spec = RunSpec(
        image: "alpine:latest",
        volumes: [
            VolumeMount(hostPath: "/Users/x/data", containerPath: "/data", readOnly: false),
            VolumeMount(hostPath: "/Users/x/cfg", containerPath: "/etc/app", readOnly: true),
        ]
    )
    _ = try await service.run(spec)

    #expect(mock.calls == [[
        "/opt/homebrew/bin/container", "run", "-d",
        "-v", "/Users/x/data:/data",
        "-v", "/Users/x/cfg:/etc/app:ro",
        "alpine:latest",
    ]])
}

@Test func runEmitsVolumesAfterEnvAndPortsBeforeImage() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: "id\n", stderr: ""))
    let service = makeService(mock)

    let spec = RunSpec(
        image: "alpine:latest",
        detached: false,
        ports: [PortMapping(hostPort: 8080, containerPort: 80)],
        env: ["FOO": "bar"],
        volumes: [VolumeMount(hostPath: "/Users/x/data", containerPath: "/data")]
    )
    _ = try await service.run(spec)

    #expect(mock.calls == [[
        "/opt/homebrew/bin/container", "run",
        "-e", "FOO=bar",
        "-p", "8080:80",
        "-v", "/Users/x/data:/data",
        "alpine:latest",
    ]])
}

@Test func runThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 125, stdout: "", stderr: "no such image"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("no such image")) {
        _ = try await service.run(RunSpec(image: "ghost:latest"))
    }
}

// MARK: - 3.4 listImages / removeImage

@Test func listImagesInvokesExactArgvAndDecodes() async throws {
    let json = try loadFixtureString("image-list.json")
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: json, stderr: ""))
    let service = makeService(mock)

    let images = try await service.listImages()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "image", "list", "--format", "json"]])
    #expect(images.count == 1)
    #expect(images.first?.name == "docker.io/library/alpine:latest")
    #expect(images.first?.platforms.contains("arm64") == true)
}

@Test func listImagesThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "daemon down"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("daemon down")) {
        try await service.listImages()
    }
}

@Test func removeImageInvokesImageDeleteArgv() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)
    try await service.removeImage("docker.io/library/alpine:latest")
    #expect(mock.calls == [["/opt/homebrew/bin/container", "image", "delete", "docker.io/library/alpine:latest"]])
}

@Test func removeImageThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "no such image"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("no such image")) {
        try await service.removeImage("ghost")
    }
}

@Test func imageConfigInvokesInspectArgvAndParsesEnv() async throws {
    // `image inspect` takes no --format flag; the CLI emits the same JSON shape
    // as `image list`, so we feed the inspect fixture through the mock runner.
    let json = try loadFixtureString("image-inspect.json")
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: json, stderr: ""))
    let service = makeService(mock)

    let config = try await service.imageConfig("docker.io/library/nginx:alpine")

    #expect(mock.calls == [["/opt/homebrew/bin/container", "image", "inspect", "docker.io/library/nginx:alpine"]])
    #expect(config.env["NGINX_VERSION"] == "1.31.2")
    #expect(config.exposedPorts.isEmpty)
}

@Test func imageConfigThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "image not found"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("image not found")) {
        _ = try await service.imageConfig("ghost:latest")
    }
}

// MARK: - Volumes

@Test func listVolumesInvokesExactArgvAndDecodes() async throws {
    let json = try loadFixtureString("volumes.json")
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: json, stderr: ""))
    let service = makeService(mock)

    let volumes = try await service.listVolumes()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "volume", "list", "--format", "json"]])
    #expect(volumes.count == 1)
    #expect(volumes.first?.id == "acg-v3-probe")
    #expect(volumes.first?.name == "acg-v3-probe")
    #expect(volumes.first?.driver == "local")
    #expect(volumes.first?.sizeInBytes == 67_108_864)
    #expect(volumes.first?.configuration.options?["size"] == "64M")
}

@Test func listVolumesThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "daemon down"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("daemon down")) {
        try await service.listVolumes()
    }
}

@Test func createVolumeWithSizeAndLabelsBuildsExactArgv() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)

    try await service.createVolume(name: "data", size: "64M", labels: ["env": "prod", "app": "web"])

    // -s before labels; labels emitted in sorted-key order (app before env); name last.
    #expect(mock.calls == [[
        "/opt/homebrew/bin/container", "volume", "create",
        "-s", "64M",
        "--label", "app=web",
        "--label", "env=prod",
        "data",
    ]])
}

@Test func createVolumeWithoutSizeOmitsSizeFlag() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)

    try await service.createVolume(name: "data", size: nil, labels: [:])

    #expect(mock.calls == [["/opt/homebrew/bin/container", "volume", "create", "data"]])
}

@Test func createVolumeThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "already exists"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("already exists")) {
        try await service.createVolume(name: "data", size: nil, labels: [:])
    }
}

@Test func removeVolumeInvokesDeleteArgv() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)
    try await service.removeVolume("data")
    #expect(mock.calls == [["/opt/homebrew/bin/container", "volume", "delete", "data"]])
}

@Test func removeVolumeThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "no such volume"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("no such volume")) {
        try await service.removeVolume("ghost")
    }
}

@Test func pruneVolumesInvokesExactArgv() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)
    try await service.pruneVolumes()
    #expect(mock.calls == [["/opt/homebrew/bin/container", "volume", "prune"]])
}

// MARK: - Networks

@Test func listNetworksInvokesExactArgvAndDecodes() async throws {
    let json = try loadFixtureString("networks.json")
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: json, stderr: ""))
    let service = makeService(mock)

    let networks = try await service.listNetworks()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "network", "list", "--format", "json"]])
    #expect(networks.count == 1)
    #expect(networks.first?.id == "default")
    #expect(networks.first?.name == "default")
    #expect(networks.first?.gateway == "192.168.64.1")
    #expect(networks.first?.subnet == "192.168.64.0/24")
}

@Test func listNetworksThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "daemon down"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("daemon down")) {
        try await service.listNetworks()
    }
}

@Test func createNetworkWithInternalSubnetAndLabelsBuildsExactArgv() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)

    try await service.createNetwork(name: "net", internal: true, subnet: "10.0.0.0/24", labels: ["env": "prod", "app": "web"])

    // --internal first, then --subnet, then labels in sorted-key order (app before env), name last.
    #expect(mock.calls == [[
        "/opt/homebrew/bin/container", "network", "create",
        "--internal",
        "--subnet", "10.0.0.0/24",
        "--label", "app=web",
        "--label", "env=prod",
        "net",
    ]])
}

@Test func createNetworkWithoutInternalOrSubnetOmitsFlags() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)

    try await service.createNetwork(name: "net", internal: false, subnet: nil, labels: [:])

    #expect(mock.calls == [["/opt/homebrew/bin/container", "network", "create", "net"]])
}

@Test func createNetworkThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "already exists"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("already exists")) {
        try await service.createNetwork(name: "net", internal: false, subnet: nil, labels: [:])
    }
}

@Test func removeNetworkInvokesDeleteArgv() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)
    try await service.removeNetwork("net")
    #expect(mock.calls == [["/opt/homebrew/bin/container", "network", "delete", "net"]])
}

@Test func removeNetworkThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "no such network"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("no such network")) {
        try await service.removeNetwork("ghost")
    }
}

// MARK: - 3.5 daemonStatus / startDaemon

@Test func daemonStatusInvokesExactArgvAndParses() async throws {
    let text = try loadFixtureString("system-status.txt")
    let mock = MockCommandRunner(result: .init(exitCode: 0, stdout: text, stderr: ""))
    let service = makeService(mock)

    let status = try await service.daemonStatus()

    #expect(mock.calls == [["/opt/homebrew/bin/container", "system", "status"]])
    #expect(status.state == .running)
    #expect(status.appRoot == "/Users/yuf/Library/Application Support/com.apple.container/")
}

@Test func daemonStatusThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "apiserver unreachable"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("apiserver unreachable")) {
        try await service.daemonStatus()
    }
}

@Test func startDaemonInvokesSystemStartArgv() async throws {
    let mock = MockCommandRunner()
    let service = makeService(mock)
    try await service.startDaemon()
    #expect(mock.calls == [["/opt/homebrew/bin/container", "system", "start", "--enable-kernel-install"]])
}

@Test func startDaemonThrowsCommandFailedOnNonZeroExit() async throws {
    let mock = MockCommandRunner(result: .init(exitCode: 1, stdout: "", stderr: "kernel install failed"))
    let service = makeService(mock)
    await #expect(throws: ContainerError.commandFailed("kernel install failed")) {
        try await service.startDaemon()
    }
}

// MARK: - 3.6 logs stream

@Test func logsStreamYieldsLinesInOrderWithoutFollow() async throws {
    let mock = MockCommandRunner(streamLines: ["line1", "line2", "line3"])
    let service = makeService(mock)

    var received: [String] = []
    for try await line in service.logs("abc123", follow: false) {
        received.append(line)
    }

    #expect(received == ["line1", "line2", "line3"])
    #expect(mock.calls == [["/opt/homebrew/bin/container", "logs", "abc123"]])
}

@Test func logsFollowAddsFollowFlagToArgv() async throws {
    let mock = MockCommandRunner(streamLines: ["tailing"])
    let service = makeService(mock)

    for try await _ in service.logs("abc123", follow: true) {}

    #expect(mock.calls == [["/opt/homebrew/bin/container", "logs", "--follow", "abc123"]])
}

@Test func logsStreamErrorPathSurfaces() async throws {
    let mock = MockCommandRunner(
        streamLines: ["partial"],
        streamError: ContainerError.commandFailed("log read failed")
    )
    let service = makeService(mock)

    var received: [String] = []
    await #expect(throws: ContainerError.commandFailed("log read failed")) {
        for try await line in service.logs("abc123", follow: false) {
            received.append(line)
        }
    }
    #expect(received == ["partial"])
}

@Test func logsStreamCancellationStopsConsumption() async throws {
    // A large pre-seeded stream; the consuming task is cancelled before it
    // iterates. The mock honors cancellation (checks `Task.isCancelled` before
    // each yield), so we must NOT drain all 1000 lines.
    let mock = MockCommandRunner(streamLines: (0..<1000).map { "line\($0)" })
    let service = makeService(mock)

    let counter = Counter()
    let task = Task {
        for try await _ in service.logs("abc123", follow: true) {
            await counter.increment()
        }
    }
    task.cancel()
    _ = await task.result
    let drained = await counter.value
    #expect(drained < 1000)
}

/// Async-safe counter for cancellation assertions.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

// MARK: - 3.7 pull stream

@Test func pullImageStreamYieldsProgressInOrderWithArgv() async throws {
    let mock = MockCommandRunner(streamLines: ["Pulling fs layer", "Downloading 50%", "Pull complete"])
    let service = makeService(mock)

    var received: [String] = []
    for try await line in service.pullImage("docker.io/library/alpine:latest") {
        received.append(line)
    }

    #expect(received == ["Pulling fs layer", "Downloading 50%", "Pull complete"])
    #expect(mock.calls == [["/opt/homebrew/bin/container", "image", "pull", "docker.io/library/alpine:latest"]])
}

@Test func pullImageStreamErrorPathSurfaces() async throws {
    let mock = MockCommandRunner(
        streamLines: ["Pulling fs layer"],
        streamError: ContainerError.commandFailed("manifest unknown")
    )
    let service = makeService(mock)

    var received: [String] = []
    await #expect(throws: ContainerError.commandFailed("manifest unknown")) {
        for try await line in service.pullImage("ghost:latest") {
            received.append(line)
        }
    }
    #expect(received == ["Pulling fs layer"])
}

// MARK: - 3.8 build stream

@Test func buildStreamYieldsLogLinesWithTaggedArgv() async throws {
    let mock = MockCommandRunner(streamLines: ["STEP 1/3", "STEP 2/3", "Successfully built"])
    let service = makeService(mock)

    var received: [String] = []
    for try await line in service.build(dockerfile: "Dockerfile", context: ".", tag: "myapp:latest") {
        received.append(line)
    }

    #expect(received == ["STEP 1/3", "STEP 2/3", "Successfully built"])
    #expect(mock.calls == [[
        "/opt/homebrew/bin/container", "build",
        "--tag", "myapp:latest",
        "--file", "Dockerfile", ".",
    ]])
}

@Test func buildStreamOmitsTagFlagWhenTagEmpty() async throws {
    let mock = MockCommandRunner(streamLines: ["STEP 1/1"])
    let service = makeService(mock)

    for try await _ in service.build(dockerfile: "build/Dockerfile", context: "ctx", tag: "") {}

    #expect(mock.calls == [[
        "/opt/homebrew/bin/container", "build",
        "--file", "build/Dockerfile", "ctx",
    ]])
}

@Test func buildStreamErrorPathSurfaces() async throws {
    let mock = MockCommandRunner(
        streamLines: ["STEP 1/3"],
        streamError: ContainerError.commandFailed("build failed")
    )
    let service = makeService(mock)

    var received: [String] = []
    await #expect(throws: ContainerError.commandFailed("build failed")) {
        for try await line in service.build(dockerfile: "Dockerfile", context: ".", tag: "t:1") {
            received.append(line)
        }
    }
    #expect(received == ["STEP 1/3"])
}

// MARK: - Interactive exec (terminal)

@Test func execInvocationBuildsInteractivePtyArgv() async throws {
    let service = makeService(MockCommandRunner())
    let inv = try await service.execInvocation(id: "acg-demo-web", command: ["sh"])
    #expect(inv.executable == "/opt/homebrew/bin/container")
    #expect(inv.arguments == ["exec", "-i", "-t", "acg-demo-web", "sh"])
}

@Test func execShellInvocationDefaultsToSh() async throws {
    let service = makeService(MockCommandRunner())
    let inv = try await service.execShellInvocation(id: "abc123")
    #expect(inv.executable == "/opt/homebrew/bin/container")
    #expect(inv.arguments == ["exec", "-i", "-t", "abc123", "sh"])
}

@Test func execInvocationPassesMultiWordCommand() async throws {
    let service = makeService(MockCommandRunner())
    let inv = try await service.execInvocation(id: "id1", command: ["/bin/sh", "-l"])
    #expect(inv.arguments == ["exec", "-i", "-t", "id1", "/bin/sh", "-l"])
}

@Test func execInvocationThrowsBinaryNotFoundWhenUnresolved() async throws {
    // A service backed by a CLI that resolves nothing (override path missing).
    let cli = ContainerCLI(runner: MockCommandRunner(), overridePath: "/nonexistent/container")
    let service = CLIContainerService(runner: MockCommandRunner(), cli: cli)
    await #expect(throws: ContainerError.binaryNotFound) {
        _ = try await service.execInvocation(id: "x", command: ["sh"])
    }
}
