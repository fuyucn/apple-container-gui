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
    let img = try #require(images.first)
    #expect(img.name == "docker.io/library/nginx:alpine")

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
    let img = try #require(images.first)
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
