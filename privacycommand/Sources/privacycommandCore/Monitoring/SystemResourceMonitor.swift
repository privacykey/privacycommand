import Foundation
import Darwin

/// Per-PID-tree CPU / RAM / disk-I/O sampler. Polls `proc_pid_rusage_v0`
/// every second across the inspected app's tracked PID set, computes
/// deltas vs. the previous tick, and emits a `Sample` summarising the
/// process tree's resource use.
///
/// Maintains a rolling baseline of recent CPU% so anomaly detection can
/// flag spikes (current > 2× baseline AND > 25% absolute). Spikes are
/// surfaced by the watch-mode change detector — no separate stream of
/// alerts here, just a `wasSpike` flag on each sample.
public actor SystemResourceMonitor {

    // MARK: - Sample

    public struct Sample: Sendable, Hashable, Codable, Identifiable {
        public var id: Date { timestamp }
        public let timestamp: Date
        public let pidCount: Int
        /// Aggregated CPU percentage across the tracked PID tree, where
        /// 100% means "one fully-saturated logical core". An app that
        /// pegs four cores returns ~400%.
        public let cpuPercent: Double
        public let residentBytes: UInt64
        public let diskReadBytesDelta: UInt64
        public let diskWriteBytesDelta: UInt64
        /// True if this sample is more than `spikeMultiplier` × the
        /// recent rolling-average CPU% AND above `spikeFloor`.
        public let wasSpike: Bool
    }

    // MARK: - Stream + state

    public nonisolated let stream: AsyncStream<Sample>
    private var continuation: AsyncStream<Sample>.Continuation?

    private var trackedPIDs: Set<Int32> = []
    private var pollTask: Task<Void, Never>?
    private var stopped = false

    public nonisolated let pollInterval: TimeInterval

    /// Per-PID rusage from the previous tick. Used to compute deltas.
    /// We use v2 because that's the flavor that introduced the
    /// `ri_diskio_bytesread` / `ri_diskio_byteswritten` fields. v0
    /// would compile but doesn't expose disk I/O at all.
    private var lastRusage: [Int32: rusage_info_v2] = [:]
    private var lastSampleAt: Date?
    /// Rolling window of recent CPU% samples. Capped at
    /// `baselineWindow` — older entries get dropped.
    private var cpuHistory: [Double] = []
    private let baselineWindow = 60   // seconds (at 1 Hz polling)
    private let spikeMultiplier: Double = 2.0
    private let spikeFloor: Double = 25.0

    // MARK: - Init

    public init(pollInterval: TimeInterval = 1.0) {
        self.pollInterval = pollInterval
        // makeStream() avoids the IUO trick — see LiveProbeMonitor.init.
        let (stream, continuation) = AsyncStream<Sample>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    public func updatePIDs(_ pids: Set<Int32>) {
        trackedPIDs = pids
    }

    public func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        stopped = true
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
    }

    // MARK: - Tick

    private func tick() async {
        guard !stopped else { return }
        let now = Date()
        var totalUserNs: UInt64 = 0
        var totalSysNs: UInt64 = 0
        var totalResident: UInt64 = 0
        var totalDiskRead: UInt64 = 0
        var totalDiskWrite: UInt64 = 0
        var newRusage: [Int32: rusage_info_v2] = [:]

        for pid in trackedPIDs where pid > 1 {
            guard let r = pidRusage(pid: pid) else { continue }
            newRusage[pid] = r
            // Resident bytes is a snapshot, not a delta.
            totalResident += r.ri_resident_size
            // CPU and disk are cumulative since process start, so we
            // compute deltas vs. the last tick.
            if let prev = lastRusage[pid] {
                totalUserNs += r.ri_user_time.saturatingSub(prev.ri_user_time)
                totalSysNs  += r.ri_system_time.saturatingSub(prev.ri_system_time)
                totalDiskRead  += r.ri_diskio_bytesread.saturatingSub(prev.ri_diskio_bytesread)
                totalDiskWrite += r.ri_diskio_byteswritten.saturatingSub(prev.ri_diskio_byteswritten)
            }
        }
        lastRusage = newRusage

        // CPU% — total CPU-ns spent in the window divided by the
        // window's wall-clock duration. 100% == one fully saturated
        // core; an app on four cores can read ~400%.
        let elapsed = lastSampleAt.map { now.timeIntervalSince($0) } ?? pollInterval
        let cpuPercent = elapsed > 0
            ? Double(totalUserNs + totalSysNs) / 1_000_000_000.0 / elapsed * 100.0
            : 0.0
        lastSampleAt = now

        // Update the rolling baseline before computing the spike flag —
        // a sustained 80% load shouldn't trigger spike alerts forever.
        cpuHistory.append(cpuPercent)
        if cpuHistory.count > baselineWindow {
            cpuHistory.removeFirst(cpuHistory.count - baselineWindow)
        }
        let baseline = cpuHistory.count > 5
            ? cpuHistory.dropLast().reduce(0, +) / Double(cpuHistory.count - 1)
            : 0.0
        let isSpike = cpuPercent > spikeFloor
            && (baseline == 0 || cpuPercent > baseline * spikeMultiplier)

        let sample = Sample(
            timestamp: now,
            pidCount: trackedPIDs.count,
            cpuPercent: cpuPercent,
            residentBytes: totalResident,
            diskReadBytesDelta: totalDiskRead,
            diskWriteBytesDelta: totalDiskWrite,
            wasSpike: isSpike)
        continuation?.yield(sample)
    }

    // MARK: - libproc shim

    /// Returns `proc_pid_rusage` v2 for a single PID, or nil if the
    /// kernel rejected the call (process exited / not visible to us).
    /// v2 is the flavor that introduced disk-I/O byte counters, which
    /// we need for the per-tick disk-read / disk-write deltas.
    private func pidRusage(pid: Int32) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        return rc == 0 ? info : nil
    }
}

// MARK: - UInt64 saturating subtract

private extension UInt64 {
    /// Saturating subtract — returns 0 if `other` > self. We hit this
    /// when `proc_pid_rusage` returns counters that decreased (rare —
    /// happens when a PID gets reused for a new process between our
    /// ticks). Wrapping arithmetic would balloon to ~2^64, throwing
    /// off the totals.
    func saturatingSub(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}
