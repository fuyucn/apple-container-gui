import Foundation

/// Errors surfaced by a `ContainerService`.
public enum ContainerError: Error, Equatable, Sendable {
    /// The `container` binary could not be located on this machine.
    case binaryNotFound
    /// A CLI invocation exited non-zero; carries the captured stderr.
    case commandFailed(String)
    /// The CLI returned output that could not be decoded into the model.
    case decodingFailed(String)
}

/// A fully-resolved invocation for spawning a process directly (used by the
/// in-app terminal, which hands `executable` + `arguments` to a PTY rather than
/// going through `CommandRunner`). `executable` is the absolute path to the
/// `container` binary; `arguments` is the complete argv after it.
public struct ProcessInvocation: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// A single published-port mapping: `hostPort:containerPort`.
public struct PortMapping: Sendable, Equatable {
    public let hostPort: Int
    public let containerPort: Int

    public init(hostPort: Int, containerPort: Int) {
        self.hostPort = hostPort
        self.containerPort = containerPort
    }
}

/// A single bind-mount: maps an absolute `hostPath` to a `containerPath`
/// (`-v host:container`, with `:ro` appended when `readOnly`). Lets stateful
/// services persist to a host directory.
public struct VolumeMount: Sendable, Equatable {
    public let hostPath: String
    public let containerPath: String
    public let readOnly: Bool

    public init(hostPath: String, containerPath: String, readOnly: Bool = false) {
        self.hostPath = hostPath
        self.containerPath = containerPath
        self.readOnly = readOnly
    }
}

/// Desired configuration for creating + running a new container, translated by
/// `CLIContainerService.run` into `container run` argv. Only `image` is
/// required; everything else is optional and omitted from argv when empty/nil.
public struct RunSpec: Sendable {
    /// Image reference to run (required), e.g. `nginx:alpine`.
    public let image: String
    /// Optional container name (`--name`).
    public let name: String?
    /// Run detached (`-d`). Defaults to true.
    public let detached: Bool
    /// Published port mappings (`-p host:container`).
    public let ports: [PortMapping]
    /// Environment variables (`-e K=V`). Emitted in sorted key order so argv is
    /// deterministic.
    public let env: [String: String]
    /// Bind mounts (`-v host:container[:ro]`). Emitted in the order supplied.
    public let volumes: [VolumeMount]
    /// Optional command + args to run in the container, after the image.
    public let command: [String]
    /// Optional CPU count (`-c`).
    public let cpus: Int?
    /// Optional memory in MiB (`-m`).
    public let memoryMiB: Int?

    // MARK: - Advanced options (Phase 3)
    //
    // All optional and omitted from argv when nil/false/empty, so existing
    // callers and tests keep compiling. Emitted in a deterministic order after
    // the existing -e/-p/-v/-c/-m flags and before the image (see
    // `CLIContainerService.run`).

    /// Remove the container after it stops (`--rm`).
    public let autoRemove: Bool
    /// Mount the root filesystem read-only (`--read-only`).
    public let readOnly: Bool
    /// Run an init process inside the container that forwards signals and reaps
    /// processes (`--init`).
    public let useInit: Bool
    /// Override the process user (`-u`/`--user`, format `name|uid[:gid]`).
    public let user: String?
    /// Initial working directory inside the container (`-w`/`--workdir`).
    public let workdir: String?
    /// Override the image entrypoint (`--entrypoint`).
    public let entrypoint: String?
    /// Container labels (`-l`/`--label k=v`). Emitted in sorted key order so
    /// argv is deterministic.
    public let labels: [String: String]
    /// Path to a file of environment variables (`--env-file`).
    public let envFile: String?
    /// Linux capabilities to add (`--cap-add`), one flag each, in the order
    /// supplied.
    public let capAdd: [String]
    /// Linux capabilities to drop (`--cap-drop`), one flag each, in the order
    /// supplied.
    public let capDrop: [String]
    /// Attach to a named network (`--network`).
    public let network: String?
    /// Platform for a multi-platform image (`--platform`, format `os/arch`).
    public let platform: String?

