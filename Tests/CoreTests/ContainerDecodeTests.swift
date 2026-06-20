import Testing
import Foundation
@testable import Core

private func loadFixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw FixtureError.notFound(name)
    }
    return try Data(contentsOf: url)
}

private enum FixtureError: Error { case notFound(String) }

@Test func decodesContainerListFixture() throws {
    let data = try loadFixture("container-list.json")
    let containers = try JSONDecoder().decode([Container].self, from: data)

    #expect(containers.count == 1)
    let c = try #require(containers.first)
    #expect(c.id == "fixture-demo")
    #expect(c.imageReference == "docker.io/library/alpine:latest")
    #expect(c.state == .running)
    #expect(c.primaryIPv4 == "192.168.64.2/24")
    #expect(c.configuration.resources.cpus == 4)
    #expect(c.configuration.resources.memoryInBytes == 1073741824)
    #expect(c.configuration.platform.architecture == "arm64")
    #expect(c.configuration.platform.os == "linux")
    #expect(c.configuration.image.descriptor.size == 9218)
}

/// Locks in the real `container list --all --format json` shape captured from
/// container v1.0.0, whose `status.networks` objects carry extra fields
/// (`ipv4Gateway`, `mtu`) and whose `configuration.networks[].options` carry
/// `mtu`. The model must decode it leniently (extra keys ignored) and surface
/// the addresses the GUI needs.
@Test func decodesLiveContainerListFixture() throws {
    let data = try loadFixture("container-list-live.json")
    let containers = try JSONDecoder().decode([Container].self, from: data)

    let c = try #require(containers.first { $0.id == "acg-demo-web" })
    #expect(c.imageReference == "docker.io/library/nginx:alpine")
    #expect(c.state == .running)
    // Primary IPv4 is read off a network object that ALSO contains the extra
    // ipv4Gateway/mtu keys the live runtime now emits — proving they're tolerated.
    #expect(c.primaryIPv4 == "192.168.64.6/24")
    let net = try #require(c.status.networks.first)
    #expect(net.network == "default")
    #expect(net.macAddress == "f2:cd:51:af:27:54")
    #expect(c.configuration.networks.compactMap(\.network) == ["default"])
}

/// The live `container list --all --format json` (v1.0.0) emits
/// `configuration.publishedPorts` as objects with host/container port pairs plus
/// extra keys (`count`, `hostAddress`, `proto`). The model must decode the pairs
/// leniently and surface them via the `publishedPorts` accessor.
@Test func decodesPublishedPortsFromLiveFixture() throws {
    let data = try loadFixture("container-list-live.json")
    let containers = try JSONDecoder().decode([Container].self, from: data)

    let c = try #require(containers.first { $0.id == "acg-demo-web" })
    let ports = c.publishedPorts
    #expect(ports.count == 1)
    let p = try #require(ports.first)
    #expect(p.hostPort == 8080)
    #expect(p.containerPort == 80)
}

/// A container with no published ports (the `container-list.json` fixture has an
/// empty `publishedPorts` array) surfaces an empty list, not nil.
@Test func decodesEmptyPublishedPorts() throws {
    let data = try loadFixture("container-list.json")
    let containers = try JSONDecoder().decode([Container].self, from: data)
    let c = try #require(containers.first)
    #expect(c.publishedPorts.isEmpty)
}

/// A container whose JSON omits `publishedPorts` entirely (older/leaner shape)
/// must still decode, surfacing an empty list.
@Test func toleratesMissingPublishedPorts() throws {
    let json = """
    [{"id":"x","configuration":{"image":{"reference":"r","descriptor":{"digest":"d","mediaType":"m","size":1}},"resources":{"cpus":1,"memoryInBytes":2},"platform":{"architecture":"arm64","os":"linux"},"networks":[]},"status":{"state":"running","networks":[]}}]
    """.data(using: .utf8)!
    let containers = try JSONDecoder().decode([Container].self, from: json)
    #expect(containers.first?.publishedPorts.isEmpty == true)
}

@Test func unknownContainerStateDecodesToUnknown() throws {
    let json = """
    [{"id":"x","configuration":{"image":{"reference":"r","descriptor":{"digest":"d","mediaType":"m","size":1}},"resources":{"cpus":1,"memoryInBytes":2},"platform":{"architecture":"arm64","os":"linux"},"networks":[]},"status":{"state":"weird-future-state","networks":[]}}]
    """.data(using: .utf8)!
    let containers = try JSONDecoder().decode([Container].self, from: json)
    #expect(containers.first?.state == .unknown)
    #expect(containers.first?.primaryIPv4 == nil)
}

@Test func containerToleratesUnknownExtraFields() throws {
    // Extra unknown top-level + nested fields must still decode (lenient).
    let json = """
    [{"id":"x","brandNewField":42,"configuration":{"image":{"reference":"r","descriptor":{"digest":"d","mediaType":"m","size":1,"someExtra":true}},"resources":{"cpus":1,"memoryInBytes":2,"futureField":"y"},"platform":{"architecture":"arm64","os":"linux"},"networks":[],"unexpectedArray":[1,2,3]},"status":{"state":"running","networks":[],"mysteryField":"z"}}]
    """.data(using: .utf8)!
    let containers = try JSONDecoder().decode([Container].self, from: json)
    #expect(containers.count == 1)
    #expect(containers.first?.state == .running)
}

@Test func stoppedStateDecodes() throws {
    let json = """
    [{"id":"x","configuration":{"image":{"reference":"r","descriptor":{"digest":"d","mediaType":"m","size":1}},"resources":{"cpus":1,"memoryInBytes":2},"platform":{"architecture":"arm64","os":"linux"},"networks":[]},"status":{"state":"stopped","networks":[]}}]
    """.data(using: .utf8)!
    let containers = try JSONDecoder().decode([Container].self, from: json)
    #expect(containers.first?.state == .stopped)
}
