import Foundation

/// The three-way cross-check at the heart of "understand the app you're using":
/// for each privacy category, what the app **requested** (Info.plist usage keys
/// / entitlements), what macOS actually **granted** it (TCC), and what a
/// monitored run saw it **use** (live probes).
///
/// This is *machine/run state*, not bundle content, so it is computed at view
/// time and never persisted into the content-keyed `StaticReport`.
public struct PermissionReconciliation: Codable, Hashable, Sendable {
    /// One row per app-declarable privacy category that has any signal.
    public let rows: [Row]
    /// System-access grants (Full Disk Access, Screen Recording, Accessibility,
    /// Input Monitoring, …) the app holds. These have no "requested" channel, so
    /// they're listed separately rather than shoehorned into the matrix.
    public let systemAccessGrants: [TCCGrant]
    /// Whether TCC could be read at all. When false, the "granted" column is
    /// unknown and the UI prompts for Full Disk Access.
    public let tccReadable: Bool
    public let generatedAt: Date

    public init(rows: [Row], systemAccessGrants: [TCCGrant],
                tccReadable: Bool, generatedAt: Date = Date()) {
        self.rows = rows
        self.systemAccessGrants = systemAccessGrants
        self.tccReadable = tccReadable
        self.generatedAt = generatedAt
    }

    public struct Row: Codable, Hashable, Sendable, Identifiable {
        public var id: String { category.rawValue }
        public let category: PrivacyCategory
        /// Declared via an Info.plist usage key or a declaring entitlement.
        public let requested: Bool
        public let requestedEvidence: [String]
        /// The binary references the underlying API (from capability inference).
        public let presentInBinary: Bool
        /// Effective TCC decision, or `nil` when there is no record for this app.
        public let grant: TCCDecision?
        /// The raw grants this row was derived from (for detail: scope, date).
        public let grants: [TCCGrant]
        public let used: Usage
        public let verdict: Verdict

        public init(category: PrivacyCategory, requested: Bool, requestedEvidence: [String],
                    presentInBinary: Bool, grant: TCCDecision?, grants: [TCCGrant],
                    used: Usage, verdict: Verdict) {
            self.category = category
            self.requested = requested
            self.requestedEvidence = requestedEvidence
            self.presentInBinary = presentInBinary
            self.grant = grant
            self.grants = grants
            self.used = used
            self.verdict = verdict
        }
    }

    /// The "used" axis is inherently partial — only camera, microphone, and
    /// screen recording are observable at runtime via live probes.
    public enum Usage: String, Codable, Hashable, Sendable {
        case observed        // a live probe saw this category used
        case notObserved     // observable, but not seen in the monitored run
        case notObservable   // privacycommand can't observe this category at runtime
    }

    public enum Verdict: String, Codable, Hashable, Sendable {
        case grantedAndUsed            // holds the grant and was seen using it
        case granted                   // holds the grant, declared it, not (yet) observed
        case grantedNotRequested       // holds the grant with no usage key / entitlement — surprising
        case requestedDenied           // asked, but the user denied it in TCC
        case requestedNotGranted       // declared, but no grant on record (dormant / never prompted)
        case usedInBinaryNotRequested  // binary references the API with no declaration
        case grantUnknown              // couldn't read TCC (needs Full Disk Access)
        case none

        /// Severity for UI cueing, reusing the shared `Finding.Severity`.
        public var severity: Finding.Severity {
            switch self {
            case .grantedNotRequested, .usedInBinaryNotRequested, .requestedDenied:
                return .warn
            default:
                return .info
            }
        }

        public var headline: String {
            switch self {
            case .grantedAndUsed:           return "Granted & used"
            case .granted:                  return "Granted"
            case .grantedNotRequested:      return "Granted, never requested"
            case .requestedDenied:          return "Requested, denied"
            case .requestedNotGranted:      return "Requested, not granted"
            case .usedInBinaryNotRequested: return "Used in binary, not declared"
            case .grantUnknown:             return "Grant unknown"
            case .none:                     return "—"
            }
        }
    }
}
