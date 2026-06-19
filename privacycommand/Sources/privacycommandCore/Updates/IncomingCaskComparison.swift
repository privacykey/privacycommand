import Foundation

/// Compares the privacy posture of the **installed** app against the
/// **incoming** (about-to-be-installed) build, surfacing what the upgrade would
/// change. Pure — no brew, network, or mounting. It wraps each `StaticReport`
/// in a static-only `RunReport` (mirroring the GUI's
/// `UpdateComparisonSheet.wrap`) so it can reuse the existing `ReportDiffer`.
public enum IncomingCaskComparison {

    public struct IncomingDiff: Sendable {
        /// Noteworthy summary of the incoming build on its own.
        public let incomingSummary: NoteworthySummary
        /// What changed from installed → incoming. In this orientation an
        /// "added" entry is something the upgrade *introduces*.
        public let diff: ReportDiff

        public init(incomingSummary: NoteworthySummary, diff: ReportDiff) {
            self.incomingSummary = incomingSummary
            self.diff = diff
        }

        /// The incoming build's version (its `CFBundleShortVersionString`), as
        /// `ReportDiffer` already recorded it on the right-hand side.
        public var incomingVersion: String? { diff.right.version }
        public var riskScoreDelta: Int { diff.riskScoreDelta }
        public var installedRiskScore: Int { diff.left.riskScore.score }
        public var incomingRiskScore: Int { diff.right.riskScore.score }
    }

    /// Diff installed → incoming. `added` entries are what the upgrade brings in.
    public static func compare(installed: StaticReport, incoming: StaticReport) -> IncomingDiff {
        let left = wrap(installed, label: "installed")
        let right = wrap(incoming, label: "incoming")
        return IncomingDiff(
            incomingSummary: NoteworthySummary.summarize(incoming),
            diff: ReportDiffer().diff(left: left, right: right))
    }

    /// Static-only `RunReport` wrapper. Kept consistent with the GUI's
    /// `UpdateComparisonSheet.wrap` (`auditorVersion "0.1.0"`, zeroed event
    /// counts, risk score from `RiskScorer`).
    static func wrap(_ report: StaticReport, label: String) -> RunReport {
        RunReport(
            auditorVersion: "0.1.0",
            startedAt: Date(),
            endedAt: Date(),
            bundle: report.bundle,
            staticReport: report,
            events: [],
            summary: RunSummary(
                processCount: 0, fileEventCount: 0, networkEventCount: 0,
                topRemoteHosts: [], topPathCategories: [],
                surprisingEventCount: 0,
                riskScore: RiskScorer().score(staticReport: report)),
            fidelityNotes: ["Static-only — \(label)"])
    }
}
