import Testing
import Foundation
@testable import Core

private enum StatsFixtureError: Error { case notFound(String) }

private func loadStatsFixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw StatsFixtureError.notFound(name)
    }
    return try Data(contentsOf: url)
}

/// Locks in the real `container stats --no-stream --format json` shape captured
/// from container v1.0.0: a JSON array of cumulative-counter snapshots.
@Test func decodesStatsFixture() throws {
    let data = try loadStatsFixture("stats.json")
    let stats = try JSONDecoder().decode([ContainerStats].self, from: data)

    #expect(stats.count == 1)
    let s = try #require(stats.first)
    #expect(s.id == "v2-stats")
    #expect(s.cpuUsageUsec == 2071)
    #expect(s.memoryUsageBytes == 5_148_672)
    #expect(s.memoryLimitBytes == 1_073_741_824)
    #expect(s.networkRxBytes == 142)
    #expect(s.networkTxBytes == 602)
    #expect(s.blockReadBytes == 4_878_336)
    #expect(s.blockWriteBytes == 0)
    #expect(s.numProcesses == 1)
}

/// Unknown fields the runtime may add later must be tolerated (lenient).
@Test func statsToleratesUnknownExtraFields() throws {
    let json = """
    [{"id":"x","cpuUsageUsec":10,"memoryUsageBytes":20,"memoryLimitBytes":30,"networkRxBytes":1,"networkTxBytes":2,"blockReadBytes":3,"blockWriteBytes":4,"numProcesses":5,"futureField":"surprise","anotherOne":[1,2,3]}]
    """.data(using: .utf8)!
    let stats = try JSONDecoder().decode([ContainerStats].self, from: json)
    #expect(stats.count == 1)
    #expect(stats.first?.id == "x")
    #expect(stats.first?.numProcesses == 5)
}
