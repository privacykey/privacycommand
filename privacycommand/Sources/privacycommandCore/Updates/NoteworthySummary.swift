import Foundation

/// A compact "is there anything worth a second look here?" view of a
/// `StaticReport`. Built entirely from fields the analyzer already produces —
/// this is a presentation layer over `StaticReport` + `RiskScorer`, not new
/// detection. Used by the CLI `preview` command and reusable by the GUI.
public struct NoteworthySummary: Sendable, Hashable, Codable {
    public let riskScore: Int
    public let tier: RiskTier
    /// Warn/error findings only — info-level noise is dropped.
    public let findings: [Finding]
    /// Plain-language one-liners for the things most people care about
    /// (trackers, weakened hardening, unsigned code, hard-coded secrets…).
    public let signals: [String]
    public let isNoteworthy: Bool
    public let headline: String

    public init(riskScore: Int, tier: RiskTier, findings: [Finding],
                signals: [String], isNoteworthy: Bool, headline: String) {
        self.riskScore = riskScore
        self.tier = tier
        self.findings = findings
        self.signals = signals
        self.isNoteworthy = isNoteworthy
        self.headline = headline
    }

    /// Distil a report into its noteworthy highlights.
    public static func summarize(_ report: StaticReport,
                                 scorer: RiskScorer = RiskScorer()) -> NoteworthySummary {
        let score = scorer.score(staticReport: report)
        let findings = report.warnings.filter { $0.severity != .info }
        let signals = deriveSignals(report)

        // "Noteworthy" = the risk crosses into medium+, OR there's a warn/error
        // finding, OR any high-signal flag fired.
        let noteworthy = score.tier != .low || !findings.isEmpty || !signals.isEmpty

        let headline: String
        if !noteworthy {
            headline = "Nothing noteworthy — \(score.tier.label.lowercased()) risk (\(score.score)/100)."
        } else {
            var bits = ["\(score.tier.label) risk (\(score.score)/100)"]
            if !findings.isEmpty { bits.append("\(findings.count) finding\(plural(findings.count))") }
            if !signals.isEmpty { bits.append("\(signals.count) signal\(plural(signals.count))") }
            headline = bits.joined(separator: ", ")
        }

        return NoteworthySummary(riskScore: score.score, tier: score.tier,
                                 findings: findings, signals: signals,
                                 isNoteworthy: noteworthy, headline: headline)
    }

    // MARK: - Signal derivation

    /// The human-facing flags. `internal` so unit tests can assert on it directly.
    static func deriveSignals(_ r: StaticReport) -> [String] {
        var s: [String] = []

        // Signing / notarization posture.
        switch r.notarization {
        case .notarized, .unknown:
            break
        case .developerIDOnly:
            s.append("Signed but not notarized by Apple")
        case .unsigned:
            s.append("Unsigned — no verifiable developer")
        case .rejected(let why):
            s.append("Gatekeeper rejected this build: \(flatten(why))")
        }
        if r.codeSigning.isAdhocSigned {
            s.append("Ad-hoc signed (no Developer ID)")
        }

        // Hardening weakened.
        if r.entitlements.disablesLibraryValidation {
            s.append("Disables library validation (can load unsigned code)")
        }
        if r.entitlements.allowsDyldEnvironmentVariables {
            s.append("Allows DYLD environment variables (injection surface)")
        }
        if r.entitlements.allowsJIT {
            s.append("Allows JIT-compiled code")
        }
        if r.entitlements.endpointSecurityClient {
            s.append("Endpoint Security client (can observe system-wide activity)")
        }
        if r.entitlements.networkServer {
            s.append("Listens as a network server")
        }

        // ATS: arbitrary (non-HTTPS) loads.
        if r.atsConfig?.allowsArbitraryLoads == true {
            s.append("Allows arbitrary (non-HTTPS) network loads")
        }

        // Capabilities exercised in the binary but never declared in Info.plist.
        let undeclared = r.inferredCapabilities.filter { $0.inferredButNotDeclared }
        if !undeclared.isEmpty {
            let cats = Set(undeclared.map { $0.category.rawValue }).sorted()
            s.append("Uses but doesn't declare: \(cats.joined(separator: ", "))")
        }

        // Third-party tracking SDKs.
        let trackers = r.sdkHits.filter { $0.isTrackerLike }
        if !trackers.isEmpty {
            let names = Set(trackers.map { $0.fingerprint.displayName }).sorted()
            s.append("Tracking SDKs: \(names.joined(separator: ", "))")
        }

        // Hard-coded secrets in the binary.
        if !r.secrets.isEmpty {
            s.append("\(r.secrets.count) hard-coded secret\(plural(r.secrets.count)) in the binary")
        }

        // Anti-analysis / anti-debugging — only the medium/high-confidence hits.
        // Low-confidence matches fire on innocuous system apps (Magnifier,
        // Bluetooth File Exchange) and would just add noise.
        if r.antiAnalysis.contains(where: { $0.confidence != .low }) {
            s.append("Anti-analysis / anti-debugging signals")
        }

        // Embedded persistence that runs at load.
        let runAtLoad = r.embeddedAssets.launchPlists.filter { $0.runAtLoad }
        if !runAtLoad.isEmpty {
            s.append("\(runAtLoad.count) embedded launch agent\(plural(runAtLoad.count)) set to run at load")
        }

        return s
    }

    private static func plural(_ n: Int) -> String { n == 1 ? "" : "s" }

    /// Collapse a multi-line tool message (e.g. spctl's Gatekeeper rejection,
    /// which spans several lines) into a single trimmed line so each signal
    /// renders on one row.
    private static func flatten(_ text: String, max: Int = 140) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        return oneLine.count > max ? String(oneLine.prefix(max)) + "…" : oneLine
    }
}
