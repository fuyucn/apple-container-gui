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
