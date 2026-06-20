import Foundation

/// `ContainerService` implemented by shelling out to the `container` CLI.
///
/// All process execution flows through the injected `CommandRunner`; the binary
/// path is resolved once via `ContainerCLI` (or supplied directly in tests).
/// Every non-streaming method runs to completion and throws
/// `ContainerError.commandFailed(stderr)` on a non-zero exit. Streaming methods
/// surface the runner's stream verbatim (its `.finish(throwing:)` propagates).
public struct CLIContainerService: ContainerService {
    private let runner: CommandRunner
    private let cli: ContainerCLI?
    private let fixedBinaryPath: String?

    /// Production initializer: resolves the binary lazily through `ContainerCLI`.
    public init(runner: CommandRunner, cli: ContainerCLI) {
        self.runner = runner
        self.cli = cli
        self.fixedBinaryPath = nil
    }

    /// Test/explicit initializer: uses a pre-resolved binary path, skipping
    /// filesystem discovery.
    public init(runner: CommandRunner, binaryPath: String) {
        self.runner = runner
        self.cli = nil
        self.fixedBinaryPath = binaryPath
    }

    // MARK: - Binary resolution

    private func binaryPath() async throws -> String {
        if let path = fixedBinaryPath { return path }
        guard let resolved = await cli?.resolveBinaryPath() else {
            throw ContainerError.binaryNotFound
        }
        return resolved
    }

    // MARK: - Command execution helpers

    /// Run argv to completion, throwing `commandFailed(stderr)` on non-zero exit.
    private func runChecked(_ args: [String]) async throws -> CommandResult {
        let path = try await binaryPath()
        let result = try await runner.run(path, args)
        guard result.exitCode == 0 else {
            throw ContainerError.commandFailed(result.stderr)
        }
        return result
    }

    // MARK: - Containers

    public func listContainers() async throws -> [Container] {
        let result = try await runChecked(["list", "--all", "--format", "json"])
        return try decode([Container].self, from: result.stdout)
    }

    public func start(_ id: String) async throws {
        _ = try await runChecked(["start", id])
    }

    public func stop(_ id: String) async throws {
        _ = try await runChecked(["stop", id])
    }

    public func remove(_ id: String) async throws {
        _ = try await runChecked(["delete", id])
    }

    public func run(_ spec: RunSpec) async throws -> String {
        var args = ["run"]
        if spec.detached { args.append("-d") }
        if let name = spec.name { args.append(contentsOf: ["--name", name]) }
        // Sorted keys → deterministic argv.
        for key in spec.env.keys.sorted() {
            args.append(contentsOf: ["-e", "\(key)=\(spec.env[key]!)"])
        }
        for port in spec.ports {
            args.append(contentsOf: ["-p", "\(port.hostPort):\(port.containerPort)"])
        }
        for volume in spec.volumes {
            let spec = "\(volume.hostPath):\(volume.containerPath)" + (volume.readOnly ? ":ro" : "")
            args.append(contentsOf: ["-v", spec])
        }
        if let cpus = spec.cpus { args.append(contentsOf: ["-c", String(cpus)]) }
        if let mem = spec.memoryMiB { args.append(contentsOf: ["-m", String(mem)]) }
        args.append(spec.image)
        args.append(contentsOf: spec.command)

        let result = try await runChecked(args)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Images

    public func listImages() async throws -> [ContainerImage] {
        let result = try await runChecked(["image", "list", "--format", "json"])
        return try decode([ContainerImage].self, from: result.stdout)
    }

    public func removeImage(_ id: String) async throws {
        _ = try await runChecked(["image", "delete", id])
    }

    public func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        stream(["image", "pull", ref])
    }

    // MARK: - Logs

    public func logs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        var args = ["logs"]
        if follow { args.append("--follow") }
        args.append(id)
        return stream(args)
    }

    // MARK: - Daemon

    public func daemonStatus() async throws -> DaemonStatus {
        let result = try await runChecked(["system", "status"])
        return DaemonStatus(parsingText: result.stdout)
    }

    public func startDaemon() async throws {
        _ = try await runChecked(["system", "start", "--enable-kernel-install"])
    }

    // MARK: - Build

    public func build(dockerfile: String, context: String, tag: String) -> AsyncThrowingStream<String, Error> {
        var args = ["build"]
        if !tag.isEmpty {
            args.append(contentsOf: ["--tag", tag])
        }
        args.append(contentsOf: ["--file", dockerfile, context])
        return stream(args)
    }

    // MARK: - Interactive exec (terminal)

    public func execInvocation(id: String, command: [String]) async throws -> ProcessInvocation {
        let path = try await binaryPath()
        // `-i -t` gives an interactive PTY-attached session, matching the
        // terminal widget's PTY. The command (default `sh`) runs inside the
        // container after the id.
        var args = ["exec", "-i", "-t", id]
        args.append(contentsOf: command)
        return ProcessInvocation(executable: path, arguments: args)
    }

    // MARK: - Streaming helper

    /// Resolve the binary and forward the runner's stream. Because
    /// `AsyncThrowingStream` factories are synchronous, this resolves the path
    /// up front via the injected fixed path. When only a `ContainerCLI` was
    /// supplied, resolution is performed lazily inside the stream's task.
    private func stream(_ args: [String]) -> AsyncThrowingStream<String, Error> {
        if let path = fixedBinaryPath {
            return runner.stream(path, args)
        }
        // Lazy async resolution wrapped in a stream.
        let runner = self.runner
        let cli = self.cli
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let path = await cli?.resolveBinaryPath() else {
                    continuation.finish(throwing: ContainerError.binaryNotFound)
                    return
                }
                do {
                    for try await line in runner.stream(path, args) {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Decoding

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ContainerError.decodingFailed(String(describing: error))
        }
    }
}