    public init(
        image: String,
        name: String? = nil,
        detached: Bool = true,
        ports: [PortMapping] = [],
        env: [String: String] = [:],
        volumes: [VolumeMount] = [],
        command: [String] = [],
        cpus: Int? = nil,
        memoryMiB: Int? = nil,
        autoRemove: Bool = false,
        readOnly: Bool = false,
        useInit: Bool = false,
        user: String? = nil,
        workdir: String? = nil,
        entrypoint: String? = nil,
        labels: [String: String] = [:],
        envFile: String? = nil,
        capAdd: [String] = [],
        capDrop: [String] = [],
        network: String? = nil,
        platform: String? = nil
    ) {
        self.image = image
        self.name = name
        self.detached = detached
        self.ports = ports
        self.env = env
        self.volumes = volumes
        self.command = command
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.autoRemove = autoRemove
        self.readOnly = readOnly
        self.useInit = useInit
        self.user = user
        self.workdir = workdir
        self.entrypoint = entrypoint
        self.labels = labels
        self.envFile = envFile
        self.capAdd = capAdd
        self.capDrop = capDrop
        self.network = network
        self.platform = platform
    }
}

/// Advanced configuration for `container build`, translated by
/// `CLIContainerService.build` into extra build argv. All fields are optional
/// and omitted from argv when empty/nil/false, so an empty `BuildOptions()`
/// reproduces the original `--tag/--file/context` invocation. Emitted in a
/// deterministic order after `--tag` and before `--file <dockerfile> <context>`
/// (see `CLIContainerService.build`).
public struct BuildOptions: Sendable, Equatable {
    /// Build-time variables (`--build-arg k=v`, repeatable). Emitted in sorted
    /// key order so argv is deterministic.
    public let buildArgs: [String: String]
    /// Target build stage (`--target <stage>`).
    public let target: String?
    /// Do not use the build cache (`--no-cache`).
    public let noCache: Bool
    /// Pull the latest base image (`--pull`).
    public let pull: Bool
    /// Image labels (`--label k=v`, repeatable). Emitted in sorted key order so
    /// argv is deterministic.
    public let labels: [String: String]
    /// Build platform (`--platform`, format `os/arch[/variant]`).
    public let platform: String?
    /// CPUs to allocate to the builder container (`-c`/`--cpus`).
    public let cpus: Int?
    /// Builder container memory in MiB (`-m`/`--memory`).
    public let memoryMiB: Int?

    public init(
        buildArgs: [String: String] = [:],
        target: String? = nil,
        noCache: Bool = false,
        pull: Bool = false,
        labels: [String: String] = [:],
        platform: String? = nil,
        cpus: Int? = nil,
        memoryMiB: Int? = nil
    ) {
        self.buildArgs = buildArgs
        self.target = target
        self.noCache = noCache
        self.pull = pull
        self.labels = labels
        self.platform = platform
        self.cpus = cpus
        self.memoryMiB = memoryMiB
    }
}

/// High-level operations the GUI performs against the `container` runtime.
///
/// Every method is expressed in terms of domain models, never raw argv or
/// process results. Implementations (e.g. `CLIContainerService`) translate
/// these calls into `container` CLI invocations via a `CommandRunner`.
///
/// `Sendable` so view models on the main actor can hold and call it freely.
public protocol ContainerService: Sendable {
    /// All containers (running and stopped) via `list --all --format json`.
    func listContainers() async throws -> [Container]

    /// Start a stopped container by id.
    func start(_ id: String) async throws

    /// Gracefully stop a running container by id (`stop`). Optionally pass a
    /// `signal` (e.g. `"TERM"`, `"HUP"`) sent via `-s`, and a `timeout` in
    /// seconds (`-t`) to wait before the runtime escalates. Both default to nil,
    /// so `stop(id)` keeps the runtime's default graceful behavior.
    func stop(_ id: String, signal: String?, timeout: Int?) async throws

    /// Forcibly signal a running container by id (`kill`). Optionally pass a
    /// `signal` (e.g. `"KILL"`, `"TERM"`, `"HUP"`, `"INT"`, `"USR1"`) sent via
    /// `-s`; nil uses the runtime's default kill signal.
    func kill(_ id: String, signal: String?) async throws

    /// Delete a container by id (`container delete [-f]`). A plain delete
    /// (`force: false`) fails on a running container with an `invalidState`
    /// error, so callers stop it first (see `ContainersViewModel.remove`).
    /// Passing `force: true` adds `-f`, which removes a running container
    /// outright without a graceful stop. Swift forbids default arg values on
    /// protocol requirements, so the `remove(id)` convenience (force defaults
    /// to false) lives in the extension below.
    func remove(_ id: String, force: Bool) async throws

