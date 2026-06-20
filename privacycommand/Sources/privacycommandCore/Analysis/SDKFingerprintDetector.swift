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

    /// Bundle identifier of privacycommand itself. The SDK fingerprint
    /// *database* is compiled into our own binary, so scanning our own
    /// app trips every `urlPatterns` / `symbolPatterns` string match and
    /// reports trackers we don't actually use (issue #3). We special-case
    /// this one bundle ID to suppress those string-derived false positives.
    public static let analyzerBundleID = "org.privacykey.privacycommand"

    public static func detect(in report: StaticReport,
                              extraSymbols: Set<String> = []) -> [SDKHit] {
        // Self-analysis guard (issue #3). When the bundle under inspection
        // is privacycommand, the only reason its binary contains
        // "app-measurement.com", "FIRApp", etc. is that *we* ship those
        // signatures to detect trackers in other apps — they're detection
        // data, not trackers we embed. So for our own bundle we ignore the
        // string-derived signals (URLs, domains, symbols) and keep only
        // framework- and bundle-ID evidence. Those require an actual linked
        // dependency, so a genuine third-party SDK ever added to
        // privacycommand would still be reported.
        // Apple platform binaries are Apple's own code — they never embed
        // third-party SDKs, so any "match" is noise from system frameworks.
        if report.codeSigning.isPlatformBinary { return [] }

        let isSelfAnalysis = report.bundle.bundleID == analyzerBundleID

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
        // Host set for domain matching: declared domains plus the hosts parsed
        // out of any hard-coded full URLs.
        let hosts = Set(domains + urls.compactMap { URLComponents(string: $0)?.host?.lowercased() })
        // Symbols are case-sensitive — many SDKs use mixed case (e.g. FIRApp).
        let symbols = extraSymbols

        var hits: [SDKHit] = []
        for fp in SDKFingerprintDatabase.all {
            var evidence: [SDKHit.Evidence] = []

            // Frameworks — exact (case-insensitive) match on the framework
            // directory name. A fingerprint's frameworkPatterns ARE the SDK's
            // framework names, so equality is correct; substring matching is
            // what made the generic "Analytics" token hit every
            // *Analytics.framework (e.g. FirebaseAnalytics -> false Segment).
            for pat in fp.frameworkPatterns {
                let needle = pat.lowercased()
                if let match = frameworkNames.first(where: { $0 == needle }) {
                    evidence.append(.framework(match))
                    break  // one per source is plenty
                }
            }

            // Bundle IDs — exact or dotted-prefix, so "com.segment" matches
            // com.segment.analytics but not com.example.segmentation.
            for pat in fp.bundleIDPatterns {
                let needle = pat.lowercased()
                if let match = bundleIDs.first(where: { $0 == needle || $0.hasPrefix(needle + ".") }) {
                    evidence.append(.bundleID(match))
                    break
                }
            }

            // URLs / domains / symbols are string-table signals — exactly the
            // ones that misfire when we scan our own database-bearing binary,
            // so they're skipped for self-analysis (see `isSelfAnalysis`).
            if !isSelfAnalysis {
                // URLs / domains: combine and search once per fingerprint pattern.
                // URLs / domains — host-boundary match (registrable-domain
                // suffix), so "adjust.com" matches app.adjust.com but NOT
                // myadjust.com. Path-bearing patterns fall back to substring.
                for pat in fp.urlPatterns {
                    let needle = pat.lowercased()
                    if needle.contains("/") {
                        if let match = urls.first(where: { $0.contains(needle) }) {
                            evidence.append(.url(match)); break
                        }
                    } else if let match = hosts.first(where: { hostMatches($0, needle) }) {
                        evidence.append(.url(match)); break
                    }
                }

                for pat in fp.symbolPatterns where symbols.contains(where: { $0.contains(pat) }) {
                    evidence.append(.symbol(pat))
                    break
                }
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

    /// True when `host` equals `needle` or is a sub-domain of it (boundary at a
    /// dot), so "adjust.com" matches "app.adjust.com" but not "myadjust.com".
    private static func hostMatches(_ host: String, _ needle: String) -> Bool {
        host == needle || host.hasSuffix("." + needle)
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
