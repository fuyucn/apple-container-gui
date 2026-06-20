import Testing
import Foundation
@testable import Core

private func loadNetworkFixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw NetworkFixtureError.notFound(name)
    }
    return try Data(contentsOf: url)
}

private enum NetworkFixtureError: Error { case notFound(String) }

@Test func decodesNetworksFixture() throws {
    let data = try loadNetworkFixture("networks.json")
    let networks = try JSONDecoder().decode([ContainerNetwork].self, from: data)

    #expect(networks.count == 1)
    let net = try #require(networks.first)
    #expect(net.id == "default")
    #expect(net.name == "default")
    #expect(net.configuration.mode == "nat")
    #expect(net.configuration.plugin == "container-network-vmnet")
    // The builtin default network's gateway is 192.168.64.1.
    #expect(net.gateway == "192.168.64.1")
    #expect(net.subnet == "192.168.64.0/24")
    #expect(net.status?.ipv6Subnet == "fd33:9ce7:6eb3:3497::/64")
    #expect(net.configuration.labels["com.apple.container.resource.role"] == "builtin")
}

@Test func networkWithoutStatusDecodesWithEmptyGatewayAndSubnet() throws {
    // A freshly-created network may report no status yet.
    let json = """
    [{"configuration":{"creationDate":"2026-06-17T19:32:12Z","labels":{},"mode":"nat","name":"fresh","options":{},"plugin":"container-network-vmnet"},"id":"fresh"}]
    """
    let networks = try JSONDecoder().decode([ContainerNetwork].self, from: Data(json.utf8))
    let net = try #require(networks.first)
    #expect(net.status == nil)
    #expect(net.gateway == "")
    #expect(net.subnet == "")
}
