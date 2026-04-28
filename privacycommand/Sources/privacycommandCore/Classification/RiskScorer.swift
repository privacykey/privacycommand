import Foundation

// MARK: - Public types

public struct RiskScore: Hashable, Codable, Sendable {
    public let score: Int                       // 0-100, higher = more concerning
    public let tier: RiskTier
    public let contributors: [RiskContributor]  // sorted by impact desc

    public init(score: Int, tier: RiskTier, contributors: [RiskContributor]) {
        self.score = max(0, min(100, score))
        self.tier = tier
        self.contributors = contributors
    }

    public static let zero = RiskScore(score: 0, tier: .low, contributors: [])
}

public enum RiskTier: String, Hashable, Codable, Sendable {
    case low, medium, high, critical

    public var label: String {
        switch self {
        case .low:       return "Low"
        case .medium:    return "Medium"
        case .high:      return "High"
        case .critical:  return "Critical"
        }
    }

    public static func from(score: Int) -> RiskTier {
        switch score {
        case ..<20:   return .low
        case ..<50:   return .medium
        case ..<80:   return .high
        default:      return .critical
        }
    }
}

public struct RiskContributor: Hashable, Codable, Sendable, Identifiable {
    public enum Source: String, Hashable, Codable, Sendable {
        case staticAnalysis, dynamicAnalysis
    }

    public var id: String { "\(source.rawValue):\(category):\(detail.prefix(80))" }
    public let source: Source
    public let category: String       // stable identifier, e.g. "hardened-runtime"
    public let detail: String         // human-readable description shown in UI
    public let impact: Int            // points contributed to the total

    public init(source: Source, category: String, detail: String, impact: Int) {
        self.source = source
        self.category = category
        self.detail = detail
        self.impact = max(0, impact)
    }
}

// MARK: - Scorer

/// Combines a `StaticReport` and a (possibly empty) list of dynamic events
/// into an explainable risk score.
///
/// Every contribution is paired with a human-readable rationale so the UI can
/// show "this is why the score is high" — never an opaque number.
public struct RiskScorer: Sendable {

    public init() {}

    public func score(staticReport: StaticReport, events: [DynamicEvent] = []) -> RiskScore {
        var contributors: [RiskContributor] = []
        contributors += scoreSigningPosture(staticReport)
        contributors += scoreDeclarations(staticReport)
        contributors += scoreInferredCapabilities(staticReport)
        contributors += scoreEntitlements(staticReport)
        contributors += scoreFileEvents(events)
        contributors += scoreNetworkEvents(events)

        let total = contributors.reduce(0) { $0 + $1.impact }
        let capped = min(100, total)
        let sorted = contributors.sorted { $0.impact > $1.impact }
        return RiskScore(score: capped, tier: .from(score: capped), contributors: sorted)
    }

    // MARK: - Static contributors

    private func scoreSigningPosture(_ report: StaticReport) -> [RiskContributor] {
        var out: [RiskContributor] = []
        let isApple = report.codeSigning.isPlatformBinary

        if !report.codeSigning.validates {
            out.append(.init(source: .staticAnalysis,
                             category: "code-signing",
                             detail: "Code signature does not validate.",
                             impact: 15))
        }
        if !isApple, !report.codeSigning.hardenedRuntime {
            out.append(.init(source: .staticAnalysis,
                             category: "hardened-runtime",
                             detail: "Hardened Runtime is OFF — wider attack surface.",
                             impact: 8))
        }
        if !isApple {
            switch report.notarization {
            case .unsigned:
                out.append(.init(source: .staticAnalysis,
                                 category: "notarization",
                                 detail: "Bundle is not signed at all.",
                                 impact: 12))
            case .rejected(let msg):
                out.append(.init(source: .staticAnalysis,
                                 category: "notarization",
                                 detail: "Gatekeeper rejected the bundle: \(msg.prefix(100))",
                                 impact: 10))
            case .developerIDOnly:
                out.append(.init(source: .staticAnalysis,
                                 category: "notarization",
                                 detail: "Developer ID signed but not notarized.",
                                 impact: 5))
            case .notarized, .unknown:
                break
            }
        }
        return out
    }

    private func scoreDeclarations(_ report: StaticReport) -> [RiskContributor] {
        var out: [RiskContributor] = []
        let emptyKeys = report.declaredPrivacyKeys.filter { $0.isEmpty }
        if !emptyKeys.isEmpty {
            let names = emptyKeys.map(\.rawKey).joined(separator: ", ")
            out.append(.init(source: .staticAnalysis,
                             category: "privacy-key-empty",
                             detail: "Privacy key(s) with empty purpose string: \(names)",
                             impact: min(10, emptyKeys.count * 3)))
        }
        return out
    }

