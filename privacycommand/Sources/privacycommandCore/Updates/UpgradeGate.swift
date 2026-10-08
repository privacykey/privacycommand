import Foundation

/// Decides, per outdated cask, whether an upgrade is **cleared** (fine to
/// apply without a human look) or **held** for review, from a risk threshold.
///
/// Pure: the CLI feeds it the `NoteworthySummary` it already has for the
/// installed or incoming build; it never touches brew. Backs
/// `privacycommand preview --max-risk` (the exit-code gate) and
/// `privacycommand upgrade --max-risk` (which then applies the cleared ones).
public enum UpgradeGate {

    /// The highest risk score (0–100) still upgraded without review.
    public struct Threshold: Sendable, Hashable, Codable {
        public let maxScore: Int

        public init(maxScore: Int) {
            self.maxScore = max(0, min(100, maxScore))
        }

        /// A tier name (`low|medium|high|critical`, any case) means "that
        /// tier is still fine" — the top score of the tier. A whole number
        /// 0–100 is used as-is. Anything else is nil.
        public static func parse(_ text: String) -> Threshold? {
            let t = text.trimmingCharacters(in: .whitespaces).lowercased()
            switch t {
            case "low":      return Threshold(maxScore: upperBound(of: .low))
            case "medium":   return Threshold(maxScore: upperBound(of: .medium))
            case "high":     return Threshold(maxScore: upperBound(of: .high))
            case "critical": return Threshold(maxScore: upperBound(of: .critical))
            default:
                guard let n = Int(t), (0...100).contains(n) else { return nil }
                return Threshold(maxScore: n)
            }
        }

        /// The highest score that still lands in `tier` — the inverse of
        /// `RiskTier.from(score:)`'s bands.
        public static func upperBound(of tier: RiskTier) -> Int {
            switch tier {
            case .low:      return 19
            case .medium:   return 49
            case .high:     return 79
            case .critical: return 100
            }
        }

        /// The tier `maxScore` itself falls in.
        public var tier: RiskTier { RiskTier.from(score: maxScore) }

        /// e.g. "49/100 (medium)".
        public var description: String { "\(maxScore)/100 (\(tier.label.lowercased()))" }
    }

    /// Which build a decision was judged on.
    public enum Basis: String, Sendable, Hashable, Codable {
        /// The downloaded incoming build (`--fetch` / `upgrade`).
        case incoming
        /// The installed build — all that's known without `--fetch`.
        case installed
    }

    /// What's known about the build an upgrade would install.
    public enum Evidence: Sendable {
        /// The incoming build was downloaded and analyzed.
        case incoming(NoteworthySummary)
        /// No fetch: only the installed build was analyzed.
        case installedOnly(NoteworthySummary)
        /// Nothing usable (analysis or download failed), with why. Always held:
        /// the gate clears on evidence, never on its absence.
        case unavailable(String)
    }

    public struct Decision: Sendable, Hashable {
        public let cleared: Bool
        /// Why it's held. nil when cleared.
        public let reason: String?
        /// The score and tier that were judged. nil when nothing was analyzable.
        public let score: Int?
        public let tier: RiskTier?
        public let basis: Basis?

        public init(cleared: Bool, reason: String?, score: Int?, tier: RiskTier?, basis: Basis?) {
            self.cleared = cleared
            self.reason = reason
            self.score = score
            self.tier = tier
            self.basis = basis
        }
    }

    /// Clear when the judged build's score is at or below the threshold.
    public static func decide(_ evidence: Evidence, threshold: Threshold) -> Decision {
        let summary: NoteworthySummary
        let basis: Basis
        switch evidence {
        case .incoming(let s):      summary = s; basis = .incoming
        case .installedOnly(let s): summary = s; basis = .installed
        case .unavailable(let why):
            return Decision(cleared: false, reason: why, score: nil, tier: nil, basis: nil)
        }
        if summary.riskScore <= threshold.maxScore {
            return Decision(cleared: true, reason: nil,
                            score: summary.riskScore, tier: summary.tier, basis: basis)
        }
        let which = basis == .incoming ? "incoming build" : "installed build"
        return Decision(
            cleared: false,
            reason: "\(which) is \(summary.tier.label.lowercased()) risk (\(summary.riskScore)/100); " +
                    "the limit is \(threshold.description)",
            score: summary.riskScore, tier: summary.tier, basis: basis)
    }
}
