import Foundation

/// Drives the Activity Monitor UI: polls `service.stats([])` on an interval,
/// derives per-container rates from the delta between consecutive CUMULATIVE
/// snapshots, and keeps a bounded rolling history of each metric for sparklines.
///
/// `@MainActor @Observable` so SwiftUI observes `rows`/`aggregate` directly.
/// Depends only on the `ContainerService` protocol so it is fully unit-testable
/// against a mock.
///
/// Testability: the delta math lives in the pure, time-free
/// `ActivityMonitorViewModel.computeMetrics(previous:current:dtSeconds:)` and
/// `ActivityRow.history` updates via `ActivityRow.appending(...)`, so tests feed
/// two snapshots with a known `dt` and assert exact rates without real time.
@MainActor
@Observable
public final class ActivityMonitorViewModel {
    /// Maximum number of history points retained per metric (sparkline window).
    public static let defaultHistoryCap = 60

    /// Computed, display-ready rates + absolutes for a single container.
    public struct ComputedMetrics: Sendable, Equatable {
        /// CPU utilization percent derived from the cumulative-usec delta.
        public var cpuPercent: Double
        /// Current memory usage in bytes (absolute snapshot value).
        public var memoryBytes: Int
        /// Memory limit in bytes (absolute snapshot value).
        public var memoryLimitBytes: Int
        /// Network throughput (rx+tx) in KB/s derived from the byte delta.
        public var netKBs: Double
        /// Block I/O (read+write) in KB/s derived from the byte delta.
        public var diskKBs: Double

        /// Memory utilization percent (`usage/limit*100`); 0 when limit is 0.
        public var memoryPercent: Double {
            memoryLimitBytes > 0 ? Double(memoryBytes) / Double(memoryLimitBytes) * 100 : 0
        }

        public init(
            cpuPercent: Double = 0,
            memoryBytes: Int = 0,
            memoryLimitBytes: Int = 0,
            netKBs: Double = 0,
            diskKBs: Double = 0
        ) {
            self.cpuPercent = cpuPercent
            self.memoryBytes = memoryBytes
            self.memoryLimitBytes = memoryLimitBytes
            self.netKBs = netKBs
            self.diskKBs = diskKBs
        }
    }

    /// A bounded rolling history of one metric (newest appended at the end).
    public struct MetricHistory: Sendable, Equatable {
        public private(set) var cpuPercent: [Double] = []
        public private(set) var memoryBytes: [Double] = []
        public private(set) var netKBs: [Double] = []
        public private(set) var diskKBs: [Double] = []

        public init() {}

        /// Push one computed sample, evicting the oldest point past `cap`.
        mutating func push(_ m: ComputedMetrics, cap: Int) {
            Self.append(&cpuPercent, m.cpuPercent, cap: cap)
            Self.append(&memoryBytes, Double(m.memoryBytes), cap: cap)
            Self.append(&netKBs, m.netKBs, cap: cap)
            Self.append(&diskKBs, m.diskKBs, cap: cap)
        }

        private static func append(_ buf: inout [Double], _ v: Double, cap: Int) {
            buf.append(v)
            if buf.count > cap { buf.removeFirst(buf.count - cap) }
        }
    }

    /// One container's live metrics + bounded history for the table/sparklines.
    public struct ActivityRow: Identifiable, Sendable, Equatable {
        public let id: String
        public var metrics: ComputedMetrics
        public var history: MetricHistory

        public init(id: String, metrics: ComputedMetrics = .init(), history: MetricHistory = .init()) {
            self.id = id
            self.metrics = metrics
            self.history = history
        }
    }

    /// Per-container rows, sorted by id for stable display.
    public private(set) var rows: [ActivityRow] = []

    /// The synthetic "Containers" aggregate row summing all rows' metrics.
    /// `nil` until the first sample produces at least one row.
    public private(set) var aggregate: ComputedMetrics?

    /// The most recent error surfaced by a poll, if any.
    public private(set) var lastError: String?

    private let service: any ContainerService
    private let historyCap: Int

    /// Previous raw sample per container id, with the timestamp it was taken.
    private var previous: [String: (sample: ContainerStats, time: Date)] = [:]

    /// The running poll loop, if active. Stored so it can be cancelled.
    private var pollTask: Task<Void, Never>?

    public init(service: any ContainerService, historyCap: Int = ActivityMonitorViewModel.defaultHistoryCap) {
        self.service = service
        self.historyCap = max(1, historyCap)
    }

