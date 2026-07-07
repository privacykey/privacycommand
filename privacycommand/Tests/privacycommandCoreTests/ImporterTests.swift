import XCTest
import SQLite3
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Tests for the Phase-4 enrichers: importing a Malimite decompilation database
/// and a mac_apt TCC export. We build throwaway databases shaped like the real
/// tools' output and assert the mapping.
final class ImporterTests: XCTestCase {

    private func makeTempDB(_ setupSQL: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-importtest-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK)
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, setupSQL, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            XCTFail("fixture setup failed: \(msg)")
        }
        return url
    }

    // MARK: - Malimite

    func testMalimiteImportGroupsByParentClass() throws {
        let url = try makeTempDB("""
        CREATE TABLE Functions (FunctionName TEXT, ParentClass TEXT, DecompilationCode TEXT, ExecutableName TEXT);
        INSERT INTO Functions VALUES ('login',  'LoginVC', 'void login(void){}',  'App');
        INSERT INTO Functions VALUES ('logout', 'LoginVC', 'void logout(void){}', 'App');
        INSERT INTO Functions VALUES ('main',   '',        'int main(void){}',    'App');
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let index = try MalimiteImporter.importDatabase(at: url)
        XCTAssertEqual(index.source, .malimite)
        XCTAssertEqual(index.functionCount, 3)
        XCTAssertFalse(index.truncated)

        let loginVC = index.classes.first { $0.name == "LoginVC" }
        XCTAssertEqual(loginVC?.functions.count, 2)
        XCTAssertEqual(loginVC?.functions.first?.cCode, "void login(void){}")
        XCTAssertEqual(index.classes.first { $0.name == "(global)" }?.functions.count, 1,
                       "empty ParentClass collects under (global)")
    }

    func testMalimiteImportRejectsNonMalimiteDatabase() throws {
        let url = try makeTempDB("CREATE TABLE Whatever (a INTEGER);")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try MalimiteImporter.importDatabase(at: url)) { error in
            XCTAssertEqual(error as? MalimiteImporter.ImportError, .notAMalimiteDatabase)
        }
    }

    // MARK: - mac_apt

    func testMacAptTCCImport() throws {
        let url = try makeTempDB("""
        CREATE TABLE TCC (Last_Modified TEXT, Service TEXT, Client TEXT, Client_Type INTEGER, Allowed INTEGER);
        INSERT INTO TCC VALUES ('2023-01-01 12:00:00', 'kTCCServiceCamera', 'com.example.app', 0, 2);
        INSERT INTO TCC VALUES ('2023-01-02 09:30:00', 'kTCCServiceSystemPolicyAllFiles', '/Applications/Foo.app', 1, 0);
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let grants = try MacAptImporter.importTCC(from: url)
        XCTAssertEqual(grants.count, 2)

        let camera = grants.first { $0.service == "kTCCServiceCamera" }
        XCTAssertEqual(camera?.category, .camera)
        XCTAssertEqual(camera?.decision, .allowed)
        XCTAssertEqual(camera?.clientType, .bundleID)
        XCTAssertNotNil(camera?.lastModified)

        let fda = grants.first { $0.service == "kTCCServiceSystemPolicyAllFiles" }
        XCTAssertEqual(fda?.category, .fullDiskAccess)
        XCTAssertTrue(fda?.isSystemAccess ?? false)
        XCTAssertEqual(fda?.decision, .denied)
        XCTAssertEqual(fda?.clientType, .path)
    }

    func testMacAptImportRejectsNonMacAptDatabase() throws {
        let url = try makeTempDB("CREATE TABLE Nope (a INTEGER);")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try MacAptImporter.importTCC(from: url)) { error in
            XCTAssertEqual(error as? MacAptImporter.ImportError, .noTCCTable)
        }
    }

    // MARK: - mac_apt field decoding (version-dependent representations)

    func testMacAptDecisionDecoding() {
        XCTAssertEqual(MacAptImporter.decision(.integer(2)), .allowed)   // macOS 11+
        XCTAssertEqual(MacAptImporter.decision(.integer(1)), .allowed)   // macOS 10.15
        XCTAssertEqual(MacAptImporter.decision(.integer(0)), .denied)
        XCTAssertEqual(MacAptImporter.decision(.text("True")), .allowed) // boolean-ish string
        XCTAssertEqual(MacAptImporter.decision(.text("false")), .denied)
        XCTAssertEqual(MacAptImporter.decision(.null), .unknown)
    }

    func testMacAptClientTypeDecoding() {
        XCTAssertEqual(MacAptImporter.clientType(.integer(0)), .bundleID)
        XCTAssertEqual(MacAptImporter.clientType(.integer(1)), .path)
        XCTAssertEqual(MacAptImporter.clientType(.text("1")), .path)
        XCTAssertEqual(MacAptImporter.clientType(.null), .bundleID)
    }

    func testMacAptLastModifiedDecoding() {
        XCTAssertEqual(MacAptImporter.lastModified(.integer(1_700_000_000)),
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNotNil(MacAptImporter.lastModified(.text("2023-01-01 12:00:00")))
        XCTAssertNil(MacAptImporter.lastModified(.text("not a date")))
        XCTAssertNil(MacAptImporter.lastModified(.null))
    }
}
