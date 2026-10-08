import Foundation
import privacycommandCore

/// The distilled result the TUI holds for one analyzed app. Decoupled from the
/// full `StaticReport` so the renderer stays simple and tests can build one by
/// hand. Built once (off the main thread) from a report + its summary.
public struct AuditSnapshot: Sendable, Equatable {

    public struct Components: Sendable, Equatable {
        public let frameworks: Int
        public let xpc: Int
        public let helpers: Int
        public let loginItems: Int
        public init(frameworks: Int, xpc: Int, helpers: Int, loginItems: Int) {
            self.frameworks = frameworks; self.xpc = xpc
            self.helpers = helpers; self.loginItems = loginItems
        }
    }

    public struct FindingLine: Sendable, Equatable {
        public let severity: Finding.Severity
        public let message: String
        public init(severity: Finding.Severity, message: String) {
            self.severity = severity; self.message = message
        }
    }

    public let name: String
    public let bundleID: String?
    public let version: String?
    public let architectures: [String]
    public let signing: String
    public let sandboxed: Bool
    public let tier: RiskTier
    public let riskScore: Int
    public let isNoteworthy: Bool
    public let headline: String
    public let capabilities: [String]
    public let privacyKeys: [String]
    public let components: Components
    public let signals: [String]
    public let findings: [FindingLine]

    public init(name: String, bundleID: String?, version: String?, architectures: [String],
                signing: String, sandboxed: Bool, tier: RiskTier, riskScore: Int,
                isNoteworthy: Bool, headline: String, capabilities: [String],
                privacyKeys: [String], components: Components, signals: [String],
                findings: [FindingLine]) {
        self.name = name; self.bundleID = bundleID; self.version = version
        self.architectures = architectures; self.signing = signing; self.sandboxed = sandboxed
        self.tier = tier; self.riskScore = riskScore; self.isNoteworthy = isNoteworthy
        self.headline = headline; self.capabilities = capabilities; self.privacyKeys = privacyKeys
        self.components = components; self.signals = signals; self.findings = findings
    }

    /// The single mapping from a full analysis to what the TUI shows.
    public init(report: StaticReport, summary: NoteworthySummary, fallbackName: String) {
        self.init(
            name: report.bundle.bundleName ?? fallbackName,
            bundleID: report.bundle.bundleID,
            version: report.bundle.bundleVersion,
            architectures: report.bundle.architectures,
            signing: Self.signingLine(report),
            sandboxed: report.entitlements.isSandboxed,
            tier: summary.tier,
            riskScore: summary.riskScore,
            isNoteworthy: summary.isNoteworthy,
            headline: summary.headline,
            capabilities: report.inferredCapabilities.map {
                $0.category.rawValue + ($0.inferredButNotDeclared ? "*" : "")
            },
            privacyKeys: report.declaredPrivacyKeys.map(\.rawKey),
            components: Components(frameworks: report.frameworks.count,
                                   xpc: report.xpcServices.count,
                                   helpers: report.helpers.count,
                                   loginItems: report.loginItems.count),
            signals: summary.signals,
            findings: summary.findings.map { FindingLine(severity: $0.severity, message: $0.message) })
    }

    /// Plain-text (no ANSI) signing posture, mirroring `AuditCommand.signingLine`.
    static func signingLine(_ r: StaticReport) -> String {
        var parts: [String] = []
        if let team = r.codeSigning.teamIdentifier {
            parts.append(r.codeSigning.teamName.map { "\($0) (\(team))" } ?? "Team \(team)")
        } else if r.codeSigning.isPlatformBinary {
            parts.append("Apple platform binary")
        } else if r.codeSigning.isAdhocSigned {
            parts.append("ad-hoc signed")
        } else {
            parts.append("unsigned")
        }
        switch r.notarization {
        case .notarized:       parts.append("notarized")
        case .developerIDOnly: parts.append("not notarized")
        case .unsigned:        parts.append("unsigned")
        case .rejected:        parts.append("Gatekeeper-rejected")
        case .unknown:         parts.append("notarization unknown")
        }
        parts.append(r.codeSigning.hardenedRuntime ? "hardened runtime" : "no hardened runtime")
        return parts.joined(separator: " · ")
    }
}
