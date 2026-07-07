import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// **Opt-in integration test** for the real TCC read that backs the permission
/// matrix's "granted" column. Skipped unless `PC_TCC_INTEGRATION=1`.
///
/// Reading the TCC databases requires the *running process* to hold **Full Disk
/// Access**, so to run it:
///
///   1. Grant Full Disk Access to the terminal / app that will run the test
///      (System Settings › Privacy & Security › Full Disk Access).
///   2. `PC_TCC_INTEGRATION=1 swift test --filter TCCAuditorIntegrationTests`
///
/// It reads your real `TCC.db`, prints a summary so you can eyeball the parse,
/// and asserts the mapping produced sane grants — verifying `TCCAuditor`
/// against the actual on-disk schema (which the unit tests only approximate
/// with fixtures). Without Full Disk Access it fails with a clear message
/// telling you to grant it.
final class TCCAuditorIntegrationTests: XCTestCase {

    func testReadsRealTCCDatabases() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PC_TCC_INTEGRATION"] == "1",
            "set PC_TCC_INTEGRATION=1 (and grant the running process Full Disk Access) to verify the real TCC read")

        let result = TCCAuditor.audit()

        // Surface what we found so a human can sanity-check the parse.
        print("── TCC audit ──────────────────────────────────────────")
        print("user DB:   \(result.readUser)")
        print("system DB: \(result.readSystem)")
        print("grants:    \(result.grants.count)")
        for grant in result.grants.prefix(15) {
            let category = grant.category.map(\.rawValue) ?? "uncategorised"
            print("  [\(grant.scope.rawValue)] \(grant.serviceLabel) = \(grant.decision.rawValue) (\(category)) — \(grant.client)")
        }
        print("───────────────────────────────────────────────────────")

        XCTAssertTrue(
            result.anyReadable,
            "No TCC database was readable — grant Full Disk Access to the process running this test, then re-run. (Outcomes: user=\(result.readUser), system=\(result.readSystem))")
        XCTAssertFalse(
            result.grants.isEmpty,
            "A real machine should have at least one TCC grant on record.")
        XCTAssertTrue(
            result.grants.allSatisfy { !$0.service.isEmpty && !$0.client.isEmpty },
            "every parsed grant must carry a service + client")
        // Some grants should map to a known PrivacyCategory (camera, mic, Full
        // Disk Access, Apple Events, …). A total miss would flag service-catalog
        // drift against a newer macOS.
        XCTAssertTrue(
            result.grants.contains { $0.category != nil },
            "expected at least one grant to map to a known PrivacyCategory — check TCCAuditor.serviceCatalog against this macOS version")
    }
}
