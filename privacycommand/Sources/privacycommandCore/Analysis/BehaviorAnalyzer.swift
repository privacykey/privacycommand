import Foundation

/// Pattern detection over a finished or in-progress run's
/// `[DynamicEvent]`.
///
/// We surface three classes of behaviour:
///
///   * **Periodic beacons.** Connections to the same destination at a
///     regular cadence (within ±10 % jitter) — heartbeats, telemetry
///     pings, license checks. Loud signal because legitimate apps rarely
///     have many of these, and malware *always* does.
///
///   * **Bursts.** Lots of events to one path or destination in a very
///     short window — credential harvesting (reading `~/Library/Cookies`
///     dozens of times in a second), bulk file enumeration, exfil
///     uploads.
///
///   * **Undeclared destinations.** Network endpoints contacted at runtime
///     that don't match any hard-coded URL/domain or ATS exception in the
///     static report. Often perfectly benign (CDNs, third-party SDKs) but
///     worth surfacing because the dev hasn't told us about them.
public enum BehaviorAnalyzer {

    public static func analyse(events: [DynamicEvent],
                               staticReport: StaticReport?) -> BehaviorReport {
        var anomalies: [BehaviorReport.Anomaly] = []
        anomalies.append(contentsOf: detectPeriodicBeacons(events: events))
        anomalies.append(contentsOf: detectBursts(events: events))
        if let staticReport {
            anomalies.append(contentsOf: detectUndeclaredHosts(
                events: events, staticReport: staticReport))
        }
        return BehaviorReport(anomalies: anomalies.sorted(by: { $0.severity > $1.severity }))
    }

    // MARK: - Periodic beacons

    private static func detectPeriodicBeacons(events: [DynamicEvent]) -> [BehaviorReport.Anomaly] {
        // Bucket network events by remote host (or numeric address as fallback).
        struct Beacon { let host: String; let timestamps: [Date] }
        var byHost: [String: [Date]] = [:]
        for case .network(let n) in events {
            let key = n.remoteHostname ?? n.tlsSNI ?? n.remoteEndpoint.address
            byHost[key, default: []].append(n.firstSeen)
        }

        var out: [BehaviorReport.Anomaly] = []
        for (host, raw) in byHost {
            let stamps = raw.sorted()
            guard stamps.count >= 4 else { continue }
            // Compute inter-arrival gaps, then check whether stddev is small
            // relative to the mean (jitter ≤ 10 %).
            let gaps = zip(stamps.dropFirst(), stamps).map { $0.timeIntervalSince($1) }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            guard mean >= 5 else { continue }   // ignore sub-5s gaps; likely chatty UI calls
            let variance = gaps.map { pow($0 - mean, 2) }.reduce(0, +) / Double(gaps.count)
            let stddev = variance.squareRoot()
            let jitter = mean > 0 ? stddev / mean : 1
            guard jitter < 0.1 else { continue }
            let interval = formatInterval(mean)
            out.append(BehaviorReport.Anomaly(
                kind: .periodicBeacon,
                severity: .medium,
                title: "Periodic beacon to \(host)",
                summary: "Connections every ~\(interval) (\(stamps.count) hits, ±\(Int((jitter * 100).rounded()))% jitter).",
                evidence: ["host=\(host)", "interval=\(interval)", "samples=\(stamps.count)"],
                kbArticleID: "behavior-periodic-beacon"))
        }
        return out
    }

    // MARK: - Bursts

    private static func detectBursts(events: [DynamicEvent]) -> [BehaviorReport.Anomaly] {
        // Sliding-window count: > 50 events touching the same path/host
        // inside a 2-second window is a burst.
        let burstThreshold = 50
        let windowSeconds: TimeInterval = 2

        struct Hit { let key: String; let timestamp: Date }
        var hits: [Hit] = []
        for ev in events {
            switch ev {
            case .file(let f):
                hits.append(Hit(key: "file:" + collapsePath(f.path), timestamp: f.timestamp))
            case .network(let n):
                let host = n.remoteHostname ?? n.tlsSNI ?? n.remoteEndpoint.address
                hits.append(Hit(key: "host:" + host, timestamp: n.firstSeen))
            case .process: continue
            }
        }
        let byKey = Dictionary(grouping: hits, by: \.key)
        var out: [BehaviorReport.Anomaly] = []
        for (key, hs) in byKey where hs.count >= burstThreshold {
            let sorted = hs.sorted(by: { $0.timestamp < $1.timestamp })
            // Slide a window across the sorted timestamps.
            var i = 0
            for j in 0..<sorted.count {
                while sorted[j].timestamp.timeIntervalSince(sorted[i].timestamp) > windowSeconds {
                    i += 1
                }
                let window = j - i + 1
                if window >= burstThreshold {
                    out.append(BehaviorReport.Anomaly(
                        kind: .burst,
                        severity: .high,
                        title: "Burst against \(displayKey(key))",
                        summary: "\(window) events in \(Int(windowSeconds))s — significantly higher than typical app behaviour.",
                        evidence: ["key=\(key)", "count=\(window)"],
                        kbArticleID: "behavior-burst"))
                    break  // one alert per key is enough
                }
            }
        }
        return out
    }

