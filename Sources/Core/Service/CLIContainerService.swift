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

    public func stop(_ id: String, signal: String?, timeout: Int?) async throws {
        var args = ["stop"]
        if let signal { args.append(contentsOf: ["-s", signal]) }
        if let timeout { args.append(contentsOf: ["-t", String(timeout)]) }
        args.append(id)
        _ = try await runChecked(args)
    }

    public func kill(_ id: String, signal: String?) async throws {
        var args = ["kill"]
        if let signal { args.append(contentsOf: ["-s", signal]) }
        args.append(id)
        _ = try await runChecked(args)
    }

    public func remove(_ id: String, force: Bool) async throws {
        var args = ["delete"]
        if force { args.append("-f") }
        args.append(id)
        _ = try await runChecked(args)
    }

    public func deleteAll() async throws {
        _ = try await runChecked(["delete", "--all"])
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
        // Advanced options (Phase 3), in a deterministic order after the
        // existing -e/-p/-v/-c/-m flags and before the image.
        if spec.autoRemove { args.append("--rm") }
        if spec.readOnly { args.append("--read-only") }
        if spec.useInit { args.append("--init") }
        if let user = spec.user { args.append(contentsOf: ["--user", user]) }
        if let workdir = spec.workdir { args.append(contentsOf: ["--workdir", workdir]) }
        if let entrypoint = spec.entrypoint { args.append(contentsOf: ["--entrypoint", entrypoint]) }
        // Sorted keys → deterministic argv.
        for key in spec.labels.keys.sorted() {
            args.append(contentsOf: ["--label", "\(key)=\(spec.labels[key]!)"])
        }
        if let envFile = spec.envFile { args.append(contentsOf: ["--env-file", envFile]) }
        for cap in spec.capAdd { args.append(contentsOf: ["--cap-add", cap]) }
        for cap in spec.capDrop { args.append(contentsOf: ["--cap-drop", cap]) }
        if let network = spec.network { args.append(contentsOf: ["--network", network]) }
        if let platform = spec.platform { args.append(contentsOf: ["--platform", platform]) }
        args.append(spec.image)
        args.append(contentsOf: spec.command)

        let result = try await runChecked(args)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func pruneContainers() async throws {
        _ = try await runChecked(["prune"])
    }

    public func exportContainer(_ id: String, to path: String) async throws {
        _ = try await runChecked(["export", "--output", path, id])
    }

    public func copyToContainer(localPath: String, containerId: String, containerPath: String) async throws {
        // `copy <localPath> <id>:<containerPath>` — the destination is the
        // container side, formatted as `<id>:<path>`.
        _ = try await runChecked(["copy", localPath, "\(containerId):\(containerPath)"])
    }

    public func copyFromContainer(containerId: String, containerPath: String, localPath: String) async throws {
        // `copy <id>:<containerPath> <localPath>` — the source is the container
        // side, formatted as `<id>:<path>`.
        _ = try await runChecked(["copy", "\(containerId):\(containerPath)", localPath])
    }

    public func stats(_ ids: [String]) async throws -> [ContainerStats] {
        var args = ["stats", "--no-stream", "--format", "json"]
        args.append(contentsOf: ids)
        let result = try await runChecked(args)
        return try decode([ContainerStats].self, from: result.stdout)
    }

    // MARK: - Images

    public func listImages() async throws -> [ContainerImage] {
        let result = try await runChecked(["image", "list", "--format", "json"])
        return try decode([ContainerImage].self, from: result.stdout)
    }

    /// Run-time defaults for an image via `image inspect <ref>`. Apple's
    /// `container` `image inspect` takes no `--format` flag (verified: it
    /// rejects `--format`) and emits the same `[ContainerImage]` JSON array as
    /// `image list`, including the per-variant `config.config` blob carrying
    /// `Env`. Exposed ports are not reported by the runtime, so
    /// `ImageConfig.exposedPorts` is currently always empty.
    public func imageConfig(_ ref: String) async throws -> ImageConfig {
        let result = try await runChecked(["image", "inspect", ref])
        let images = try decode([ContainerImage].self, from: result.stdout)
        // `inspect <ref>` returns a single-element array for one ref.
        let match = images.first { $0.name == ref } ?? images.first
        return ImageConfig(runtimeConfig: match?.defaultRuntimeConfig)
    }

    public func removeImage(_ id: String) async throws {
        _ = try await runChecked(["image", "delete", id])
    }

    public func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        stream(["image", "pull", ref])
    }

    public func pruneImages() async throws {
        _ = try await runChecked(["image", "prune"])
    }

    public func tagImage(source: String, newRef: String) async throws {
        _ = try await runChecked(["image", "tag", source, newRef])
    }

    public func pushImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        stream(["image", "push", ref])
    }

    public func saveImage(_ ref: String, to path: String) async throws {
        _ = try await runChecked(["image", "save", "--output", path, ref])
    }

    public func loadImage(from path: String) async throws {
        _ = try await runChecked(["image", "load", "--input", path])
    }

    // MARK: - Volumes

    public func listVolumes() async throws -> [ContainerVolume] {
        let result = try await runChecked(["volume", "list", "--format", "json"])
        return try decode([ContainerVolume].self, from: result.stdout)
    }

    public func createVolume(name: String, size: String?, labels: [String: String]) async throws {
        var args = ["volume", "create"]
        if let size { args.append(contentsOf: ["-s", size]) }
        // Sorted keys → deterministic argv.
        for key in labels.keys.sorted() {
            args.append(contentsOf: ["--label", "\(key)=\(labels[key]!)"])
        }
        args.append(name)
        _ = try await runChecked(args)
    }

    public func removeVolume(_ name: String) async throws {
        _ = try await runChecked(["volume", "delete", name])
    }

    public func pruneVolumes() async throws {
        _ = try await runChecked(["volume", "prune"])
    }

    // MARK: - Networks

    public func listNetworks() async throws -> [ContainerNetwork] {
        let result = try await runChecked(["network", "list", "--format", "json"])
        return try decode([ContainerNetwork].self, from: result.stdout)
    }

    public func createNetwork(name: String, internal isInternal: Bool, subnet: String?, labels: [String: String]) async throws {
        var args = ["network", "create"]
        if isInternal { args.append("--internal") }
        if let subnet { args.append(contentsOf: ["--subnet", subnet]) }
        // Sorted keys → deterministic argv.
        for key in labels.keys.sorted() {
            args.append(contentsOf: ["--label", "\(key)=\(labels[key]!)"])
        }
        args.append(name)
        _ = try await runChecked(args)
    }

    public func removeNetwork(_ name: String) async throws {
        _ = try await runChecked(["network", "delete", name])
    }

    // MARK: - Logs

    public func logs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> AsyncThrowingStream<String, Error> {
        var args = ["logs"]
        if boot { args.append("--boot") }
        if let tail { args.append(contentsOf: ["-n", String(tail)]) }
        if follow { args.append("--follow") }
        args.append(id)
        return stream(args)
    }

    // MARK: - Disk usage

    public func systemDF() async throws -> DiskUsage {
        let result = try await runChecked(["system", "df", "--format", "json"])
        return try decode(DiskUsage.self, from: result.stdout)
    }

    // MARK: - Daemon

    public func daemonStatus() async throws -> DaemonStatus {
        let result = try await runChecked(["system", "status"])
        return DaemonStatus(parsingText: result.stdout)
    }

    public func startDaemon() async throws {
        _ = try await runChecked(["system", "start", "--enable-kernel-install"])
    }

    public func stopDaemon() async throws {
        _ = try await runChecked(["system", "stop"])
    }

    public func systemVersion() async throws -> [SystemVersion] {
        let result = try await runChecked(["system", "version", "--format", "json"])
        return try SystemVersion.parse(json: result.stdout)
    }

    public func systemProperties() async throws -> SystemProperties {
        // `system property list` emits TOML; there is NO --format json and no
        // write path on a default install (verified against container v1.0.0).
        let result = try await runChecked(["system", "property", "list"])
        return SystemProperties(parsingTOML: result.stdout)
    }

    // MARK: - Builder

    public func builderStatus() async throws -> BuilderStatus {
        let result = try await runChecked(["builder", "status", "--format", "json"])
        return try BuilderStatus(parsingJSON: result.stdout)
    }

    public func builderStart(cpus: Int?, memory: String?) async throws {
        var args = ["builder", "start"]
        if let cpus { args.append(contentsOf: ["-c", String(cpus)]) }
        if let memory { args.append(contentsOf: ["-m", memory]) }
        _ = try await runChecked(args)
    }

    public func builderStop() async throws {
        _ = try await runChecked(["builder", "stop"])
    }

    public func builderDelete() async throws {
        _ = try await runChecked(["builder", "delete", "-f"])
    }

    // MARK: - Build

    public func build(dockerfile: String, context: String, tag: String, options: BuildOptions) -> AsyncThrowingStream<String, Error> {
        var args = ["build"]
        if !tag.isEmpty {
            args.append(contentsOf: ["--tag", tag])
        }
        // Advanced options (Phase 3), in a deterministic order after --tag and
        // before --file <dockerfile> <context>. Map keys are sorted so argv is
        // stable. Verified against `container build --help` (container v1.0.0).
        for key in options.buildArgs.keys.sorted() {
            args.append(contentsOf: ["--build-arg", "\(key)=\(options.buildArgs[key]!)"])
        }
        if let target = options.target { args.append(contentsOf: ["--target", target]) }
        if options.noCache { args.append("--no-cache") }
        if options.pull { args.append("--pull") }
        for key in options.labels.keys.sorted() {
            args.append(contentsOf: ["--label", "\(key)=\(options.labels[key]!)"])
        }
        if let platform = options.platform { args.append(contentsOf: ["--platform", platform]) }
        if let cpus = options.cpus { args.append(contentsOf: ["-c", String(cpus)]) }
        if let mem = options.memoryMiB { args.append(contentsOf: ["-m", String(mem)]) }
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

    public func imageShellInvocation(ref: String) async throws -> ProcessInvocation {
        let path = try await binaryPath()
        // `run --rm -i -t <ref> sh` spins up a throwaway container from the
        // image, attaches an interactive PTY (matching the terminal widget's
        // PTY), and removes the container on exit (`--rm`). Verified against
        // `container run --help` (container v1.0.0).
        return ProcessInvocation(executable: path, arguments: ["run", "--rm", "-i", "-t", ref, "sh"])
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
