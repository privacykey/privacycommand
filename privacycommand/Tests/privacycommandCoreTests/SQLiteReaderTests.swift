import XCTest
import SQLite3
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Unit tests for the read-only `SQLiteReader`. We build a throwaway database
/// with the raw sqlite3 C API (the reader itself can only read), then assert
/// the reader surfaces rows, storage types, NULLs, and schema introspection.
final class SQLiteReaderTests: XCTestCase {

    /// Create a temp SQLite file and run `setupSQL` against it.
    private func makeTempDB(_ setupSQL: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-sqlitereader-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK, "fixture open failed")
        defer { sqlite3_close(db) }
        var errPtr: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, setupSQL, nil, nil, &errPtr) != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errPtr)
            XCTFail("fixture setup failed: \(msg)")
        }
        return url
    }

    func testReadsRowsTypesAndNulls() throws {
        let url = try makeTempDB("""
        CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER, ts REAL, raw BLOB);
        INSERT INTO access VALUES ('kTCCServiceCamera', 'com.example.app', 2, 1.5, x'00ff');
        INSERT INTO access VALUES ('kTCCServiceMicrophone', 'com.example.app', 0, NULL, NULL);
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try SQLiteReader(path: url.path)
        let rows = try reader.query(
            "SELECT service, client, auth_value, ts, raw FROM access ORDER BY service")

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["service"]?.string, "kTCCServiceCamera")
        XCTAssertEqual(rows[0]["auth_value"]?.int, 2)
        XCTAssertEqual(rows[0]["ts"]?.double, 1.5)
        XCTAssertEqual(rows[0]["raw"]?.blob, Data([0x00, 0xff]))

        XCTAssertEqual(rows[1]["service"]?.string, "kTCCServiceMicrophone")
        XCTAssertEqual(rows[1]["auth_value"]?.int, 0)
        XCTAssertEqual(rows[1]["ts"], .null, "SQL NULL must map to .null")
        XCTAssertEqual(rows[1]["raw"], .null)
    }

    func testColumnsAndHasTable() throws {
        let url = try makeTempDB("CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER);")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try SQLiteReader(path: url.path)

        XCTAssertEqual(try reader.columns(of: "access").sorted(),
                       ["auth_value", "client", "service"])
        XCTAssertTrue(reader.hasTable("access"))
        XCTAssertFalse(reader.hasTable("nonexistent"))
        XCTAssertEqual(try reader.columns(of: "nonexistent"), [])
    }

    func testOpenMissingFileThrows() {
        XCTAssertThrowsError(
            try SQLiteReader(path: "/nonexistent/pc-\(UUID().uuidString).db"))
    }

    func testImmutableURIEncodesReservedCharacters() {
        XCTAssertEqual(
            SQLiteReader.immutableURI(for: "/Users/a b/TCC.db"),
            "file:///Users/a%20b/TCC.db?immutable=1")
        // Plain paths pass through with only the scheme + query added.
        XCTAssertEqual(
            SQLiteReader.immutableURI(for: "/Library/Application Support/com.apple.TCC/TCC.db"),
            "file:///Library/Application%20Support/com.apple.TCC/TCC.db?immutable=1")
    }
}
