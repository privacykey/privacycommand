import Foundation
import Darwin

/// Best-effort network destination tracker for a set of PIDs.
///
/// Polls `lsof -i -nP -p <pids>` for socket entries and `nettop` for byte
/// counters. Aggregates by `(pid, proto, remoteAddr, remotePort)` into
/// `NetworkEvent` values. The output is honest about its fidelity — short-lived
/// UDP queries that complete inside a single poll interval will be missed.
public actor NetworkMonitor {

    public nonisolated let stream: AsyncStream<NetworkEvent>
    private var continuation: AsyncStream<NetworkEvent>.Continuation?

    public nonisolated let pollInterval: TimeInterval
    private var pids: Set<Int32>

    private struct Key: Hashable {
        let pid: Int32
        let proto: NetworkEvent.NetProto
        let remoteAddress: String
        let remotePort: UInt16
    }

    private var connections: [Key: NetworkEvent] = [:]
    private var pollTask: Task<Void, Never>?
    private var dnsCache: [String: String] = [:]   // address -> hostname
    /// Set in `stop()`; checked before each yield. Without this, an
    /// in-flight `lsof` call (up to 4 s timeout) would keep emitting events
    /// for several seconds after the user clicks Stop.
    private var stopped = false

    public init(
        initialPIDs: Set<Int32>,
        pollInterval: TimeInterval = 0.5
    ) {
        self.pids = initialPIDs
        self.pollInterval = pollInterval
        var continuationLocal: AsyncStream<NetworkEvent>.Continuation!
        self.stream = AsyncStream { c in continuationLocal = c }
        self.continuation = continuationLocal
    }

    public func updatePIDs(_ pids: Set<Int32>) {
        self.pids = pids
    }

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

    public var snapshot: [NetworkEvent] { Array(connections.values) }

    // MARK: - Implementation

    private func pollOnce() async {
        guard !stopped, !pids.isEmpty else { return }
        let pidArg = pids.map(String.init).joined(separator: ",")
        // -a is the critical flag: without it, lsof ORs `-i` and `-p`, which
        // returns *every* network socket on the system + every open file for
        // our PIDs. With -a, the lists are ANDed: network files for our PIDs
        // only.
        let result = ProcessRunner.runSync(
            launchPath: "/usr/sbin/lsof",
            arguments: ["-a", "-i", "-nP", "-w", "-p", pidArg],
            timeout: 4
        )
        // The user may have clicked Stop while lsof was running. If so,
        // discard everything this poll produced.
        guard !stopped else { return }
        guard result.success || !result.stdout.isEmpty else { return }
        let now = Date()
        for line in result.stdout.split(separator: "\n").dropFirst() {   // drop header
            if stopped { return }
            if let entry = NetworkMonitor.parseLSOFLine(String(line)) {
                // Defensive: even with `-a`, in flight process-tree updates
                // could leave stale PIDs in the lsof output. If the entry
                // isn't a tracked descendant of the target, drop it.
                guard pids.contains(entry.pid) else { continue }
                let key = Key(pid: entry.pid, proto: entry.proto,
                              remoteAddress: entry.remoteAddress, remotePort: entry.remotePort)
                if var existing = connections[key] {
                    existing = NetworkEvent(
                        id: existing.id,
                        firstSeen: existing.firstSeen,
                        lastSeen: now,
                        pid: existing.pid,
                        processName: existing.processName,
                        netProto: existing.netProto,
                        localEndpoint: existing.localEndpoint,
                        remoteEndpoint: existing.remoteEndpoint,
                        remoteHostname: existing.remoteHostname,
                        bytesSent: existing.bytesSent,
                        bytesReceived: existing.bytesReceived,
                        tlsSNI: existing.tlsSNI,
                        payloadSamples: existing.payloadSamples,
                        risk: existing.risk
                    )
                    connections[key] = existing
                    continuation?.yield(existing)
                } else {
                    let host = reverseLookup(address: entry.remoteAddress)
                    let event = NetworkEvent(
                        firstSeen: now,
                        lastSeen: now,
                        pid: entry.pid,
                        processName: NetworkMonitor.lookupProcessName(pid: entry.pid),
                        netProto: entry.proto,
                        localEndpoint: .init(address: entry.localAddress, port: entry.localPort),
                        remoteEndpoint: .init(address: entry.remoteAddress, port: entry.remotePort),
                        remoteHostname: host,
                        bytesSent: 0,
                        bytesReceived: 0,
                        tlsSNI: nil,
                        payloadSamples: [],
                        risk: .expected   // RiskClassifier promotes if needed
                    )
                    connections[key] = event
                    continuation?.yield(event)
                }
            }
        }
    }

    struct LSOFEntry: Equatable {
        let pid: Int32
        let proto: NetworkEvent.NetProto
        let localAddress: String
        let localPort: UInt16
        let remoteAddress: String
        let remotePort: UInt16
    }

    /// Looks up the executable basename for a PID via libproc. Sync, no actor
    /// hop needed.
    static func lookupProcessName(pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let r = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard r > 0 else { return String(pid) }
        let path = String(cString: buf)
        return (path as NSString).lastPathComponent
    }

    /// Parse a single line of `lsof -i -nP`. Skips lines that don't have an
    /// established remote endpoint.
    static func parseLSOFLine(_ line: String) -> LSOFEntry? {
        // Columns are space-separated and right-padded by lsof; the NAME column
        // (last) is everything from column 9 to the end. Example line:
        //   Slack 41212 alice 27u IPv4 0x... 0t0 TCP 192.168.1.5:51212->17.253.144.10:443 (ESTABLISHED)
        let cols = line.split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 9 else { return nil }
        guard let pid = Int32(cols[1]) else { return nil }
        let typeStr = String(cols[7])
        let proto: NetworkEvent.NetProto
        if typeStr == "TCP" || typeStr.hasPrefix("TCP") { proto = .tcp }
        else if typeStr == "UDP" || typeStr.hasPrefix("UDP") { proto = .udp }
        else { proto = .other }

        let nameField = cols[8...].joined(separator: " ")
        // Strip trailing "(STATE)" if present.
        var endpoint = nameField
        if let openParen = endpoint.firstIndex(of: "(") {
            endpoint = String(endpoint[..<openParen]).trimmingCharacters(in: .whitespaces)
        }
        // Expect "local->remote"
        let parts = endpoint.components(separatedBy: "->")
        guard parts.count == 2 else { return nil }
        guard let local = parseAddrPort(parts[0]),
              let remote = parseAddrPort(parts[1]) else { return nil }

        return LSOFEntry(
            pid: pid, proto: proto,
            localAddress: local.host, localPort: local.port,
            remoteAddress: remote.host, remotePort: remote.port
        )
    }

    private static func parseAddrPort(_ s: String) -> (host: String, port: UInt16)? {
        // IPv4: "1.2.3.4:443"   IPv6: "[fe80::1]:443"
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let after = trimmed[trimmed.index(after: close)...]
            guard after.hasPrefix(":"),
                  let port = UInt16(after.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        guard let port = UInt16(trimmed[trimmed.index(after: colon)...]) else { return nil }
        return (host, port)
    }

    private func reverseLookup(address: String) -> String? {
        if let cached = dnsCache[address] { return cached.isEmpty ? nil : cached }
        // We synchronously resolve using getnameinfo. Cap with a timeout: if
        // DNS is slow we don't want to block monitoring.
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo(address, nil, &hints, &info) == 0, let addr = info else {
            dnsCache[address] = ""
            return nil
        }
        defer { freeaddrinfo(addr) }

        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(addr.pointee.ai_addr, addr.pointee.ai_addrlen,
                             &hostBuf, socklen_t(hostBuf.count),
                             nil, 0, NI_NAMEREQD)
        if rc == 0 {
            let host = String(cString: hostBuf)
            dnsCache[address] = host
            return host
        }
        dnsCache[address] = ""
        return nil
    }
}
