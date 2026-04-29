import Foundation
import Darwin

/// Polls `libproc` to maintain the set of PIDs descended from a root PID.
/// Best-effort: it will miss processes that fork+exec+exit between two polls.
/// Always emit a fidelity note alongside its results.
public actor ProcessTracker {

    public struct Snapshot: Sendable {
        public let pids: Set<Int32>
        public let starts: [ProcessEvent]
        public let exits: [ProcessEvent]
    }

    public nonisolated let rootPID: Int32
    /// Optional bundle path prefix. Any running process whose executable
    /// lives inside this path is treated as part of the target's process
    /// tree, even if its ppid isn't a tracked PID. This catches the common
    /// macOS pattern where apps spawn helpers via XPC/launchd (Chrome,
    /// Slack, VS Code, …) — their ppid is 1, but their executable is at
    /// `/Applications/Foo.app/Contents/.../Foo Helper`.
    public nonisolated let bundlePathPrefix: String?
    private var trackedPIDs: Set<Int32> = []
    private var pidPaths: [Int32: String] = [:]
    private var continuation: AsyncStream<ProcessEvent>.Continuation?
    public nonisolated let stream: AsyncStream<ProcessEvent>

    private var pollTask: Task<Void, Never>?
    public nonisolated let pollInterval: TimeInterval
    /// Mirrors NetworkMonitor.stopped — gates yields so events stop the
    /// instant Stop is clicked, even if a poll is mid-flight.
    private var stopped = false

    public init(rootPID: Int32, bundlePathPrefix: String? = nil,
                pollInterval: TimeInterval = 0.25) {
        self.rootPID = rootPID
        self.bundlePathPrefix = bundlePathPrefix
        self.pollInterval = pollInterval
        // makeStream() avoids the IUO trick — see LiveProbeMonitor.init.
        let (stream, continuation) = AsyncStream<ProcessEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
        self.trackedPIDs.insert(rootPID)
    }

    public func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            // Emit a synthetic start event for the root pid.
            await self.emitStart(pid: self.rootPID, ppid: 0)
            while !Task.isCancelled {
                await self.poll()
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

    public var currentPIDs: Set<Int32> { trackedPIDs }

    // MARK: - Implementation

    private func poll() async {
        guard !stopped else { return }
        let allPIDs = libProcAllPIDs()
        var alive = Set<Int32>()
        var byPID: [Int32: (ppid: Int32, path: String)] = [:]
        for pid in allPIDs {
            guard let info = libProcInfo(pid: pid) else { continue }
            byPID[pid] = info
            alive.insert(pid)
        }

        // Walk the tree from the root, expanding to include any descendant.
        // ALSO seed with any process whose executable path lives inside the
        // target's .app bundle — that catches helpers spawned via launchd
        // / XPC (their ppid is 1, not the main app).
        var newlyTracked = Set<Int32>()
        if let prefix = bundlePathPrefix {
            for (pid, info) in byPID where !trackedPIDs.contains(pid) {
                if !info.path.isEmpty, info.path.hasPrefix(prefix) {
                    newlyTracked.insert(pid)
                }
            }
        }
        var changed = true
        while changed {
            changed = false
            for (pid, info) in byPID where !trackedPIDs.contains(pid)
                                          && !newlyTracked.contains(pid) {
                if trackedPIDs.contains(info.ppid) || newlyTracked.contains(info.ppid) {
                    newlyTracked.insert(pid)
                    changed = true
                }
            }
        }
        for pid in newlyTracked {
            let info = byPID[pid]!
            trackedPIDs.insert(pid)
            pidPaths[pid] = info.path
            emitStart(pid: pid, ppid: info.ppid)
        }

        // Detect exits.
        let exited = trackedPIDs.subtracting(alive)
        for pid in exited where pid != rootPID || !alive.contains(rootPID) {
            emitExit(pid: pid)
            trackedPIDs.remove(pid)
            pidPaths[pid] = nil
        }
    }

    private func emitStart(pid: Int32, ppid: Int32) {
        guard !stopped else { return }
        let path = libProcPath(pid: pid) ?? pidPaths[pid] ?? ""
        pidPaths[pid] = path
        continuation?.yield(ProcessEvent(
            kind: .start, pid: pid, ppid: ppid, path: path, arguments: libProcArgs(pid: pid)
        ))
    }

    private func emitExit(pid: Int32) {
        guard !stopped else { return }
        continuation?.yield(ProcessEvent(
            kind: .exit, pid: pid, ppid: 0, path: pidPaths[pid] ?? "", arguments: nil
        ))
    }

    // MARK: - libproc shims

    private func libProcAllPIDs() -> [Int32] {
        // `proc_listallpids(NULL, 0)` returns the total byte size needed.
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        let count = Int(needed) / MemoryLayout<pid_t>.stride + 32  // small slack
        var buf = [pid_t](repeating: 0, count: count)
        let bytesWritten = proc_listallpids(&buf, Int32(MemoryLayout<pid_t>.stride * buf.count))
        guard bytesWritten > 0 else { return [] }
        let actual = Int(bytesWritten) / MemoryLayout<pid_t>.stride
        return Array(buf.prefix(actual)).filter { $0 > 0 }
    }

    private func libProcInfo(pid: Int32) -> (ppid: Int32, path: String)? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        if r <= 0 { return nil }
        let ppid = Int32(info.pbi_ppid)
        let path = libProcPath(pid: pid) ?? ""
        return (ppid, path)
    }

    private func libProcPath(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let r = proc_pidpath(pid, &buf, UInt32(buf.count))
        if r <= 0 { return nil }
        return String(cString: buf)
    }

    /// Best-effort process arguments via `KERN_PROCARGS2`.
    private func libProcArgs(pid: Int32) -> [String]? {
        var size: size_t = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        if sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) != 0 { return nil }
        var buf = [CChar](repeating: 0, count: size)
        if sysctl(&mib, UInt32(mib.count), &buf, &size, nil, 0) != 0 { return nil }
        guard size >= 4 else { return nil }
        // First 4 bytes = argc as Int32 (host-endian)
        let argc: Int32 = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }
        var args: [String] = []
        var idx = 4
        // Skip exec path (first nul-terminated string) plus its trailing alignment nuls.
        while idx < size && buf[idx] != 0 { idx += 1 }
        while idx < size && buf[idx] == 0 { idx += 1 }
        var collected: Int32 = 0
        while collected < argc && idx < size {
            let start = idx
            while idx < size && buf[idx] != 0 { idx += 1 }
            if start < idx {
                let s = String(cString: Array(buf[start..<idx]) + [0])
                args.append(s)
                collected += 1
            }
            idx += 1
        }
        return args.isEmpty ? nil : args
    }
}
