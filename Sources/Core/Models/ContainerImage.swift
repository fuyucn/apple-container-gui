import Foundation

/// An image as reported by `container image list --format json` (container
/// v1.0.0). Each element carries its OCI index `id` (digest), a `configuration`
/// (name + descriptor) and per-platform `variants`. Unknown fields (e.g. the
/// large per-variant `config` blob) are tolerated and not modeled.
public struct ContainerImage: Codable, Identifiable, Sendable {
    public let id: String
    public let configuration: Configuration
    public let variants: [Variant]

    public struct Configuration: Codable, Sendable {
        public let name: String
        public let descriptor: Descriptor
        /// Image creation timestamp as reported by the runtime
        /// (`configuration.creationDate`, e.g. `2026-06-16T00:00:15Z`). Optional
        /// because leaner JSON shapes (and `image list`) may omit it.
        public let creationDate: String?
    }

    public struct Descriptor: Codable, Sendable {
        public let digest: String
        public let mediaType: String
        public let size: Int
    }

    public struct Variant: Codable, Sendable {
        public let digest: String
        public let platform: Platform
        public let size: Int
        /// The per-variant OCI config blob. Optional because some variants
        /// (e.g. the "unknown/unknown" attestation manifests) carry only an
        /// empty config. Only the fields the GUI needs are modeled.
        public let config: VariantConfig?
    }

    /// The OCI image config for a single platform variant: `variants[].config`.
    public struct VariantConfig: Codable, Sendable {
        public let architecture: String?
        public let os: String?
        /// The nested runtime config (`config.config`) carrying `Env`, `Cmd`,
        /// `WorkingDir`, etc. — the defaults a container inherits at run time.
        public let config: ImageRuntimeConfig?
    }

    /// The nested runtime config (`variants[].config.config`) as reported by
    /// Apple's `container` runtime. Only `Env` and `ExposedPorts` are decoded
    /// for run-time prefill; the latter is currently never populated by the
    /// runtime (kept for forward-compatibility). Coding keys match the
    /// capitalized OCI field names.
    public struct ImageRuntimeConfig: Codable, Sendable {
        public let env: [String]?
        public let exposedPorts: [String: AnyEmpty]?
        /// The image's default command (`config.config.Cmd`), e.g.
        /// `["nginx", "-g", "daemon off;"]`. Optional; absent for some variants.
        public let cmd: [String]?
        /// The image's entrypoint (`config.config.Entrypoint`), e.g.
        /// `["/docker-entrypoint.sh"]`. Only present when the image sets one
        /// (e.g. nginx); absent for plain images like alpine.
        public let entrypoint: [String]?
        /// The image's working directory (`config.config.WorkingDir`), e.g. `/`.
        public let workingDir: String?

        private enum CodingKeys: String, CodingKey {
            case env = "Env"
            case exposedPorts = "ExposedPorts"
            case cmd = "Cmd"
            case entrypoint = "Entrypoint"
            case workingDir = "WorkingDir"
        }
    }

    /// Placeholder for OCI `ExposedPorts` values, which are empty `{}` objects
    /// keyed by `"<port>/<proto>"`. We only care about the keys.
    public struct AnyEmpty: Codable, Sendable {}

    public struct Platform: Codable, Sendable {
        public let architecture: String
        public let os: String
        public let variant: String?
    }

    /// Image name/reference, e.g. `docker.io/library/alpine:latest`.
    public var name: String { configuration.name }

    /// Sum of all variant sizes in bytes.
    public var totalSize: Int { variants.map(\.size).reduce(0, +) }

