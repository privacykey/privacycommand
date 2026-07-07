import Foundation

/// Reads macOS's TCC databases to answer "what has the OS actually *granted*
/// this app?" — the granted axis of the permission matrix.
///
/// **Privilege.** Both `TCC.db` files are protected by the OS; opening them
/// requires the reading process to hold **Full Disk Access**. privacycommand
/// tries a direct read first (works when the app itself has FDA) and, in the
/// app, falls back to the privileged helper. When neither can read, the UI
/// shows an FDA-remediation card — see `TCCAuditResult.ReadOutcome`.
///
/// **Schema-defensive.** Apple has renamed columns across macOS 13/14/15, so we
/// introspect the `access` table with `PRAGMA table_info` and select only the
/// columns that exist, preferring modern `auth_value` and falling back to
/// legacy `allowed`. See ``mapAccessRows(_:scope:)`` — the pure, unit-tested
/// mapper that turns raw rows into `TCCGrant`s.
public enum TCCAuditor {

    // MARK: - Reading

    public struct TCCAuditResult: Sendable {
        public let grants: [TCCGrant]
        public let readUser: ReadOutcome
        public let readSystem: ReadOutcome

        public enum ReadOutcome: Sendable, Equatable {
            case ok(Int)              // read N rows
            case notPresent           // file doesn't exist
            case unreadable(String)   // exists but couldn't open/parse (usually: needs FDA)
        }

        /// True if at least one database was readable — governs whether the UI
        /// shows real data or the "grant Full Disk Access" card.
        public var anyReadable: Bool {
            if case .ok = readUser { return true }
            if case .ok = readSystem { return true }
            return false
        }

        public init(grants: [TCCGrant], readUser: ReadOutcome, readSystem: ReadOutcome) {
            self.grants = grants
            self.readUser = readUser
            self.readSystem = readSystem
        }
    }

    static let userDBRelativePath = "Library/Application Support/com.apple.TCC/TCC.db"
    static let systemDBPath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// Read both TCC databases directly. Returns per-database outcomes so the
    /// caller can distinguish "no grants" from "couldn't read (needs FDA)".
    public static func audit(fileManager fm: FileManager = .default) -> TCCAuditResult {
        let userPath = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(userDBRelativePath).path
        let (userGrants, userOutcome) = readDatabase(at: userPath, scope: .user, fm: fm)
        let (systemGrants, systemOutcome) = readDatabase(at: systemDBPath, scope: .system, fm: fm)
        return TCCAuditResult(grants: userGrants + systemGrants,
                              readUser: userOutcome,
                              readSystem: systemOutcome)
    }

    /// Columns we read when present. `client`/`service` identify the grant;
    /// `auth_value`/`allowed` carry the decision; the rest are metadata.
    static let wantedColumns = ["service", "client", "client_type",
                                "auth_value", "allowed", "last_modified"]

    static func readDatabase(at path: String, scope: TCCGrant.Scope,
                             fm: FileManager) -> ([TCCGrant], TCCAuditResult.ReadOutcome) {
        guard fm.fileExists(atPath: path) else { return ([], .notPresent) }
        do {
            let reader = try SQLiteReader(path: path)
            let present = Set(try reader.columns(of: "access"))
            guard !present.isEmpty else { return ([], .unreadable("no 'access' table")) }
            let selected = wantedColumns.filter(present.contains)
            // `service` + `client` are load-bearing; without them there's nothing to map.
            guard selected.contains("service"), selected.contains("client") else {
                return ([], .unreadable("access table missing service/client columns"))
            }
            let rows = try reader.query("SELECT \(selected.joined(separator: ", ")) FROM access")
            let grants = mapAccessRows(rows, scope: scope)
            return (grants, .ok(grants.count))
        } catch {
            return ([], .unreadable(error.localizedDescription))
        }
    }

    // MARK: - Pure mapping (unit-tested)

    /// Turn raw `access` rows into `TCCGrant`s. Skips rows missing a service or
    /// client. Decision resolution prefers `auth_value` and falls back to the
    /// legacy `allowed` column, so it's correct across macOS versions.
    public static func mapAccessRows(_ rows: [[String: SQLiteReader.Value]],
                                     scope: TCCGrant.Scope) -> [TCCGrant] {
        rows.compactMap { row in
            guard let service = row["service"]?.string, !service.isEmpty,
                  let client = row["client"]?.string, !client.isEmpty else { return nil }
            let info = serviceCatalog[service]
            let clientType = TCCGrant.ClientType(rawValue: Int(row["client_type"]?.int ?? 0)) ?? .bundleID
            let lastModified = (row["last_modified"]?.int)
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return TCCGrant(
                service: service,
                category: info?.category,
                serviceLabel: info?.label ?? prettifyService(service),
                isSystemAccess: info?.isSystemAccess ?? false,
                client: client,
                clientType: clientType,
                decision: decision(for: row),
                lastModified: lastModified,
                scope: scope)
        }
    }

