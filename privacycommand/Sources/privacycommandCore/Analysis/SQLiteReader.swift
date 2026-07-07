import Foundation
import SQLite3

/// Minimal **read-only** SQLite reader over the system `libsqlite3`.
///
/// privacycommand never writes SQLite; it only *reads* databases produced by
/// macOS or by other tools:
///   * `TCC.db` — the OS's permission-grant store (`TCCAuditor`).
///   * Malimite / mac_apt exports — optional decompiler / forensic enrichers.
///
/// Design constraints:
///   * **Read-only + immutable.** We open with `SQLITE_OPEN_READONLY` and the
///     `immutable=1` URI parameter so we can read a database the OS is actively
///     writing (e.g. a live `TCC.db` with a hot WAL) without taking a lock or
///     perturbing it. `immutable` tells SQLite the file won't change under it,
///     so it skips all locking and WAL recovery.
///   * **Schema-defensive callers.** Apple renames columns across macOS
///     releases, so callers introspect with ``columns(of:)`` (PRAGMA
///     `table_info`) and select only the columns that actually exist rather
///     than relying on positional `SELECT *`.
///
/// Not thread-safe: a reader wraps one `sqlite3*` connection and is meant to be
/// created, used, and dropped within a single scope.
public final class SQLiteReader {

    public enum SQLiteError: Error, LocalizedError, Equatable {
        case cannotOpen(String)
        case prepareFailed(String)
        case stepFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let m):    return "Couldn't open SQLite database: \(m)"
            case .prepareFailed(let m): return "SQLite query failed to prepare: \(m)"
            case .stepFailed(let m):    return "SQLite query failed while reading: \(m)"
            }
        }
    }

    /// A single column value, tagged by SQLite's storage class.
    public enum Value: Equatable, Sendable {
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
        case null

        public var int: Int64? { if case .integer(let v) = self { return v } else { return nil } }
        public var double: Double? { if case .real(let v) = self { return v } else { return nil } }
        public var string: String? { if case .text(let v) = self { return v } else { return nil } }
        public var blob: Data? { if case .blob(let v) = self { return v } else { return nil } }
        public var isNull: Bool { self == .null }
    }

    private var db: OpaquePointer?

    /// Open `path` read-only. Throws `SQLiteError.cannotOpen` if the file is
    /// missing, unreadable (e.g. an FDA-protected `TCC.db` without the
    /// entitlement), or not a database.
    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let rc = sqlite3_open_v2(Self.immutableURI(for: path), &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "open failed (code \(rc))"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.cannotOpen(msg)
        }
        self.db = handle
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// Column names present on `table`, via `PRAGMA table_info`. Empty if the
    /// table doesn't exist. Use this to select only columns that exist on the
    /// running OS's schema.
    public func columns(of table: String) throws -> [String] {
        // Table identifiers can't be bound as parameters; quote defensively.
        let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
        return try query("PRAGMA table_info(\"\(quoted)\")")
            .compactMap { $0["name"]?.string }
    }

    /// Whether `table` exists in the database.
    public func hasTable(_ table: String) -> Bool {
        (try? columns(of: table))?.isEmpty == false
    }

    /// Run a read-only `sql` statement and return every row as a
    /// column-name → ``Value`` dictionary. No parameter binding — callers build
    /// safe SQL from a fixed, schema-checked column allow-list.
    public func query(_ sql: String) throws -> [[String: Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepareFailed(lastMessage())
        }
        defer { sqlite3_finalize(stmt) }

        let columnCount = sqlite3_column_count(stmt)
        var names: [String] = []
        names.reserveCapacity(Int(columnCount))
        for i in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(stmt, i)))
        }

        var rows: [[String: Value]] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                var row: [String: Value] = [:]
                row.reserveCapacity(Int(columnCount))
                for i in 0..<columnCount {
                    row[names[Int(i)]] = Self.value(stmt, i)
                }
                rows.append(row)
            case SQLITE_DONE:
                return rows
            default:
                throw SQLiteError.stepFailed(lastMessage())
            }
        }
    }

    // MARK: - Helpers

    private func lastMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }

    private static func value(_ stmt: OpaquePointer, _ i: Int32) -> Value {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT:
            guard let c = sqlite3_column_text(stmt, i) else { return .null }
            return .text(String(cString: c))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, i) else { return .null }
            let count = Int(sqlite3_column_bytes(stmt, i))
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }

    /// Build a `file:` URI that opens the database read-only and immutable.
    /// The path is percent-encoded so spaces / reserved characters in a home
    /// directory don't corrupt the URI.
    static func immutableURI(for path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .sqliteURIPath) ?? path
        // Absolute paths begin with "/", giving the canonical three-slash form
        // "file:///Users/...". Empty authority is intentional.
        return "file://\(encoded)?immutable=1"
    }
}

private extension CharacterSet {
    /// Characters that may appear unescaped in the path portion of a SQLite
    /// `file:` URI. Keeps '/' as the separator; everything else that isn't
    /// alphanumeric or a safe punctuation mark gets percent-encoded.
    static let sqliteURIPath: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "/-._~")
        return set
    }()
}
