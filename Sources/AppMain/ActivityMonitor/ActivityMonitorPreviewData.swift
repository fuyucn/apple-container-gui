import Foundation
import Core

/// Fixture-backed sample data + mock services for the Activity Monitor
/// `#Preview`s. Builds a `ActivityMonitorViewModel` and feeds it a sequence of
/// `ContainerStats` snapshots via `ingest(_:at:)` so the table shows real rows
/// and the sparkline cards render with accumulated history — all without a live
/// daemon or the real `container` binary.
@MainActor
enum ActivityMonitorPreviewData {
    /// A service returning no stats (drives the empty state).
    static var emptyService: any ContainerService { PreviewStatsService(stats: []) }

    /// A view model pre-seeded with several deltas for two containers so the
    /// sparklines have a meaningful history to draw.
    static func seededViewModel() -> ActivityMonitorViewModel {
        let vm = ActivityMonitorViewModel(service: PreviewStatsService(stats: []))
        let base = Date(timeIntervalSince1970: 0)

        // Walk cumulative counters forward over 24 two-second steps, varying the
        // CPU/network/disk growth so the sparklines wiggle rather than flatline.
        var cpuWeb = 0, cpuDB = 0
        var rxWeb = 0, txDB = 0, blkWeb = 0
        for i in 0..<24 {
            let t = base.addingTimeInterval(Double(i) * 2)
            cpuWeb += (1_000_000 + i % 5 * 200_000)
            cpuDB += (500_000 + i % 3 * 150_000)
            rxWeb += (2048 + i % 4 * 512)
            txDB += 1024
            blkWeb += (i % 6) * 1024
            vm.ingest([
                ContainerStats(
                    id: "web-server",
                    cpuUsageUsec: cpuWeb,
                    memoryUsageBytes: 256 * 1024 * 1024,
                    memoryLimitBytes: 2 * 1024 * 1024 * 1024,
                    networkRxBytes: rxWeb,
                    networkTxBytes: 0,
                    blockReadBytes: 0,
                    blockWriteBytes: blkWeb,
                    numProcesses: 12
                ),
                ContainerStats(
                    id: "postgres-db",
                    cpuUsageUsec: cpuDB,
                    memoryUsageBytes: 512 * 1024 * 1024,
                    memoryLimitBytes: 1 * 1024 * 1024 * 1024,
                    networkRxBytes: 0,
                    networkTxBytes: txDB,
                    blockReadBytes: 0,
                    blockWriteBytes: 0,
                    numProcesses: 8
                ),
            ], at: t)
        }
        return vm
    }
}

/// A minimal `ContainerService` for previews: returns canned stats, succeeds on
/// every action, and produces empty streams. Never touches a process.
private struct PreviewStatsService: ContainerService {
    let stats: [ContainerStats]

    func listContainers() async throws -> [Container] { [] }
    func start(_ id: String) async throws {}
    func stop(_ id: String) async throws {}
    func remove(_ id: String) async throws {}
    func run(_ spec: RunSpec) async throws -> String { "preview-id" }
    func stats(_ ids: [String]) async throws -> [ContainerStats] { stats }
    func listImages() async throws -> [ContainerImage] { [] }
    func pullImage(_ ref: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func removeImage(_ id: String) async throws {}
    func pruneImages() async throws {}
    func tagImage(source: String, newRef: String) async throws {}
    func pushImage(_ ref: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func listVolumes() async throws -> [ContainerVolume] { [] }
    func createVolume(name: String, size: String?, labels: [String: String]) async throws {}
    func removeVolume(_ name: String) async throws {}
    func pruneVolumes() async throws {}
    func listNetworks() async throws -> [ContainerNetwork] { [] }
    func createNetwork(name: String, internal isInternal: Bool, subnet: String?, labels: [String: String]) async throws {}
    func removeNetwork(_ name: String) async throws {}
    func logs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func daemonStatus() async throws -> DaemonStatus {
        DaemonStatus(state: .running, appRoot: nil, installRoot: nil)
    }
    func startDaemon() async throws {}
    func build(dockerfile: String, context: String, tag: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
