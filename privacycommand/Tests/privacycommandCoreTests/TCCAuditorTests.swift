import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Unit tests for `TCCAuditor`'s pure row mapper. We feed synthetic `access`
/// rows shaped like the real TCC schemas across macOS 13/14/15 (legacy
/// `allowed` vs modern `auth_value`, both `client_type`s) and assert the
/// mapping — never touching a live database.
final class TCCAuditorTests: XCTestCase {

    private func row(service: String?, client: String?, clientType: Int? = 0,
                     authValue: Int? = nil, allowed: Int? = nil,
                     lastModified: Int? = nil) -> [String: SQLiteReader.Value] {
        var r: [String: SQLiteReader.Value] = [:]
        if let service { r["service"] = .text(service) }
        if let client { r["client"] = .text(client) }
        if let clientType { r["client_type"] = .integer(Int64(clientType)) }
        if let authValue { r["auth_value"] = .integer(Int64(authValue)) }
        if let allowed { r["allowed"] = .integer(Int64(allowed)) }
        if let lastModified { r["last_modified"] = .integer(Int64(lastModified)) }
        return r
    }

    // MARK: - Modern schema (auth_value)

    func testAuthValueDecisions() {
        let grants = TCCAuditor.mapAccessRows([
            row(service: "kTCCServiceCamera", client: "com.example.app", authValue: 2),
            row(service: "kTCCServiceMicrophone", client: "com.example.app", authValue: 0),
            row(service: "kTCCServicePhotos", client: "com.example.app", authValue: 3),
            row(service: "kTCCServiceReminders", client: "com.example.app", authValue: 1),
        ], scope: .user)

        let byCategory = Dictionary(uniqueKeysWithValues: grants.map { ($0.category, $0.decision) })
        XCTAssertEqual(byCategory[.camera], .allowed)
        XCTAssertEqual(byCategory[.microphone], .denied)
        XCTAssertEqual(byCategory[.photoLibrary], .limited)
        XCTAssertEqual(byCategory[.reminders], .unknown, "auth_value 1 == not determined")
    }

    // MARK: - Legacy schema (allowed)

    func testLegacyAllowedColumn() {
        let grants = TCCAuditor.mapAccessRows([
            row(service: "kTCCServiceCamera", client: "com.example.app", allowed: 1),
            row(service: "kTCCServiceMicrophone", client: "com.example.app", allowed: 0),
        ], scope: .user)
        XCTAssertEqual(grants.first { $0.category == .camera }?.decision, .allowed)
        XCTAssertEqual(grants.first { $0.category == .microphone }?.decision, .denied)
    }

    func testAuthValuePreferredOverAllowedWhenBothPresent() {
        // A row carrying both columns (transitional schema) must trust auth_value.
        var r = row(service: "kTCCServiceCamera", client: "com.example.app", authValue: 2)
        r["allowed"] = .integer(0)
        let grants = TCCAuditor.mapAccessRows([r], scope: .user)
        XCTAssertEqual(grants.first?.decision, .allowed)
    }

    // MARK: - Client type

    func testClientTypeBundleIDvsPath() {
        let grants = TCCAuditor.mapAccessRows([
            row(service: "kTCCServiceCamera", client: "com.example.app", clientType: 0, authValue: 2),
            row(service: "kTCCServiceAccessibility", client: "/Applications/Foo.app", clientType: 1, authValue: 2),
        ], scope: .system)
        XCTAssertEqual(grants[0].clientType, .bundleID)
        XCTAssertEqual(grants[1].clientType, .path)
    }

    // MARK: - Category mapping & system access

    func testSystemAccessServicesFlaggedAndCategorised() {
        let grants = TCCAuditor.mapAccessRows([
            row(service: "kTCCServiceSystemPolicyAllFiles", client: "com.example.app", authValue: 2),
            row(service: "kTCCServiceScreenCapture", client: "com.example.app", authValue: 2),
            row(service: "kTCCServiceAccessibility", client: "com.example.app", authValue: 2),
            row(service: "kTCCServiceListenEvent", client: "com.example.app", authValue: 2),
        ], scope: .system)
        XCTAssertTrue(grants.allSatisfy(\.isSystemAccess))
        XCTAssertEqual(grants.first { $0.service == "kTCCServiceSystemPolicyAllFiles" }?.category, .fullDiskAccess)
        XCTAssertEqual(grants.first { $0.service == "kTCCServiceScreenCapture" }?.category, .screenCapture)
        XCTAssertEqual(grants.first { $0.service == "kTCCServiceAccessibility" }?.category, .accessibility)
        XCTAssertEqual(grants.first { $0.service == "kTCCServiceListenEvent" }?.category, .inputMonitoring)
    }

    func testUnknownServiceSurfacedRawNotDropped() {
        let grants = TCCAuditor.mapAccessRows([
            row(service: "kTCCServiceLiverpool", client: "com.example.app", authValue: 2),
        ], scope: .user)
        XCTAssertEqual(grants.count, 1, "an unrecognised service must still be surfaced")
        XCTAssertNil(grants[0].category)
        XCTAssertEqual(grants[0].serviceLabel, "Liverpool", "de-prefixed from kTCCService")
    }

    // MARK: - Skipping & metadata

    func testRowsMissingServiceOrClientSkipped() {
        let grants = TCCAuditor.mapAccessRows([
            row(service: nil, client: "com.example.app", authValue: 2),
            row(service: "kTCCServiceCamera", client: nil, authValue: 2),
            row(service: "kTCCServiceCamera", client: "", authValue: 2),
            row(service: "kTCCServiceCamera", client: "com.example.app", authValue: 2),
        ], scope: .user)
        XCTAssertEqual(grants.count, 1)
    }

    func testLastModifiedEpochParsed() {
        let grants = TCCAuditor.mapAccessRows([
            row(service: "kTCCServiceCamera", client: "com.example.app", authValue: 2, lastModified: 1_700_000_000),
        ], scope: .user)
        XCTAssertEqual(grants.first?.lastModified, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - App matching

    func testMatchingByBundleIDAndPath() {
        let grants = TCCAuditor.mapAccessRows([
            row(service: "kTCCServiceCamera", client: "com.example.app", clientType: 0, authValue: 2),
            row(service: "kTCCServiceMicrophone", client: "com.other.app", clientType: 0, authValue: 2),
            row(service: "kTCCServiceAccessibility", client: "/Applications/Foo.app/Contents/MacOS/Foo", clientType: 1, authValue: 2),
        ], scope: .system)

        let mine = grants.matching(bundleID: "com.example.app",
                                   executablePath: "/Applications/Foo.app/Contents/MacOS/Foo",
                                   bundlePath: "/Applications/Foo.app")
        let categories = Set(mine.compactMap(\.category))
        XCTAssertTrue(categories.contains(.camera))
        XCTAssertTrue(categories.contains(.accessibility))
        XCTAssertFalse(categories.contains(.microphone), "com.other.app must not match")
    }

    func testDisplayNameCoversSystemAccessCategories() {
        XCTAssertEqual(PrivacyCategory.fullDiskAccess.displayName, "Full Disk Access")
        XCTAssertEqual(PrivacyCategory.screenCapture.displayName, "Screen Recording")
        XCTAssertTrue(PrivacyCategory.accessibility.isSystemAccess)
        XCTAssertFalse(PrivacyCategory.camera.isSystemAccess)
    }
}
