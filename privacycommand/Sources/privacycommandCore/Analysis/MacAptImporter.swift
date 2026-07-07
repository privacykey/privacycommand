import Foundation

/// Ingests a **mac_apt** (ydkhatri/mac_apt) SQLite export into our `TCCGrant`
/// model, so a forensic capture — e.g. TCC pulled from a *disk image* rather
/// than the live machine — can corroborate the native `TCCAuditor` read.
///
/// Like the Malimite path, this is an *importer*, not a driver: the user runs
/// mac_apt (`python mac_apt.py … TCC …`), then imports the resulting SQLite.
/// mac_apt's TCC plugin writes a `TCC` table (`plugins/tcc.py`):
///
///     TCC(Last_Modified, Service, Client, Client_Type, Allowed, …)
///
/// `Allowed` is mac_apt's normalised decision (it collapses the raw
/// `auth_value`, so `limited` isn't distinguished here). We reuse
/// `TCCAuditor`'s service catalog for the category/label mapping.
public enum MacAptImporter {

    public enum ImportError: LocalizedError, Equatable {
        case unreadable(String)
        case noTCCTable

        public var errorDescription: String? {
            switch self {
            case .unreadable(let m):
                return "Couldn't open the mac_apt export: \(m)"
            case .noTCCTable:
                return "That database has no `TCC` table — run mac_apt with the TCC plugin to produce one."
            }
        }
    }

    /// Import TCC grants from a mac_apt SQLite export at `url`.
    public static func importTCC(from url: URL) throws -> [TCCGrant] {
        let reader: SQLiteReader
        do {
            reader = try SQLiteReader(path: url.path)
        } catch {
            throw ImportError.unreadable((error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription)
        }
        return try parseTCC(reader: reader)
    }

    /// Pure mapping over a reader — unit-tested against a fixture database.
    static func parseTCC(reader: SQLiteReader) throws -> [TCCGrant] {
        let columns = Set((try? reader.columns(of: "TCC")) ?? [])
        guard columns.contains("Service"), columns.contains("Client") else {
            throw ImportError.noTCCTable
        }
        let wanted = ["Service", "Client", "Client_Type", "Allowed", "Last_Modified"]
            .filter(columns.contains)
        let rows = try reader.query("SELECT \(wanted.joined(separator: ", ")) FROM TCC")
        return rows.compactMap(mapRow)
    }

    static func mapRow(_ row: [String: SQLiteReader.Value]) -> TCCGrant? {
        guard let service = row["Service"]?.string, !service.isEmpty,
              let client = row["Client"]?.string, !client.isEmpty else { return nil }
        let info = TCCAuditor.serviceCatalog[service]
        return TCCGrant(
            service: service,
            category: info?.category,
            serviceLabel: info?.label ?? TCCAuditor.prettifyService(service),
            isSystemAccess: info?.isSystemAccess ?? false,
            client: client,
            clientType: clientType(row["Client_Type"]),
            decision: decision(row["Allowed"]),
            lastModified: lastModified(row["Last_Modified"]),
            scope: .system)
    }

    // MARK: - Field decoding (mac_apt-specific representations)

    static func clientType(_ value: SQLiteReader.Value?) -> TCCGrant.ClientType {
        switch value {
        case .integer(let n): return TCCGrant.ClientType(rawValue: Int(n)) ?? .bundleID
        case .text(let s):    return Int(s).flatMap { TCCGrant.ClientType(rawValue: $0) } ?? .bundleID
        default:              return .bundleID
        }
    }

    /// mac_apt's `Allowed` may be a normalised int (0 denied / 1|2 allowed) or a
    /// boolean-ish string, depending on version. `limited` (3) isn't preserved.
    static func decision(_ value: SQLiteReader.Value?) -> TCCDecision {
        switch value {
        case .integer(let n):
            return n == 0 ? .denied : .allowed
        case .text(let s):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1", "2", "allowed": return .allowed
            case "false", "0", "denied":      return .denied
            default:                          return .unknown
            }
        default:
            return .unknown
        }
    }

    /// mac_apt writes `Last_Modified` as a datetime string (or occasionally a
    /// Unix epoch int). Best-effort parse; `nil` when it can't be read.
    static func lastModified(_ value: SQLiteReader.Value?) -> Date? {
        switch value {
        case .integer(let n):
            return Date(timeIntervalSince1970: TimeInterval(n))
        case .text(let s):
            return macAptDateFormatter.date(from: s.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    private static let macAptDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