    /// Delete all containers, running and stopped (`container delete --all`).
    /// Used by the list's "Delete All" action.
    func deleteAll() async throws

    /// Create and run a new container from `spec` via `container run`, returning
    /// the new container's id (trimmed stdout).
    func run(_ spec: RunSpec) async throws -> String

    /// Remove all stopped containers (`prune`, a top-level subcommand).
    func pruneContainers() async throws

    /// Export a container's filesystem to a tar archive at `path`
    /// (`export --output <path> <id>`).
    func exportContainer(_ id: String, to path: String) async throws

    /// Copy a host file/folder INTO a container
    /// (`copy <localPath> <containerId>:<containerPath>`). A default extension
    /// impl below throws `binaryNotFound` so preview/stub conformers inherit it
    /// unchanged; `CLIContainerService` overrides it to shell out and the test
    /// mock overrides it to record the call.
    func copyToContainer(localPath: String, containerId: String, containerPath: String) async throws

    /// Copy a file/folder OUT of a container onto the host
    /// (`copy <containerId>:<containerPath> <localPath>`). A default extension
    /// impl below throws `binaryNotFound` so preview/stub conformers inherit it
    /// unchanged; `CLIContainerService` overrides it to shell out and the test
    /// mock overrides it to record the call.
    func copyFromContainer(containerId: String, containerPath: String, localPath: String) async throws

    /// Resource-usage snapshots via `stats --no-stream --format json [<id>...]`.
    /// Passing an empty `ids` array samples all running containers. Each element
    /// is a CUMULATIVE-counter snapshot; callers derive rates from deltas.
    func stats(_ ids: [String]) async throws -> [ContainerStats]

    /// All locally available images via `image list --format json`.
    func listImages() async throws -> [ContainerImage]

    /// An image's run-time defaults (suggested env, and exposed ports if the
    /// runtime reports them) via `image inspect <ref>`. Used to prefill the Run
    /// sheet. Throws `commandFailed` if the image is not found locally.
    func imageConfig(_ ref: String) async throws -> ImageConfig

    /// Pull an image by reference, streaming progress lines as they arrive.
    func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error>

    /// Delete an image by reference (or id/digest).
    func removeImage(_ id: String) async throws

    /// Remove all unused (dangling) images (`image prune`).
    func pruneImages() async throws

    /// Create a new reference `newRef` for the existing image `source`
    /// (`image tag <source> <newRef>`).
    func tagImage(source: String, newRef: String) async throws

    /// Push an image by reference, streaming progress lines as they arrive.
    func pushImage(_ ref: String) -> AsyncThrowingStream<String, Error>

    /// Save an image to an OCI-compatible tar archive at `path`
    /// (`image save --output <path> <ref>`). A no-op default extension impl below
    /// lets preview/stub conformers inherit it unchanged; `CLIContainerService`
    /// overrides it to shell out and the test mock overrides it to record calls.
    func saveImage(_ ref: String, to path: String) async throws

    /// Load (import) an image from an OCI/Docker tar archive at `path`
    /// (`image load --input <path>`), the inverse of `saveImage`. A no-op default
    /// extension impl below lets preview/stub conformers inherit it unchanged;
    /// `CLIContainerService` overrides it to shell out and the test mock overrides
    /// it to record calls.
    func loadImage(from path: String) async throws

    /// All volumes via `volume list --format json`.
    func listVolumes() async throws -> [ContainerVolume]

    /// Create a volume by `name`. When `size` is set (e.g. `"64M"`) it is passed
    /// via `-s`; each `labels` entry is passed via `--label k=v`.
    func createVolume(name: String, size: String?, labels: [String: String]) async throws

    /// Delete a volume by name (`volume delete <name>`).
    func removeVolume(_ name: String) async throws

    /// Remove all unused volumes (`volume prune`).
    func pruneVolumes() async throws

    /// All networks via `network list --format json`.
    func listNetworks() async throws -> [ContainerNetwork]

