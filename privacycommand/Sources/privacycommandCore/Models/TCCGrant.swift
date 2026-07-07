import Foundation

/// One row from macOS's TCC (Transparency, Consent & Control) `access` table —
/// i.e. a permission the OS has actually *granted* (or denied) to a specific
/// client. This is the "granted" axis of the permission matrix, distinct from
/// what an app *requests* (Info.plist usage keys / entitlements) and what a
/// monitored run sees it *use* (live probes).
public struct TCCGrant: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(scope.rawValue)|\(service)|\(client)" }

    /// Raw TCC service constant, e.g. `kTCCServiceCamera`. Kept verbatim so a
    /// service we don't have a `PrivacyCategory` for is still surfaced, not dropped.
    public let service: String
    /// Mapped privacy category, when the service corresponds to one. `nil` for
    /// rare / unrecognised services (surfaced raw via `serviceLabel`).
    public let category: PrivacyCategory?
    /// Human-facing label (e.g. "Camera", "Full Disk Access"), from the service
    /// catalog or de-prefixed from the raw constant.
    public let serviceLabel: String
    /// System-access grant (Full Disk Access, Screen Recording, Accessibility,
    /// Input Monitoring) — no Info.plist declaration channel; granted by hand.
    public let isSystemAccess: Bool
    /// The grantee: a bundle identifier (`clientType == .bundleID`) or an
    /// absolute executable path (`clientType == .path`).
    public let client: String
    public let clientType: ClientType
    public let decision: TCCDecision
    /// When the grant was last modified, from the `last_modified` epoch column.
    public let lastModified: Date?
    /// Which database the row came from.
    public let scope: Scope

    public enum Scope: String, Codable, Hashable, Sendable {
        case user     // ~/Library/Application Support/com.apple.TCC/TCC.db
        case system   // /Library/Application Support/com.apple.TCC/TCC.db
    }

    /// TCC's `client_type`: how `client` should be interpreted.
    public enum ClientType: Int, Codable, Hashable, Sendable {
        case bundleID = 0
        case path = 1
    }

    public init(service: String, category: PrivacyCategory?, serviceLabel: String,
                isSystemAccess: Bool, client: String, clientType: ClientType,
                decision: TCCDecision, lastModified: Date?, scope: Scope) {
        self.service = service
        self.category = category
        self.serviceLabel = serviceLabel
        self.isSystemAccess = isSystemAccess
        self.client = client
        self.clientType = clientType
        self.decision = decision
        self.lastModified = lastModified
        self.scope = scope
    }
}

/// The grant decision. Maps modern `auth_value` (0/2/3) and legacy `allowed`
/// (0/1) onto a single vocabulary.
public enum TCCDecision: String, Codable, Hashable, Sendable {
    case allowed
    case denied
    case limited     // auth_value == 3, e.g. limited Photos access
    case unknown     // auth_value == 1 (not determined) or an unreadable column

    public var isAllowed: Bool { self == .allowed || self == .limited }
}

public extension Array where Element == TCCGrant {
    /// Grants belonging to a specific app: bundle-ID grants matched against
    /// `bundleID`, path grants matched against `executablePath`. A grant with a
    /// path client is compared both exactly and by whether it points inside the
    /// app bundle, since TCC sometimes stores the `.app` path and sometimes the
    /// inner executable path.
    func matching(bundleID: String?, executablePath: String?, bundlePath: String? = nil) -> [TCCGrant] {
        filter { grant in
            switch grant.clientType {
            case .bundleID:
                return bundleID != nil && grant.client == bundleID
            case .path:
                if let executablePath, grant.client == executablePath { return true }
                if let bundlePath, grant.client == bundlePath { return true }
                if let bundlePath, grant.client.hasPrefix(bundlePath) { return true }
                return false
            }
        }
    }
}
