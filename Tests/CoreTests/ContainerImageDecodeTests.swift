import Testing
import Foundation
@testable import Core

private func loadImageFixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw ImageFixtureError.notFound(name)
    }
    return try Data(contentsOf: url)
}

private enum ImageFixtureError: Error { case notFound(String) }

@Test func decodesImageListFixture() throws {
    let data = try loadImageFixture("image-list.json")
    let images = try JSONDecoder().decode([ContainerImage].self, from: data)

    #expect(images.count == 1)
    let img = try #require(images.first)
    #expect(img.name == "docker.io/library/alpine:latest")
    #expect(img.id == "28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b")
    #expect(img.configuration.descriptor.size == 9218)
    // Variants include an arm64 platform.
    #expect(img.platforms.contains("arm64"))
    #expect(img.variants.count > 1)
    // totalSize is the sum of all variant sizes.
    let expected = img.variants.map(\.size).reduce(0, +)
    #expect(img.totalSize == expected)
}

@Test func imageVariantWithVariantFieldDecodes() throws {
    let data = try loadImageFixture("image-list.json")
    let images = try JSONDecoder().decode([ContainerImage].self, from: data)
    let img = try #require(images.first)
    // One arm64 variant carries platform.variant "v8".
    let v8 = img.variants.first { $0.platform.variant == "v8" }
    #expect(v8 != nil)
    #expect(v8?.platform.architecture == "arm64")
}

@Test func imageConfigParsesEnvFromInspectFixture() throws {
    // `image inspect <ref>` returns the same `[ContainerImage]` JSON as
    // `image list`, including the per-variant `config.config` blob with `Env`.
    let data = try loadImageFixture("image-inspect.json")
    let images = try JSONDecoder().decode([ContainerImage].self, from: data)
    let img = try #require(images.first { $0.name == "docker.io/library/nginx:alpine" })

    let config = ImageConfig(runtimeConfig: img.defaultRuntimeConfig)

    // Env defaults are parsed from KEY=VALUE into a dict.
    #expect(config.env["PATH"] == "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    #expect(config.env["NGINX_VERSION"] == "1.31.2")
    // Apple's container runtime does NOT report ExposedPorts (verified against
    // nginx, which carries 80/tcp upstream), so the list is empty.
    #expect(config.exposedPorts.isEmpty)
}

@Test func defaultRuntimeConfigPrefersPopulatedVariantOverUnknown() throws {
    // The fixture has an arm64 variant (with Env) and an "unknown" variant
    // (empty config). The arm64 one must win.
    let data = try loadImageFixture("image-inspect.json")
    let images = try JSONDecoder().decode([ContainerImage].self, from: data)
    let img = try #require(images.first { $0.name == "docker.io/library/nginx:alpine" })
    let runtime = try #require(img.defaultRuntimeConfig)
    #expect(runtime.env?.isEmpty == false)
}

@Test func imageConfigParsesExposedPortsWhenPresent() throws {
    // Forward-compat: if a runtime ever reports ExposedPorts, parse the leading
    // integer of each "<port>/<proto>" key, de-duplicated and sorted.
    let json = """
    {"Env":["FOO=bar","NOEQUALS","=novalue"],"ExposedPorts":{"7860/tcp":{},"443/tcp":{},"443/udp":{}}}
    """.data(using: .utf8)!
    let runtime = try JSONDecoder().decode(ContainerImage.ImageRuntimeConfig.self, from: json)
    let config = ImageConfig(runtimeConfig: runtime)

    #expect(config.env == ["FOO": "bar"])          // entries without a key/= are skipped
    #expect(config.exposedPorts == [443, 7860])    // de-duplicated + sorted ascending
}

@Test func imageConfigFromNilRuntimeIsEmpty() {
    let config = ImageConfig(runtimeConfig: nil)
    #expect(config.env.isEmpty)
    #expect(config.exposedPorts.isEmpty)
}

// MARK: - ImageDetail (detail panel projection)

@Test func imageDetailDecodesAlpineCommandAndWorkingDir() throws {
    let data = try loadImageFixture("image-inspect.json")
    let images = try JSONDecoder().decode([ContainerImage].self, from: data)
    let alpine = try #require(images.first { $0.name == "docker.io/library/alpine:latest" })
    let detail = alpine.detail

    #expect(detail.name == "docker.io/library/alpine:latest")
    #expect(detail.id == "28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b")
    #expect(detail.digest.hasPrefix("sha256:"))
    // alpine: Cmd is /bin/sh, no entrypoint, WorkingDir /.
    #expect(detail.command == ["/bin/sh"])
    #expect(detail.commandLine == "/bin/sh")
    #expect(detail.entrypoint.isEmpty)
    #expect(detail.workingDir == "/")
    // arm64 variant is chosen on Apple Silicon.
    #expect(detail.platform == "linux/arm64")
    // Env carries PATH.
    let env = Dictionary(uniqueKeysWithValues: detail.environment.map { ($0.key, $0.value) })
    #expect(env["PATH"] == "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    // creationDate parses.
    #expect(detail.creationDateRaw != nil)
    #expect(detail.createdDate != nil)
}