    /// Distinct, ordered list of variant architectures.
    public var platforms: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for v in variants where !seen.contains(v.platform.architecture) {
            seen.insert(v.platform.architecture)
            result.append(v.platform.architecture)
        }
        return result
    }

    /// The runtime config to use for run-time defaults. Prefers a variant whose
    /// architecture matches the host (arm64 on Apple Silicon), then any
    /// linux/non-"unknown" variant that actually carries a populated config,
    /// falling back to the first config present. Returns nil if no variant
    /// carries a runtime config.
    public var defaultRuntimeConfig: ImageRuntimeConfig? {
        func runtime(_ v: Variant) -> ImageRuntimeConfig? {
            guard let cfg = v.config?.config,
                  cfg.env != nil || cfg.exposedPorts != nil
                    || cfg.cmd != nil || cfg.entrypoint != nil || cfg.workingDir != nil
            else { return nil }
            return cfg
        }
        if let arm = variants.first(where: { $0.platform.architecture == "arm64" }).flatMap(runtime) {
            return arm
        }
        if let linux = variants.first(where: { $0.platform.os == "linux" }).flatMap(runtime) {
            return linux
        }
        return variants.lazy.compactMap(runtime).first
    }

    /// The variant the GUI surfaces by default: prefers the host arch (arm64 on
    /// Apple Silicon), then any non-"unknown" linux variant, then the first
    /// variant. Used to derive the displayed platform string.
    public var defaultVariant: Variant? {
        if let arm = variants.first(where: { $0.platform.architecture == "arm64" }) {
            return arm
        }
        if let linux = variants.first(where: { $0.platform.os == "linux" && $0.platform.architecture != "unknown" }) {
            return linux
        }
        return variants.first
    }

    /// Human-readable platform string for the chosen variant, e.g. `linux/arm64`.
    /// nil when no variant is present.
    public var platformString: String? {
        guard let v = defaultVariant else { return nil }
        return "\(v.platform.os)/\(v.platform.architecture)"
    }

    /// The image's short digest id without any `sha256:` prefix (the OCI index
    /// `id`). Same as `id`; provided for naming symmetry with `digest`.
    public var digest: String { id }

    /// Parsed creation `Date` from `configuration.creationDate` (ISO-8601), or
    /// nil if absent/unparseable. Tries fractional-second then plain ISO-8601.
    public var createdDate: Date? {
        guard let raw = configuration.creationDate else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// A flattened, display-ready snapshot of everything the detail panel needs.
    public var detail: ImageDetail {
        let rt = defaultRuntimeConfig
        return ImageDetail(
            id: id,
            digest: configuration.descriptor.digest,
            name: name,
            creationDateRaw: configuration.creationDate,
            createdDate: createdDate,
            totalSize: totalSize,
            platform: platformString,
            command: rt?.cmd ?? [],
            entrypoint: rt?.entrypoint ?? [],
            workingDir: rt?.workingDir,
            env: rt?.env ?? []
        )
    }
}

/// A flattened, display-ready view of a `ContainerImage` for the detail panel.
/// Decoupled from the raw decoding shape so the UI renders a single value.
public struct ImageDetail: Sendable, Equatable {
    /// OCI index `id` (short digest, no `sha256:` prefix).
    public let id: String
    /// The full manifest digest (`configuration.descriptor.digest`,
    /// e.g. `sha256:…`).
    public let digest: String
    /// Image reference / tag, e.g. `docker.io/library/nginx:alpine`.
    public let name: String
    /// Raw creation timestamp string as reported by the runtime, if any.
    public let creationDateRaw: String?
    /// Parsed creation `Date`, if the raw string was parseable.
    public let createdDate: Date?
    /// Sum of all variant sizes in bytes.
    public let totalSize: Int
    /// Display platform string, e.g. `linux/arm64`, or nil.
    public let platform: String?
    /// Default command (`Cmd`); empty when the image sets none.
    public let command: [String]
    /// Entrypoint; empty when the image sets none.
    public let entrypoint: [String]
    /// Working directory; nil when unset.
    public let workingDir: String?
    /// Raw `KEY=VALUE` environment entries.
    public let env: [String]

    public init(
        id: String,
        digest: String,
        name: String,
        creationDateRaw: String?,
        createdDate: Date?,
        totalSize: Int,
        platform: String?,
        command: [String],
        entrypoint: [String],
        workingDir: String?,
        env: [String]
    ) {
        self.id = id
        self.digest = digest
        self.name = name
        self.creationDateRaw = creationDateRaw
        self.createdDate = createdDate
        self.totalSize = totalSize
        self.platform = platform
        self.command = command
        self.entrypoint = entrypoint
        self.workingDir = workingDir
        self.env = env
    }