    /// Resolve the grant decision from whichever decision column exists.
    ///   * `auth_value` (macOS 11+): 0 denied, 1 unknown, 2 allowed, 3 limited.
    ///   * `allowed` (legacy): 0 denied, 1 allowed.
    static func decision(for row: [String: SQLiteReader.Value]) -> TCCDecision {
        if let authValue = row["auth_value"]?.int {
            switch authValue {
            case 0:  return .denied
            case 2:  return .allowed
            case 3:  return .limited
            default: return .unknown   // 1 == not determined
            }
        }
        if let allowed = row["allowed"]?.int {
            return allowed == 1 ? .allowed : .denied
        }
        return .unknown
    }

    /// `kTCCServiceSomething` → `Something` for services not in the catalog, so
    /// an unrecognised grant still reads sensibly instead of showing a constant.
    static func prettifyService(_ service: String) -> String {
        let prefix = "kTCCService"
        return service.hasPrefix(prefix) ? String(service.dropFirst(prefix.count)) : service
    }

    // MARK: - Service catalog

    struct ServiceInfo {
        let category: PrivacyCategory?
        let label: String
        let isSystemAccess: Bool
        init(_ category: PrivacyCategory?, _ label: String, systemAccess: Bool = false) {
            self.category = category
            self.label = label
            self.isSystemAccess = systemAccess
        }
    }

    /// Common TCC services → (category, label). High-signal system-access
    /// services are flagged so the matrix can group them. Anything absent here
    /// is still surfaced with a de-prefixed label and `category == nil`.
    static let serviceCatalog: [String: ServiceInfo] = [
        "kTCCServiceCamera":            ServiceInfo(.camera, "Camera"),
        "kTCCServiceMicrophone":        ServiceInfo(.microphone, "Microphone"),
        "kTCCServiceAddressBook":       ServiceInfo(.contacts, "Contacts"),
        "kTCCServiceCalendar":          ServiceInfo(.calendar, "Calendar"),
        "kTCCServiceReminders":         ServiceInfo(.reminders, "Reminders"),
        "kTCCServicePhotos":            ServiceInfo(.photoLibrary, "Photos"),
        "kTCCServicePhotosAdd":         ServiceInfo(.photoLibraryAdd, "Photos (add only)"),
        "kTCCServiceMediaLibrary":      ServiceInfo(.mediaLibrary, "Media Library"),
        "kTCCServiceAppleEvents":       ServiceInfo(.appleEvents, "Apple Events / Automation"),
        "kTCCServiceLocation":          ServiceInfo(.location, "Location"),
        "kTCCServiceBluetoothAlways":   ServiceInfo(.bluetoothAlways, "Bluetooth"),
        "kTCCServiceMotion":            ServiceInfo(.motion, "Motion & Fitness"),
        "kTCCServiceSpeechRecognition": ServiceInfo(.speechRecognition, "Speech Recognition"),
        "kTCCServiceUserTracking":      ServiceInfo(.userTrackingTransparency, "App Tracking"),
        "kTCCServiceFocusStatus":       ServiceInfo(.focusStatus, "Focus Status"),
        "kTCCServiceWillow":            ServiceInfo(.homeKit, "HomeKit"),
        // Files & Folders
        "kTCCServiceSystemPolicyDesktopFolder":   ServiceInfo(.desktopFolder, "Desktop Folder"),
        "kTCCServiceSystemPolicyDocumentsFolder": ServiceInfo(.documentsFolder, "Documents Folder"),
        "kTCCServiceSystemPolicyDownloadsFolder": ServiceInfo(.downloadsFolder, "Downloads Folder"),
        "kTCCServiceSystemPolicyNetworkVolumes":  ServiceInfo(.networkVolumes, "Network Volumes"),
        "kTCCServiceSystemPolicyRemovableVolumes": ServiceInfo(.removableVolumes, "Removable Volumes"),
        // System access — no declaration channel; granted by hand.
        "kTCCServiceSystemPolicyAllFiles": ServiceInfo(.fullDiskAccess, "Full Disk Access", systemAccess: true),
        "kTCCServiceScreenCapture":        ServiceInfo(.screenCapture, "Screen Recording", systemAccess: true),
        "kTCCServiceAccessibility":        ServiceInfo(.accessibility, "Accessibility", systemAccess: true),
        "kTCCServiceListenEvent":          ServiceInfo(.inputMonitoring, "Input Monitoring", systemAccess: true),
        "kTCCServicePostEvent":            ServiceInfo(nil, "Synthetic Input (post events)", systemAccess: true),
        "kTCCServiceDeveloperTool":        ServiceInfo(nil, "Developer Tools", systemAccess: true),
    ]
}
