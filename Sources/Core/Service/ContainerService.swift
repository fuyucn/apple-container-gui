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

    public init(
        image: String,
        name: String? = nil,
        detached: Bool = true,
        ports: [PortMapping] = [],
        env: [String: String] = [:],
        volumes: [VolumeMount] = [],
        command: [String] = [],
        cpus: Int? = nil,
        memoryMiB: Int? = nil
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

    /// Current daemon status via `system status`.
    func daemonStatus() async throws -> DaemonStatus

    /// Start the daemon / install the kernel via `system start`.
    func startDaemon() async throws

    /// Build an image, streaming build log lines as they arrive.
    func build(dockerfile: String, context: String, tag: String) -> AsyncThrowingStream<String, Error>

    /// Resolve the executable + argv for an interactive `exec` session into a
    /// container, e.g. `container exec -i -t <id> sh`. The terminal UI hands the
    /// result to a PTY-backed process; building the argv here keeps the app from
    /// hand-assembling CLI arguments. Throws `binaryNotFound` if the `container`
    /// binary cannot be located.
    func execInvocation(id: String, command: [String]) async throws -> ProcessInvocation
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