@Test func imageDetailDecodesNginxEntrypoint() throws {
    let data = try loadImageFixture("image-inspect.json")
    let images = try JSONDecoder().decode([ContainerImage].self, from: data)
    let nginx = try #require(images.first { $0.name == "docker.io/library/nginx:alpine" })
    let detail = nginx.detail

    // nginx: Cmd is nginx -g daemon off;, Entrypoint /docker-entrypoint.sh.
    #expect(detail.command == ["nginx", "-g", "daemon off;"])
    #expect(detail.commandLine == "nginx -g daemon off;")
    #expect(detail.entrypoint == ["/docker-entrypoint.sh"])
    #expect(detail.entrypointLine == "/docker-entrypoint.sh")
    #expect(detail.workingDir == "/")
    // NGINX_VERSION env is exposed via the environment table.
    let env = Dictionary(uniqueKeysWithValues: detail.environment.map { ($0.key, $0.value) })
    #expect(env["NGINX_VERSION"] == "1.31.2")
}

@Test func imageDetailEnvironmentSkipsMalformedEntries() {
    let detail = ImageDetail(
        id: "x", digest: "sha256:x", name: "x:latest",
        creationDateRaw: nil, createdDate: nil, totalSize: 0, platform: nil,
        command: [], entrypoint: [], workingDir: nil,
        env: ["A=1", "NOEQUALS", "=novalue", "B=two=three"]
    )
    let pairs = detail.environment
    #expect(pairs.count == 2)
    #expect(pairs[0] == ("A", "1"))
    // First `=` splits; the rest of the value is preserved verbatim.
    #expect(pairs[1] == ("B", "two=three"))
}

@Test func imageCreatedDateParsesFractionalAndPlainISO8601() {
    func detail(_ raw: String) -> ImageDetail {
        let json = """
        [{"id":"i","configuration":{"name":"n:latest","creationDate":"\(raw)","descriptor":{"digest":"d","mediaType":"m","size":1}},"variants":[]}]
        """.data(using: .utf8)!
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode([ContainerImage].self, from: json)[0].detail
    }
    #expect(detail("2026-06-16T00:00:15Z").createdDate != nil)
    #expect(detail("2026-06-17T23:12:38.123456789Z").createdDate != nil)
    #expect(detail("not-a-date").createdDate == nil)
}

// MARK: - In-use detection / normalization

@Test func imageUsageNormalizesDockerHubPrefix() {
    #expect(ImageUsage.normalize("docker.io/library/alpine:latest") == "alpine:latest")
    #expect(ImageUsage.normalize("alpine:latest") == "alpine:latest")
    #expect(ImageUsage.normalize("docker.io/library/nginx:alpine") == "nginx:alpine")
    // Non-Docker-Hub registries are left intact.
    #expect(ImageUsage.normalize("ghcr.io/foo/bar:1") == "ghcr.io/foo/bar:1")
    // docker.io without library/ namespace still strips the registry.
    #expect(ImageUsage.normalize("docker.io/me/app:1") == "me/app:1")
}

@Test func imageUsageInUseNamesMatchesAcrossPrefixForms() throws {
    func image(_ name: String) throws -> ContainerImage {
        let json = """
        [{"id":"i","configuration":{"name":"\(name)","descriptor":{"digest":"d","mediaType":"m","size":1}},"variants":[]}]
        """.data(using: .utf8)!
        return try JSONDecoder().decode([ContainerImage].self, from: json)[0]
    }
    // A short-tagged alpine image and a long-form nginx image; a dangling uuid.
    let images = [
        try image("alpine:latest"),
        try image("docker.io/library/nginx:alpine"),
        try image("e3573bbeaf27fc648133d1c35b5d981f962f332fab1b4e0c653173fdabb73366"),
    ]
    // Containers reference the fully-qualified forms.
    let refs = [
        "docker.io/library/alpine:latest",
        "docker.io/library/nginx:alpine",
    ]
    let used = ImageUsage.inUseNames(images: images, containerReferences: refs)
    #expect(used.contains("alpine:latest"))
    #expect(used.contains("docker.io/library/nginx:alpine"))
    // The dangling/uuid image matches nothing.
    #expect(!used.contains("e3573bbeaf27fc648133d1c35b5d981f962f332fab1b4e0c653173fdabb73366"))
    #expect(used.count == 2)
}

@Test func imageUsageEmptyWhenNoContainers() throws {
    let json = """
    [{"id":"i","configuration":{"name":"alpine:latest","descriptor":{"digest":"d","mediaType":"m","size":1}},"variants":[]}]
    """.data(using: .utf8)!
    let images = try JSONDecoder().decode([ContainerImage].self, from: json)
    #expect(ImageUsage.inUseNames(images: images, containerReferences: [String]()).isEmpty)
}

@Test func imageToleratesUnknownExtraFields() throws {
    let json = """
    [{"id":"abc","brandNew":1,"configuration":{"name":"foo:latest","descriptor":{"digest":"d","mediaType":"m","size":10,"extra":true}},"variants":[{"digest":"vd","platform":{"architecture":"arm64","os":"linux"},"size":100,"weird":"x"}]}]
    """.data(using: .utf8)!
    let images = try JSONDecoder().decode([ContainerImage].self, from: json)
    #expect(images.count == 1)
    #expect(images.first?.name == "foo:latest")
    #expect(images.first?.totalSize == 100)
    #expect(images.first?.platforms == ["arm64"])
}
