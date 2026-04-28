import Foundation

/// Scans an executable's printable strings for **feature flags,
/// experiment identifiers, trial / licensing state, and debug
/// toggles** — the kinds of switches that turn paid features on or
/// off, gate A/B variants, or unlock developer-only behaviour.
///
/// **Why this is separate from `SecretsScanner` and
/// `SDKFingerprintDetector`.** The other two answer different
/// questions:
///   • *Secrets* ask "what credentials are baked in?".
///   • *SDK fingerprints* ask "is the LaunchDarkly / Optimizely SDK
///     even present?".
///   • *Flags* ask "what specific switches does this binary check at
///     runtime, and what are their names?". An app can ship the
///     LaunchDarkly SDK with zero usage, or ship raw `if isPro {…}`
///     without any third-party SDK at all. The scanner picks up both.
///
/// The scanner is regex-based over the same printable-string stream
/// `BinaryStringScanner` walks. Conservative — we'd rather miss a
/// few unfamiliar patterns than light up every `enable_*` symbol in
/// libstdc++.
public enum FlagsScanner {

    public struct Result: Sendable, Hashable, Codable {
        public var findings: [FlagFinding]
        public init(findings: [FlagFinding] = []) { self.findings = findings }
    }

    /// Convenience: scan a Mach-O on disk.
    public static func scan(executable url: URL,
                            maxBytes: Int = 64 * 1024 * 1024,
                            timeoutSeconds: TimeInterval = 5) -> Result {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return Result() }
        return scan(data: data.prefix(maxBytes), timeoutSeconds: timeoutSeconds)
    }

    /// Scan an arbitrary byte range. Walks null-terminated runs of
    /// ASCII printable bytes (mirroring `strings(1)`) and applies
    /// every rule to every run whose length plausibly matches.
    public static func scan(data: some DataProtocol,
                            timeoutSeconds: TimeInterval = 5) -> Result {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var findings: [FlagFinding] = []
        var seen: Set<String> = []
        var current = [UInt8]()
        current.reserveCapacity(256)

        @inline(__always) func flush() {
            // Most flag identifiers are short. Don't bother scanning
            // strings shorter than 6 chars — every match would be a
            // false positive in libstdc++ symbols.
            if current.count >= 6, let s = String(bytes: current, encoding: .ascii) {
                applyRules(to: s, into: &findings, seen: &seen)
            }
            current.removeAll(keepingCapacity: true)
        }

        for b in data {
            if b >= 0x20 && b < 0x7F {
                current.append(b)
            } else {
                flush()
                if Date() > deadline { break }
            }
        }
        flush()
        return Result(findings: findings)
    }

    // MARK: - Rules

    private static func applyRules(to s: String,
                                   into findings: inout [FlagFinding],
                                   seen: inout Set<String>) {
        for rule in rules {
            guard let m = rule.matcher(s) else { continue }
            let key = "\(rule.kind.rawValue):\(m.lowercased())"
            if seen.insert(key).inserted {
                findings.append(FlagFinding(
                    kind: rule.kind,
                    rawMatch: m,
                    category: rule.kind.category,
                    kbArticleID: rule.kbArticleID))
            }
        }
    }

    private struct Rule {
        let kind: FlagFinding.Kind
        let kbArticleID: String?
        /// Returns the matched substring, or nil if no match.
        let matcher: @Sendable (String) -> String?
    }

    /// Whole-string regex helper.
    private static func first(in s: String, pattern: String) -> String? {
        guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
        return String(s[r])
    }

    // MARK: - Rule table

    private static let rules: [Rule] = [

        // ─── Trial / licensing ─────────────────────────────────────────────

        // Boolean-y trial / pro / premium state. snake_case + camelCase.
        Rule(kind: .trialState, kbArticleID: "flag-trial-state") { s in
            first(in: s, pattern: #"\b(?:is[_]?(?:trial|pro|premium|paid|free|registered|activated|expired)|has[_]?(?:trial|premium|license))\b"#)
        },
        Rule(kind: .trialState, kbArticleID: "flag-trial-state") { s in
            first(in: s, pattern: #"\bIs(?:Trial|Pro|Premium|Paid|Registered|Activated|Expired|InTrial|TrialActive)\b"#)
        },

        // Trial expiry / day counters.
        Rule(kind: .trialExpiry, kbArticleID: "flag-trial-expiry") { s in
            first(in: s, pattern: #"\b(?:trial[_]?(?:days|end|start|expir(?:y|es|ed|ation)|remaining)|days[_]?(?:remaining|left)|trialEnd|trialStart|trialExpir\w*)\b"#)
        },

        // Subscription state.
        Rule(kind: .subscription, kbArticleID: "flag-subscription") { s in
            first(in: s, pattern: #"\bsubscription[_]?(?:status|state|expir\w*|renewal|period|tier|plan)\b"#)
        },

        // License keys / activation codes (the *names*, not the values —
        // SecretsScanner handles values).
        Rule(kind: .licenseKey, kbArticleID: "flag-license-key") { s in
            first(in: s, pattern: #"\b(?:license|activation|registration)[_]?(?:key|code|token|id)\b"#)
        },

        // Pro / Premium / Tier-related flags.
        Rule(kind: .proPremium, kbArticleID: "flag-pro-premium") { s in
            first(in: s, pattern: #"\b(?:pro[_]?(?:feature|mode|user|version|enabled)|premium[_]?(?:feature|mode|user|tier|enabled)|paid[_]?(?:feature|user|tier))\b"#)
        },

        // ─── Feature flag platforms ────────────────────────────────────────

        Rule(kind: .launchDarkly, kbArticleID: "flag-launchdarkly") { s in
            first(in: s, pattern: #"\b(?:LDClient|launchdarkly|LaunchDarkly|ld_user|LDValue|LDFlagKey)\b"#)
        },
        Rule(kind: .optimizely, kbArticleID: "flag-optimizely") { s in
            first(in: s, pattern: #"\b(?:OptimizelyClient|optimizely|OPTIMIZELY|optly)\b"#)
        },
        Rule(kind: .firebaseRemoteConfig, kbArticleID: "flag-firebase-remote-config") { s in
            first(in: s, pattern: #"\b(?:FIRRemoteConfig|firebase[_]?remote[_]?config|getRemoteConfig)\b"#)
        },
        Rule(kind: .posthogFlag, kbArticleID: "flag-posthog") { s in
            first(in: s, pattern: #"\b(?:PHGPostHog|posthog|isFeatureEnabled|getFeatureFlag)\b"#)
        },
        Rule(kind: .statsig, kbArticleID: "flag-statsig") { s in
            first(in: s, pattern: #"\b(?:StatsigClient|statsig|checkGate|getExperiment|getDynamicConfig)\b"#)
        },
        Rule(kind: .unleash, kbArticleID: "flag-unleash") { s in
            first(in: s, pattern: #"\b(?:UnleashClient|isEnabled|unleash[_]?(?:toggle|api|context))\b"#)
        },

        // ─── Generic feature flag patterns ─────────────────────────────────

        Rule(kind: .featureFlag, kbArticleID: "flag-generic") { s in
            first(in: s, pattern: #"\b(?:feature[_]?flag(?:s)?|featureFlag(?:s)?|FeatureFlag(?:s)?|feature[_]?toggle|FeatureToggle|kFeature\w+)\b"#)
        },

        // ─── A/B experiments ───────────────────────────────────────────────

        Rule(kind: .experiment, kbArticleID: "flag-experiment") { s in
            first(in: s, pattern: #"\b(?:experiment[_]?(?:id|name|variant|key|group)|abtest|ab[_]?test|abTest|variant[_]?(?:id|name|group)|treatment[_]?(?:group|name))\b"#)
        },

        // ─── Debug / dev / internal-only ───────────────────────────────────

        Rule(kind: .debugFlag, kbArticleID: "flag-debug") { s in
            first(in: s, pattern: #"\b(?:DEBUG[_]?(?:MODE|ENABLED|BUILD)|isDebug\w*|debug[_]?mode|debug[_]?enabled|kDebug\w+)\b"#)
        },
        Rule(kind: .internalOnly, kbArticleID: "flag-internal-only") { s in
            first(in: s, pattern: #"\b(?:internal[_]?(?:only|build|user|tier|feature)|staff[_]?(?:only|user|mode)|employee[_]?(?:only|build))\b"#)
        }
    ]
}

// MARK: - Public types

public struct FlagFinding: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(kind.rawValue):\(rawMatch)" }
    public let kind: Kind
    /// The exact substring we matched, preserved so the user can grep
    /// for it inside the binary or search the web for context.
    public let rawMatch: String
    public let category: Category
    public let kbArticleID: String?

    public enum Kind: String, Sendable, Hashable, Codable {
        // Trial & licensing
        case trialState              = "Trial / Pro / Premium state"
        case trialExpiry             = "Trial expiry / day counter"
        case subscription            = "Subscription state"
        case licenseKey              = "License / activation key name"
        case proPremium              = "Pro / Premium feature gate"

        // Feature-flag platforms
        case launchDarkly            = "LaunchDarkly"
        case optimizely              = "Optimizely"
        case firebaseRemoteConfig    = "Firebase Remote Config"
        case posthogFlag             = "PostHog feature flag"
        case statsig                 = "Statsig"
        case unleash                 = "Unleash"

        // Generic / custom
        case featureFlag             = "Feature flag (generic)"
        case experiment              = "A/B experiment"

        // Debug / dev
        case debugFlag               = "Debug / development flag"
        case internalOnly            = "Internal-only / staff-only flag"

        public var category: FlagFinding.Category {
            switch self {
            case .trialState, .trialExpiry, .subscription,
                 .licenseKey, .proPremium:
                return .trialAndLicensing
            case .launchDarkly, .optimizely, .firebaseRemoteConfig,
                 .posthogFlag, .statsig, .unleash, .featureFlag:
                return .featureFlags
            case .experiment:
                return .experiments
            case .debugFlag, .internalOnly:
                return .debugging
            }
        }

        public var icon: String {
            switch self {
            case .trialState, .trialExpiry, .subscription,
                 .licenseKey, .proPremium:
                return "ticket"
            case .launchDarkly, .optimizely, .firebaseRemoteConfig,
                 .posthogFlag, .statsig, .unleash, .featureFlag:
                return "switch.2"
            case .experiment:
                return "flask"
            case .debugFlag, .internalOnly:
                return "ant"
            }
        }
    }

    public enum Category: String, Sendable, Hashable, Codable, CaseIterable {
        case trialAndLicensing = "Trial & licensing"
        case featureFlags      = "Feature flags"
        case experiments       = "A/B experiments"
        case debugging         = "Debug & development"
    }
}