    /// Create a network by `name`. When `internal` is true the `--internal`
    /// flag is passed; when `subnet` is set (e.g. `"10.0.0.0/24"`) it is passed
    /// via `--subnet`; each `labels` entry is passed via `--label k=v`.
    func createNetwork(name: String, internal isInternal: Bool, subnet: String?, labels: [String: String]) async throws

    /// Delete a network by name (`network delete <name>`).
    func removeNetwork(_ name: String) async throws

    /// Stream a container's logs (`logs [--boot] [-n <tail>] [--follow] <id>`).
    /// `follow: true` tails new output; `boot: true` shows the VM boot log
    /// (`--boot`) instead of the container's own output; `tail` (when non-nil)
    /// limits output to the last N lines (`-n <tail>`). Swift forbids default arg
    /// values on protocol requirements, so the `logs(id, follow:)` convenience
    /// (boot defaults false, tail nil) lives in the extension below.
    func logs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> AsyncThrowingStream<String, Error>

    /// Disk-usage totals via `system df --format json` (Docker-Desktop-style
    /// breakdown). Requires the daemon to be running; on an XPC/daemon error the
    /// CLI exits non-zero and this throws `commandFailed`, so callers degrade
    /// gracefully. A default extension impl below lets preview/stub conformers
    /// inherit a zeroed value; `CLIContainerService` overrides it to shell out
    /// and the test mock overrides it to return a seeded value.
    func systemDF() async throws -> DiskUsage

    /// Current daemon status via `system status`.
    func daemonStatus() async throws -> DaemonStatus

    /// Start the daemon / install the kernel via `system start`.
    func startDaemon() async throws

    /// Build an image, streaming build log lines as they arrive. `options`
    /// carries the advanced flags (`--build-arg/--target/--no-cache/--pull/
    /// --label/--platform/-c/-m`); an empty `BuildOptions()` reproduces the
    /// plain `--tag/--file/context` invocation. Swift forbids default arg values
    /// on protocol requirements, so the `build(dockerfile:context:tag:)`
    /// convenience (empty options) lives in the extension below.
    func build(dockerfile: String, context: String, tag: String, options: BuildOptions) -> AsyncThrowingStream<String, Error>

    /// Resolve the executable + argv for an interactive `exec` session into a
    /// container, e.g. `container exec -i -t <id> sh`. The terminal UI hands the
    /// result to a PTY-backed process; building the argv here keeps the app from
    /// hand-assembling CLI arguments. Throws `binaryNotFound` if the `container`
    /// binary cannot be located.
    func execInvocation(id: String, command: [String]) async throws -> ProcessInvocation

    /// Resolve the executable + argv for an interactive *debug shell* into a
    /// throwaway container created from an image, i.e.
    /// `container run --rm -i -t <ref> sh`. `--rm` removes the container when the
    /// shell exits so nothing is left behind. The terminal UI hands the result
    /// to a PTY-backed process. Throws `binaryNotFound` if the `container`
    /// binary cannot be located.
    func imageShellInvocation(ref: String) async throws -> ProcessInvocation
}

extension ContainerService {
    /// Convenience: stop with the runtime's default graceful behavior. Keeps
    /// existing `stop(id)` call sites working now that the requirement carries
    /// `signal`/`timeout` (Swift forbids default arg values on protocol
    /// requirements, so the defaults live here as an overload).
    public func stop(_ id: String) async throws {
        try await stop(id, signal: nil, timeout: nil)
    }

    /// Convenience: stop with only a `signal` (timeout left to the runtime).
    public func stop(_ id: String, signal: String?) async throws {
        try await stop(id, signal: signal, timeout: nil)
    }

    /// Convenience: stop with only a `timeout` (default signal).
    public func stop(_ id: String, timeout: Int?) async throws {
        try await stop(id, signal: nil, timeout: timeout)
    }

    /// Convenience: kill with the runtime's default signal.
    public func kill(_ id: String) async throws {
        try await kill(id, signal: nil)
    }