    // MARK: - Undeclared destinations

    private static func detectUndeclaredHosts(events: [DynamicEvent],
                                              staticReport: StaticReport) -> [BehaviorReport.Anomaly] {
        // Build a haystack of declared hosts: hard-coded domains/URLs and
        // ATS exception domains. Anything contacted at runtime that isn't
        // in this set is "undeclared".
        var declared = Set<String>()
        for u in staticReport.hardcodedURLs {
            if let host = URL(string: u)?.host?.lowercased() { declared.insert(host) }
        }
        for d in staticReport.hardcodedDomains { declared.insert(d.lowercased()) }
        if let ats = staticReport.atsConfig {
            for ex in ats.exceptionDomains { declared.insert(ex.domain.lowercased()) }
        }

        var contacted = Set<String>()
        for case .network(let n) in events {
            let host = (n.remoteHostname ?? n.tlsSNI)?.lowercased()
            guard let host, !host.isEmpty else { continue }
            contacted.insert(host)
        }

        let undeclared = contacted.filter { host in
            // Match if any declared domain is a suffix of `host` (so
            // `assets.example.com` matches a declared `example.com`).
            !declared.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        }

        guard !undeclared.isEmpty else { return [] }
        return [BehaviorReport.Anomaly(
            kind: .undeclaredHost,
            severity: .low,
            title: "Contacted \(undeclared.count) host\(undeclared.count == 1 ? "" : "s") not declared in the bundle",
            summary: "These destinations didn't appear in the binary's hard-coded URLs / domains or any ATS exception. Often a CDN or third-party SDK.",
            evidence: Array(undeclared.sorted().prefix(10)),
            kbArticleID: "behavior-undeclared-host")]
    }

    // MARK: - Helpers

    private static func collapsePath(_ path: String) -> String {
        // Collapse any home-directory subpath into `~`, and any
        // numeric-only suffix into `*`. Keeps related events grouped.
        var p = path
        let home = NSHomeDirectory()
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        if let r = p.range(of: #"/\d+$"#, options: .regularExpression) {
            p = String(p[..<r.lowerBound]) + "/*"
        }
        return p
    }

    private static func formatInterval(_ s: TimeInterval) -> String {
        if s < 60 { return "\(Int(s.rounded()))s" }
        if s < 3600 { return "\(Int((s / 60).rounded()))m" }
        return String(format: "%.1fh", s / 3600)
    }

    private static func displayKey(_ key: String) -> String {
        if key.hasPrefix("file:") { return String(key.dropFirst(5)) }
        if key.hasPrefix("host:") { return String(key.dropFirst(5)) }
        return key
    }
}

// MARK: - Public types

public struct BehaviorReport: Sendable, Hashable, Codable {
    public let anomalies: [Anomaly]
    public init(anomalies: [Anomaly] = []) { self.anomalies = anomalies }
    public static let empty = BehaviorReport()

    public struct Anomaly: Sendable, Hashable, Codable, Identifiable {
        public var id: String { "\(kind.rawValue):\(title.prefix(80))" }

        public enum Kind: String, Sendable, Hashable, Codable {
            case periodicBeacon = "Periodic beacon"
            case burst          = "Activity burst"
            case undeclaredHost = "Undeclared destination"
        }
        public enum Severity: String, Sendable, Hashable, Codable, Comparable {
            case low, medium, high
            public static func < (a: Severity, b: Severity) -> Bool {
                let order: [Severity] = [.low, .medium, .high]
                return order.firstIndex(of: a)! < order.firstIndex(of: b)!
            }
        }

        public let kind: Kind
        public let severity: Severity
        public let title: String
        public let summary: String
        public let evidence: [String]
        public let kbArticleID: String?
    }
}
