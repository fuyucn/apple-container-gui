import Testing
import Foundation
@testable import Core

private func sample(
    id: String = "c1",
    cpu: Int = 0,
    mem: Int = 0,
    memLimit: Int = 0,
    rx: Int = 0,
    tx: Int = 0,
    blkR: Int = 0,
    blkW: Int = 0,
    procs: Int = 1
) -> ContainerStats {
    ContainerStats(
        id: id,
        cpuUsageUsec: cpu,
        memoryUsageBytes: mem,
        memoryLimitBytes: memLimit,
        networkRxBytes: rx,
        networkTxBytes: tx,
        blockReadBytes: blkR,
        blockWriteBytes: blkW,
        numProcesses: procs
    )
}

// MARK: - Pure delta math

@Test func computeMetricsDerivesCPUNetDiskFromDelta() {
    // cpu 1_000_000 -> 3_000_000 usec over dt=2s => (2_000_000/1e6)/2*100 = 100%
    // rx+tx grows by 2048 bytes over 2s => 2048/1024/2 = 1 KB/s
    // blockRead+Write grows by 4096 over 2s => 4096/1024/2 = 2 KB/s
    let prev = sample(cpu: 1_000_000, rx: 1000, tx: 0, blkR: 500, blkW: 0)
    let cur = sample(cpu: 3_000_000, mem: 512, memLimit: 1024,
                     rx: 1000, tx: 2048, blkR: 500, blkW: 4096)

    let m = ActivityMonitorViewModel.computeMetrics(previous: prev, current: cur, dtSeconds: 2)

    #expect(m.cpuPercent == 100)
    #expect(m.netKBs == 1)
    #expect(m.diskKBs == 2)
    #expect(m.memoryBytes == 512)
    #expect(m.memoryLimitBytes == 1024)
    #expect(m.memoryPercent == 50)
}

@Test func computeMetricsFirstSampleHasZeroRates() {
    let cur = sample(cpu: 5_000_000, mem: 256, memLimit: 1024, rx: 9999, tx: 9999)
    let m = ActivityMonitorViewModel.computeMetrics(previous: nil, current: cur, dtSeconds: 2)
    #expect(m.cpuPercent == 0)
    #expect(m.netKBs == 0)
    #expect(m.diskKBs == 0)
    // Memory absolutes still populated.
    #expect(m.memoryBytes == 256)
    #expect(m.memoryLimitBytes == 1024)
}

@Test func computeMetricsZeroDtYieldsZeroRates() {
    let prev = sample(cpu: 1_000_000)
    let cur = sample(cpu: 3_000_000)
    let m = ActivityMonitorViewModel.computeMetrics(previous: prev, current: cur, dtSeconds: 0)
    #expect(m.cpuPercent == 0)
    #expect(m.netKBs == 0)
    #expect(m.diskKBs == 0)
}

// MARK: - Ingest: first sample then delta

@MainActor
@Test func ingestFirstSampleZeroRatesThenDeltaRates() {
    let service = MockContainerService()
    let vm = ActivityMonitorViewModel(service: service)
    let t0 = Date(timeIntervalSince1970: 1000)

    vm.ingest([sample(id: "c1", cpu: 1_000_000, mem: 100, memLimit: 1000)], at: t0)
    #expect(vm.rows.count == 1)
    #expect(vm.rows[0].metrics.cpuPercent == 0) // first sample, no prior

    let t1 = t0.addingTimeInterval(2)
    vm.ingest([sample(id: "c1", cpu: 3_000_000, mem: 100, memLimit: 1000,
                      tx: 2048, blkW: 4096)], at: t1)
    #expect(vm.rows[0].metrics.cpuPercent == 100)
    #expect(vm.rows[0].metrics.netKBs == 1)
    #expect(vm.rows[0].metrics.diskKBs == 2)
}

// MARK: - History is bounded

@MainActor
@Test func historyIsBoundedToCap() {
    let cap = 5
    let service = MockContainerService()
    let vm = ActivityMonitorViewModel(service: service, historyCap: cap)
    let base = Date(timeIntervalSince1970: 0)

    for i in 0..<20 {
        vm.ingest([sample(id: "c1", cpu: i * 1_000_000)], at: base.addingTimeInterval(Double(i)))
    }

    let hist = vm.rows[0].history
    #expect(hist.cpuPercent.count == cap)
    #expect(hist.memoryBytes.count == cap)
    #expect(hist.netKBs.count == cap)
    #expect(hist.diskKBs.count == cap)
}

// MARK: - Aggregate sums rows

@MainActor
@Test func aggregateSumsRows() {
    let service = MockContainerService()
    let vm = ActivityMonitorViewModel(service: service)
    let t0 = Date(timeIntervalSince1970: 0)
    let t1 = t0.addingTimeInterval(2)

    // Two containers, seed prior at t0.
    vm.ingest([
        sample(id: "a", cpu: 0, mem: 100, memLimit: 1000),
        sample(id: "b", cpu: 0, mem: 200, memLimit: 2000),
    ], at: t0)

    // At t1: a does 2_000_000 usec (=>100%) + 2048 net; b does 1_000_000 usec (=>50%) + 1024 disk.
    vm.ingest([
        sample(id: "a", cpu: 2_000_000, mem: 100, memLimit: 1000, tx: 2048),
        sample(id: "b", cpu: 1_000_000, mem: 200, memLimit: 2000, blkW: 1024),
    ], at: t1)

    let agg = try! #require(vm.aggregate)
    #expect(agg.cpuPercent == 150)        // 100 + 50
    #expect(agg.memoryBytes == 300)       // 100 + 200
    #expect(agg.memoryLimitBytes == 3000) // 1000 + 2000
    #expect(agg.netKBs == 1)              // 2048/1024/2 from a
    #expect(agg.diskKBs == 0.5)           // 1024/1024/2 from b
}

@MainActor
@Test func aggregateNilBeforeFirstSample() {
    let vm = ActivityMonitorViewModel(service: MockContainerService())
    #expect(vm.aggregate == nil)
    #expect(vm.rows.isEmpty)
}

// MARK: - pollOnce uses the service

@MainActor
@Test func pollOnceFetchesAllStats() async {
    let service = MockContainerService(stats: [sample(id: "c1", cpu: 1_000_000, mem: 50, memLimit: 100)])
    let vm = ActivityMonitorViewModel(service: service)

    await vm.pollOnce()

    #expect(service.statsCalls == [[]]) // empty ids => all containers
    #expect(vm.rows.count == 1)
    #expect(vm.rows[0].id == "c1")
}

// MARK: - stopPolling leaves no running task

@MainActor
@Test func stopPollingLeavesNoRunningTask() async {
    let vm = ActivityMonitorViewModel(service: MockContainerService())
    vm.startPolling(interval: .milliseconds(10))
    #expect(vm.isPolling)
    vm.stopPolling()
    #expect(!vm.isPolling)
}
