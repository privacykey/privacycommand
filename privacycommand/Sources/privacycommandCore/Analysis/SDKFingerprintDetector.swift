import Foundation

/// Matches a `StaticReport`'s observed artefacts against the
/// `SDKFingerprintDatabase` and returns one `SDKHit` per detected SDK.
///
/// Each fingerprint is checked against four signal sources:
///   * Linked frameworks (`StaticReport.frameworks`)
///   * Bundle IDs of frameworks / XPC services / login items / helpers
///   * Hard-coded URLs and domains lifted from the binary's strings
///   * Privacy / framework symbols already extracted by the binary scanner
///
/// Any of the four constitutes a hit, with the matching strings recorded as
/// evidence so the UI can show *why* we flagged it.
public enum SDKFingerprintDetector {

    public static func detect(in report: StaticReport,
                              extraSymbols: Set<String> = []) -> [SDKHit] {
        // Pre-compute lowercased haystacks once for every fingerprint to test.
        let frameworkNames: [String] = report.frameworks
            .map { $0.url.deletingPathExtension().lastPathComponent.lowercased() }
        let bundleIDs: [String] = (
            report.frameworks.compactMap(\.bundleID)
            + report.xpcServices.compactMap(\.bundleID)
            + report.loginItems.compactMap(\.bundleID)
            + report.helpers.compactMap(\.bundleID)
        ).map { $0.lowercased() }
        let urls = report.hardcodedURLs.map { $0.lowercased() }
        let domains = report.hardcodedDomains.map { $0.lowercased() }
        // Symbols are case-sensitive — many SDKs use mixed case (e.g. FIRApp).
        let symbols = extraSymbols

        var hits: [SDKHit] = []
        for fp in SDKFingerprintDatabase.all {
            var evidence: [SDKHit.Evidence] = []

            // Frameworks (case-insensitive substring of "FirebaseAnalytics" etc.)
            for pat in fp.frameworkPatterns {
                let needle = pat.lowercased()
                if let match = frameworkNames.first(where: { $0.contains(needle) }) {
                    evidence.append(.framework(match))
                    break  // one per source is plenty
                }
            }

            for pat in fp.bundleIDPatterns {
                let needle = pat.lowercased()
                if let match = bundleIDs.first(where: { $0.contains(needle) }) {
                    evidence.append(.bundleID(match))
                    break
                }
            }

            // URLs / domains: combine and search once per fingerprint pattern.
            for pat in fp.urlPatterns {
                let needle = pat.lowercased()
                if let match = urls.first(where: { $0.contains(needle) }) {
                    evidence.append(.url(match))
                    break
                }
                if let match = domains.first(where: { $0.contains(needle) }) {
                    evidence.append(.url(match))
                    break
                }
            }

            for pat in fp.symbolPatterns where symbols.contains(where: { $0.contains(pat) }) {
                evidence.append(.symbol(pat))
                break
            }

            if !evidence.isEmpty {
                hits.append(SDKHit(fingerprint: fp, evidence: evidence))
            }
        }

        // Sort: tracker-heavy categories first so the user sees them at a
        // glance, then by display name within each category.
        let categoryOrder: [SDKCategory: Int] = [
            .advertising: 0, .attribution: 1, .analytics: 2,
            .pushNotifications: 3, .feedback: 4, .abTesting: 5,
            .crashReporting: 6, .performance: 7, .customerSupport: 8,
            .authentication: 9, .monetization: 10, .logging: 11
        ]
        return hits.sorted { lhs, rhs in
            let l = categoryOrder[lhs.fingerprint.category] ?? 99
            let r = categoryOrder[rhs.fingerprint.category] ?? 99
            if l != r { return l < r }
            return lhs.fingerprint.displayName.localizedCaseInsensitiveCompare(rhs.fingerprint.displayName) == .orderedAscending
        }
    }
}

// MARK: - Public types

public struct SDKHit: Sendable, Hashable, Codable, Identifiable {
    public var id: String { fingerprint.id }
    public let fingerprint: SDKFingerprint
    public let evidence: [Evidence]

    public init(fingerprint: SDKFingerprint, evidence: [Evidence]) {
        self.fingerprint = fingerprint
        self.evidence = evidence
    }

    public enum Evidence: Sendable, Hashable, Codable {
        case framework(String)
        case bundleID(String)
        case symbol(String)
        case url(String)

        public var label: String {
            switch self {
            case .framework(let s): return "Framework: \(s)"
            case .bundleID(let s):  return "Bundle ID: \(s)"
            case .symbol(let s):    return "Symbol: \(s)"
            case .url(let s):       return "URL / domain: \(s)"
            }
        }
    }

    /// Whether any of this hit's evidence is a tracker-class signal — useful
    /// for the "tracker count" callout in the UI.
    public var isTrackerLike: Bool {
        switch fingerprint.category {
        case .advertising, .attribution, .analytics, .feedback,
             .pushNotifications, .abTesting:
            return true
        default:
            return false
        }
    }
}
