import Foundation

/// Snapshot-style monitor that polls `lsof -p <pids>` (no `-i` filter) every
/// `pollInterval` and emits the entire current set of open file descriptors
/// for the tracked process tree. The Sloth-style "what is this app holding
/// open right now?" view is built off this stream.
///
/// Stream items are full snapshots, not deltas — the view replaces its state
/// with each emission. Keeps consumer code simple at the cost of some
/// redundant data per tick.
public actor ResourceMonitor {

    public nonisolated let stream: AsyncStream<[OpenResource]>
    private var continuation: AsyncStream<[OpenResource]>.Continuation?

    public nonisolated let pollInterval: TimeInterval
    private var pids: Set<Int32>
    private var pollTask: Task<Void, Never>?
    private var stopped = false

    public init(initialPIDs: Set<Int32>, pollInterval: TimeInterval = 1.0) {
        self.pids = initialPIDs
        self.pollInterval = pollInterval
        // makeStream() avoids the IUO trick — see LiveProbeMonitor.init.
        let (stream, continuation) = AsyncStream<[OpenResource]>.makeStream(
            bufferingPolicy: .bufferingNewest(4))
        self.stream = stream
        self.continuation = continuation
    }

    public func updatePIDs(_ pids: Set<Int32>) { self.pids = pids }

    public func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
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

    // MARK: - Internal

    private func pollOnce() async {
        guard !stopped, !pids.isEmpty else { return }
        let pidArg = pids.map(String.init).joined(separator: ",")
        // No `-i` here — we want EVERY fd type. lsof's default is to OR the
        // selectors, but with only `-p` there's nothing to OR with, so the
        // output is naturally scoped to those PIDs.
        let result = ProcessRunner.runSync(
            launchPath: "/usr/sbin/lsof",
            arguments: ["-nP", "-w", "-p", pidArg],
            timeout: 6
        )
        guard !stopped else { return }

        var resources: [OpenResource] = []
        for line in result.stdout.split(separator: "\n").dropFirst() {   // header
            if stopped { return }
            if let r = ResourceMonitor.parseLine(String(line)) {
                guard pids.contains(r.pid) else { continue }
                resources.append(r)
            }
        }
        continuation?.yield(resources)
    }

    /// Parse a single `lsof` line. Format (with `-nP`):
    ///   COMMAND  PID  USER  FD  TYPE  DEVICE  SIZE/OFF  NODE  NAME...
    /// Several columns can be empty; we use a tolerant tokenizer.
    static func parseLine(_ line: String) -> OpenResource? {
        let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard cols.count >= 5 else { return nil }
        let processName = cols[0]
        guard let pid = Int32(cols[1]) else { return nil }
        let user = cols[2]
        let fd = cols[3]
        let typeRaw = cols[4]
        let kind = OpenResource.Kind.from(lsofType: typeRaw)

        // Columns 5..7 are optional — DEVICE, SIZE/OFF, NODE.
        var idx = 5
        var device: String?
        var sizeOff: String?
        var node: String?
        if cols.count > idx, looksLikeDevice(cols[idx])  { device = cols[idx]; idx += 1 }
        if cols.count > idx, looksLikeSizeOff(cols[idx]) { sizeOff = cols[idx]; idx += 1 }
        if cols.count > idx, looksLikeNode(cols[idx])    { node = cols[idx]; idx += 1 }

        // Everything left is the NAME (paths can contain spaces).
        let name = cols[idx...].joined(separator: " ")
        guard !name.isEmpty else { return nil }

        return OpenResource(
            pid: pid, processName: processName, user: user,
            fd: fd, kind: kind, typeRaw: typeRaw,
            device: device, sizeOrOffset: sizeOff, node: node,
            name: name
        )
    }

    // Tiny heuristics for the optional columns. lsof's spacing isn't always
    // predictable so we look at content, not position.
    private static func looksLikeDevice(_ s: String) -> Bool {
        // Devices are like "0x...", "1,5", or hex digits. They aren't paths.
        return s.hasPrefix("0x") || (s.contains(",") && s.allSatisfy { $0.isNumber || $0 == "," }) ||
               (s.allSatisfy { $0.isHexDigit } && s.count >= 4 && s.count <= 16)
    }
    private static func looksLikeSizeOff(_ s: String) -> Bool {
        // SIZE/OFF is "0t1234" or "1234B" or pure digits.
        if s.hasPrefix("0t") || s.hasSuffix("B") { return true }
        if let _ = Int(s), s.count <= 12 { return true }
        return false
    }
    private static func looksLikeNode(_ s: String) -> Bool {
        // NODE is usually pure digits, or a protocol like "TCP" / "UDP".
        if let _ = Int(s) { return true }
        let known: Set<String> = ["TCP", "UDP", "STREAM", "DGRAM", "ICMP", "ICMPv6", "PIPE"]
        return known.contains(s.uppercased())
    }
}