    /// `Cmd` joined with spaces for single-line display; empty string when none.
    public var commandLine: String { command.joined(separator: " ") }

    /// `Entrypoint` joined with spaces for single-line display; empty when none.
    public var entrypointLine: String { entrypoint.joined(separator: " ") }

    /// Parsed `KEY=VALUE` env entries as ordered (key, value) pairs. Entries
    /// without an `=` are skipped; preserves the image's original ordering.
    public var environment: [(key: String, value: String)] {
        env.compactMap { entry in
            guard let eq = entry.firstIndex(of: "=") else { return nil }
            let key = String(entry[..<eq])
            guard !key.isEmpty else { return nil }
            return (key, String(entry[entry.index(after: eq)...]))
        }
    }
}

/// In-use detection for images: which locally-available images are currently
/// referenced by an existing container. Pure and testable — independent of any
/// service or view model.
///
/// Apple's `container` reports container image references in fully-qualified
/// form (`docker.io/library/alpine:latest`) while a locally-tagged image may be
/// named either way. We normalize both sides to a canonical trailing
/// `repo:tag`, stripping the `docker.io/library/` Docker Hub prefix, so
/// `alpine:latest` matches `docker.io/library/alpine:latest`.
public enum ImageUsage {
    /// Canonicalize an image reference for matching: strip a leading
    /// `docker.io/` registry and a `library/` namespace so Docker Hub official
    /// images compare equal whether or not they were written long-form.
    /// Other registries (e.g. `ghcr.io/...`) are left intact.
    public static func normalize(_ reference: String) -> String {
        var ref = reference
        if ref.hasPrefix("docker.io/") {
            ref.removeFirst("docker.io/".count)
        }
        if ref.hasPrefix("library/") {
            ref.removeFirst("library/".count)
        }
        return ref
    }

    /// Given the available images and the set of container image references
    /// (e.g. from `listContainers().map(\.imageReference)`), return the set of
    /// image *names* (as `ContainerImage.name`) that are currently in use.
    /// Matching is by normalized reference.
    public static func inUseNames(
        images: [ContainerImage],
        containerReferences: some Sequence<String>
    ) -> Set<String> {
        let used = Set(containerReferences.map(normalize))
        return Set(images.map(\.name).filter { used.contains(normalize($0)) })
    }
}

/// An image's run-time defaults, surfaced so the Run sheet can prefill suggested
/// environment variables (and, if the runtime ever reports them, exposed ports).
///
/// Apple's `container` v1.0.0 `image inspect` does NOT report `ExposedPorts`
/// (verified against nginx, which carries `80/tcp` upstream), so `exposedPorts`
/// is currently always empty; it is modeled for forward-compatibility.
public struct ImageConfig: Sendable, Equatable {
    /// Parsed `KEY=VALUE` environment defaults from the image config's `Env`.
    public let env: [String: String]
    /// Exposed container ports parsed from `ExposedPorts` keys (e.g. `"7860/tcp"`
    /// -> `7860`). Empty when the runtime does not report them.
    public let exposedPorts: [Int]

    public init(env: [String: String] = [:], exposedPorts: [Int] = []) {
        self.env = env
        self.exposedPorts = exposedPorts
    }

    /// Build an `ImageConfig` from a decoded image's runtime config.
    /// `Env` entries without an `=` are skipped; `ExposedPorts` keys are parsed
    /// as the leading integer before any `/proto` suffix, de-duplicated and
    /// sorted ascending.
    public init(runtimeConfig: ContainerImage.ImageRuntimeConfig?) {
        var env: [String: String] = [:]
        for entry in runtimeConfig?.env ?? [] {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            guard !key.isEmpty else { continue }
            env[key] = String(entry[entry.index(after: eq)...])
        }
        var ports = Set<Int>()
        for key in (runtimeConfig?.exposedPorts ?? [:]).keys {
            let head = key.split(separator: "/", maxSplits: 1).first.map(String.init) ?? key
            if let p = Int(head) { ports.insert(p) }
        }
        self.env = env
        self.exposedPorts = ports.sorted()
    }
}
