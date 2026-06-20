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

    /// Stop a running container by id.
    func stop(_ id: String) async throws

    /// Delete a stopped container by id (`container delete`). A running
    /// container must be stopped first (see `ContainersViewModel.remove`),
    /// since a plain delete fails on a running container with an
    /// `invalidState` error. This stays a single, predictable CLI call.
    func remove(_ id: String) async throws

    /// Create and run a new container from `spec` via `container run`, returning
    /// the new container's id (trimmed stdout).
    func run(_ spec: RunSpec) async throws -> String

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

    /// Stream a container's logs; `follow: true` tails new output.
    func logs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error>

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