    // MARK: - Pure delta math (deterministic, time-free)

    /// Derive display rates from two CUMULATIVE-counter snapshots over `dtSeconds`.
    ///
    /// Pure and `nonisolated` so tests call it directly with a known `dt`:
    /// - `cpuPercent = (Δcpu µs / 1_000_000) / dt * 100`
    /// - `netKBs     = Δ(rx+tx) bytes / 1024 / dt`
    /// - `diskKBs    = Δ(blockRead+blockWrite) bytes / 1024 / dt`
    /// - `memoryBytes`/`memoryLimitBytes` are absolute (taken from `current`).
    ///
    /// With no `previous` (first sample) or a non-positive `dt`, all rates are 0
    /// while memory absolutes still reflect `current`.
    public nonisolated static func computeMetrics(
        previous: ContainerStats?,
        current: ContainerStats,
        dtSeconds: Double
    ) -> ComputedMetrics {
        var metrics = ComputedMetrics(
            memoryBytes: current.memoryUsageBytes,
            memoryLimitBytes: current.memoryLimitBytes
        )
        guard let prev = previous, dtSeconds > 0 else { return metrics }

        let cpuDeltaUsec = max(0, current.cpuUsageUsec - prev.cpuUsageUsec)
        metrics.cpuPercent = (Double(cpuDeltaUsec) / 1_000_000) / dtSeconds * 100

        let netDelta = max(0, (current.networkRxBytes + current.networkTxBytes)
            - (prev.networkRxBytes + prev.networkTxBytes))
        metrics.netKBs = Double(netDelta) / 1024 / dtSeconds

        let diskDelta = max(0, (current.blockReadBytes + current.blockWriteBytes)
            - (prev.blockReadBytes + prev.blockWriteBytes))
        metrics.diskKBs = Double(diskDelta) / 1024 / dtSeconds

        return metrics
    }

    /// Sum a set of per-container metrics into the aggregate "Containers" row.
    /// CPU/net/disk add; memory usage and limit add (total footprint).
    public nonisolated static func aggregate(_ metrics: [ComputedMetrics]) -> ComputedMetrics {
        metrics.reduce(into: ComputedMetrics()) { acc, m in
            acc.cpuPercent += m.cpuPercent
            acc.memoryBytes += m.memoryBytes
            acc.memoryLimitBytes += m.memoryLimitBytes
            acc.netKBs += m.netKBs
            acc.diskKBs += m.diskKBs
        }
    }

    // MARK: - Sampling

    /// Ingest one batch of raw snapshots taken at `time`, computing rates vs the
    /// stored previous sample per container, updating `rows`/history/`aggregate`.
    ///
    /// Exposed (not private) so tests can drive sampling deterministically with
    /// explicit timestamps instead of relying on the poll loop's wall clock.
    public func ingest(_ samples: [ContainerStats], at time: Date) {
        var existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var nextRows: [ActivityRow] = []

        for sample in samples {
            let prior = previous[sample.id]
            let dt = prior.map { time.timeIntervalSince($0.time) } ?? 0
            let metrics = Self.computeMetrics(
                previous: prior?.sample,
                current: sample,
                dtSeconds: dt
            )

            var row = existing[sample.id] ?? ActivityRow(id: sample.id)
            row.metrics = metrics
            row.history.push(metrics, cap: historyCap)
            nextRows.append(row)

            previous[sample.id] = (sample, time)
            existing[sample.id] = nil
        }

        // Drop previous-sample state for containers no longer reported.
        let liveIDs = Set(samples.map(\.id))
        previous = previous.filter { liveIDs.contains($0.key) }

        rows = nextRows.sorted { $0.id < $1.id }
        aggregate = rows.isEmpty ? nil : Self.aggregate(rows.map(\.metrics))
    }

    /// Poll once: fetch all stats and ingest them stamped with the current time.
    /// Errors are captured into `lastError` so the poll loop never crashes.
    public func pollOnce() async {
        do {
            let samples = try await service.stats([])
            ingest(samples, at: Date())
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Polling lifecycle

    /// Begin polling: sample now and every `interval` until stopped. Cancels any
    /// existing poll loop first so there is never more than one running.
    public func startPolling(interval: Duration) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                if Task.isCancelled { break }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Stop polling and release the task. Idempotent; safe from `onDisappear`.
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Whether a poll loop is currently running (test/diagnostic aid).
    public var isPolling: Bool { pollTask != nil && !(pollTask?.isCancelled ?? true) }
}