    private func scoreInferredCapabilities(_ report: StaticReport) -> [RiskContributor] {
        var out: [RiskContributor] = []
        let undeclared = report.inferredCapabilities.filter { $0.inferredButNotDeclared }
        if !undeclared.isEmpty {
            let cats = undeclared.map(\.category.rawValue).joined(separator: ", ")
            out.append(.init(source: .staticAnalysis,
                             category: "undeclared-api",
                             detail: "Sensitive API used but not declared: \(cats)",
                             impact: min(15, undeclared.count * 5)))
        }
        let unjustified = report.inferredCapabilities.filter { $0.declaredButNotJustified }
        if !unjustified.isEmpty {
            let cats = unjustified.map(\.category.rawValue).joined(separator: ", ")
            out.append(.init(source: .staticAnalysis,
                             category: "unjustified-permission",
                             detail: "Permission declared but not used in binary: \(cats)",
                             impact: min(8, unjustified.count * 2)))
        }
        return out
    }

    private func scoreEntitlements(_ report: StaticReport) -> [RiskContributor] {
        var out: [RiskContributor] = []
        let isApple = report.codeSigning.isPlatformBinary

        if !isApple, report.entitlements.disablesLibraryValidation {
            out.append(.init(source: .staticAnalysis,
                             category: "library-validation",
                             detail: "Library validation is disabled (third-party code can be loaded).",
                             impact: 5))
        }
        if !isApple, report.entitlements.allowsDyldEnvironmentVariables {
            out.append(.init(source: .staticAnalysis,
                             category: "dyld-env",
                             detail: "DYLD environment variables permitted.",
                             impact: 4))
        }
        if case .anyApp = report.entitlements.appleEvents {
            out.append(.init(source: .staticAnalysis,
                             category: "automation",
                             detail: "Apple Events automation enabled for any application.",
                             impact: 6))
        }
        if report.entitlements.endpointSecurityClient {
            out.append(.init(source: .staticAnalysis,
                             category: "endpoint-security",
                             detail: "App holds the Endpoint Security entitlement (can monitor other processes).",
                             impact: 10))
        }
        return out
    }

    // MARK: - Dynamic contributors

    private func scoreFileEvents(_ events: [DynamicEvent]) -> [RiskContributor] {
        let fileEvents = events.compactMap { e -> FileEvent? in
            if case .file(let f) = e { return f } else { return nil }
        }
        guard !fileEvents.isEmpty else { return [] }

        var out: [RiskContributor] = []
        let surprising = fileEvents.filter { $0.risk == .surprising }
        let sensitive = fileEvents.filter { $0.risk == .sensitive }

        if !surprising.isEmpty {
            let topPaths = Array(Set(surprising.map(\.path))).prefix(5).joined(separator: ", ")
            out.append(.init(source: .dynamicAnalysis,
                             category: "surprising-file-access",
                             detail: "\(surprising.count) surprising file access(es). e.g. \(topPaths)",
                             impact: min(15, surprising.count * 2)))
        }
        if !sensitive.isEmpty {
            out.append(.init(source: .dynamicAnalysis,
                             category: "sensitive-file-access",
                             detail: "\(sensitive.count) sensitive file access(es).",
                             impact: min(10, sensitive.count)))
        }
        return out
    }

    private func scoreNetworkEvents(_ events: [DynamicEvent]) -> [RiskContributor] {
        let netEvents = events.compactMap { e -> NetworkEvent? in
            if case .network(let n) = e { return n } else { return nil }
        }
        guard !netEvents.isEmpty else { return [] }

        var out: [RiskContributor] = []
        let distinctHosts = Set(netEvents.compactMap { $0.remoteHostname ?? $0.remoteEndpoint.address })
        if distinctHosts.count > 10 {
            // Fan-out: lots of distinct hosts is unusual for an app that's
            // not a browser or mail client.
            out.append(.init(source: .dynamicAnalysis,
                             category: "many-hosts",
                             detail: "Contacted \(distinctHosts.count) distinct remote hosts during the run.",
                             impact: min(10, max(0, distinctHosts.count - 10))))
        }
        let surprising = netEvents.filter { $0.risk == .surprising }
        if !surprising.isEmpty {
            out.append(.init(source: .dynamicAnalysis,
                             category: "surprising-network",
                             detail: "\(surprising.count) surprising remote endpoint(s).",
                             impact: min(10, surprising.count * 2)))
        }
        return out
    }
}