    /// Convenience: stream logs without a boot toggle or tail limit. Keeps
    /// existing `logs(id, follow:)` call sites working now that the requirement
    /// carries `boot`/`tail` (Swift forbids default arg values on protocol
    /// requirements, so the defaults live here as an overload).
    public func logs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        logs(id, follow: follow, boot: false, tail: nil)
    }

    /// Convenience: a plain delete (no `-f`). Keeps existing `remove(id)` call
    /// sites working now that the requirement carries `force` (Swift forbids
    /// default arg values on protocol requirements, so the default lives here).
    public func remove(_ id: String) async throws {
        try await remove(id, force: false)
    }

    /// Convenience: build with no advanced options. Keeps existing
    /// `build(dockerfile:context:tag:)` call sites working now that the
    /// requirement carries `options` (Swift forbids default arg values on
    /// protocol requirements, so the default lives here as an overload).
    public func build(dockerfile: String, context: String, tag: String) -> AsyncThrowingStream<String, Error> {
        build(dockerfile: dockerfile, context: context, tag: tag, options: BuildOptions())
    }

    /// Convenience: an interactive shell (`sh`) exec invocation.
    public func execShellInvocation(id: String) async throws -> ProcessInvocation {
        try await execInvocation(id: id, command: ["sh"])
    }

    /// Default invocation builder for conformers (mocks/preview services) that
    /// don't resolve a real binary. Uses the canonical relative argv with a
    /// placeholder `container` executable, so previews and tests get a
    /// well-formed `ProcessInvocation` without filesystem discovery.
    /// `CLIContainerService` overrides this to resolve the real binary path.
    public func execInvocation(id: String, command: [String]) async throws -> ProcessInvocation {
        var args = ["exec", "-i", "-t", id]
        args.append(contentsOf: command)
        return ProcessInvocation(executable: "container", arguments: args)
    }

    /// Default `systemDF` for conformers (mocks/preview services) that do not
    /// shell out: returns a zeroed breakdown so previews render an empty Disk
    /// Usage panel. `CLIContainerService` overrides this with the real
    /// `system df --format json` invocation; the test mock overrides it to
    /// return a seeded value.
    public func systemDF() async throws -> DiskUsage {
        let zero = DiskUsage.Category(active: 0, reclaimable: 0, sizeInBytes: 0, total: 0)
        return DiskUsage(containers: zero, images: zero, volumes: zero)
    }

    /// No-op default `saveImage` for conformers (mocks/preview services) that do
    /// not shell out. `CLIContainerService` overrides this with the real
    /// `image save` invocation; the test mock overrides it to record the call.
    public func saveImage(_ ref: String, to path: String) async throws {}

    /// No-op default `loadImage` for conformers (mocks/preview services) that do
    /// not shell out. `CLIContainerService` overrides this with the real
    /// `image load` invocation; the test mock overrides it to record the call.
    public func loadImage(from path: String) async throws {}

    /// Default `copyToContainer` for conformers (preview/stub services) that do
    /// not shell out: throws `binaryNotFound`. `CLIContainerService` overrides it
    /// with the real `copy` invocation; the test mock overrides it to record.
    public func copyToContainer(localPath: String, containerId: String, containerPath: String) async throws {
        throw ContainerError.binaryNotFound
    }

    /// Default `copyFromContainer` for conformers (preview/stub services) that do
    /// not shell out: throws `binaryNotFound`. `CLIContainerService` overrides it
    /// with the real `copy` invocation; the test mock overrides it to record.
    public func copyFromContainer(containerId: String, containerPath: String, localPath: String) async throws {
        throw ContainerError.binaryNotFound
    }

    /// Default debug-shell invocation builder for conformers (mocks/preview
    /// services) that don't resolve a real binary. Uses the canonical relative
    /// argv (`run --rm -i -t <ref> sh`) with a placeholder `container`
    /// executable. `CLIContainerService` overrides this to resolve the real
    /// binary path.
    public func imageShellInvocation(ref: String) async throws -> ProcessInvocation {
        ProcessInvocation(executable: "container", arguments: ["run", "--rm", "-i", "-t", ref, "sh"])
    }

    /// Default config lookup for conformers (mocks/preview services) that do not
    /// shell out: reuse `listImages`, find the matching image by name, and
    /// derive its `ImageConfig`. Returns an empty config when not found, so the
    /// Run sheet degrades to a plain form. `CLIContainerService` overrides this
    /// with a targeted `image inspect`.
    public func imageConfig(_ ref: String) async throws -> ImageConfig {
        let images = try await listImages()
        guard let match = images.first(where: { $0.name == ref }) else {
            return ImageConfig()
        }
        return ImageConfig(runtimeConfig: match.defaultRuntimeConfig)
    }
}
