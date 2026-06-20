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

        private enum CodingKeys: String, CodingKey {
            case env = "Env"
            case exposedPorts = "ExposedPorts"
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
            guard let cfg = v.config?.config, cfg.env != nil || cfg.exposedPorts != nil else { return nil }
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
