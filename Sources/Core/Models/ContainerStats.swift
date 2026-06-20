import Foundation

/// A single snapshot from `container stats --no-stream --format json`
/// (container v1.0.0), which returns a JSON array of these objects.
///
/// Every counter except `memoryUsageBytes`/`memoryLimitBytes`/`numProcesses` is
/// CUMULATIVE since the container started: `cpuUsageUsec`, `networkRxBytes`,
/// `networkTxBytes`, `blockReadBytes`, and `blockWriteBytes` only ever grow.
/// Rates (CPU%, KB/s) must therefore be derived from the delta between two
/// snapshots over wall-clock time — this struct is a raw sample, not a rate.
///
/// Decoding is lenient: only the modeled keys are read, so unknown fields the
/// runtime may add later are tolerated (Codable ignores extra keys by default).
public struct ContainerStats: Codable, Sendable, Identifiable, Equatable {
    /// Container id this snapshot belongs to.
    public let id: String
    /// Cumulative CPU time consumed, in microseconds.
    public let cpuUsageUsec: Int
    /// Current memory usage, in bytes (absolute, not cumulative).
    public let memoryUsageBytes: Int
    /// Memory limit, in bytes.
    public let memoryLimitBytes: Int
    /// Cumulative bytes received on the network.
    public let networkRxBytes: Int
    /// Cumulative bytes transmitted on the network.
    public let networkTxBytes: Int
    /// Cumulative bytes read from block storage.
    public let blockReadBytes: Int
    /// Cumulative bytes written to block storage.
    public let blockWriteBytes: Int
    /// Number of processes currently running in the container.
    public let numProcesses: Int

    public init(
        id: String,
        cpuUsageUsec: Int,
        memoryUsageBytes: Int,
        memoryLimitBytes: Int,
        networkRxBytes: Int,
        networkTxBytes: Int,
        blockReadBytes: Int,
        blockWriteBytes: Int,
        numProcesses: Int
    ) {
        self.id = id
        self.cpuUsageUsec = cpuUsageUsec
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.numProcesses = numProcesses
    }
}
