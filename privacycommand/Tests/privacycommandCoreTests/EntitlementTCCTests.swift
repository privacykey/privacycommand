import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Wave 10 — surface high-trust / sandbox-escape entitlements and broaden the
/// TCC usage-key filter.
final class EntitlementTCCTests: XCTestCase {

    private func ents(_ raw: [String: PlistValue]) -> Entitlements {
        Entitlements(raw: raw, isSandboxed: false, appGroups: [], appleEvents: nil,
                     networkClient: false, networkServer: false, allowsJIT: false,
                     allowsDyldEnvironmentVariables: false, disablesLibraryValidation: false,
                     endpointSecurityClient: false, networkExtension: [])
    }
    private func categories(_ report: StaticReport) -> Set<String> {
        Set(RiskScorer().score(staticReport: report).contributors.map(\.category))
    }

    // MARK: - Classification

    func testNotableEntitlementsClassified() {
        let n = EntitlementsReader.notableEntitlements(in: [
            "com.apple.developer.system-extension.install": .bool(true),
            "com.apple.developer.driverkit.transport.usb": .bool(true),
            "com.apple.security.cs.debugger": .bool(true),
            "com.apple.security.temporary-exception.files.absolute-path.read-write": .array([.string("/")]),
        ])
        let keys = Set(n.map(\.key))
        XCTAssertTrue(keys.contains("com.apple.developer.system-extension.install"))
        XCTAssertTrue(keys.contains("com.apple.developer.driverkit"))
        XCTAssertTrue(keys.contains("com.apple.security.cs.debugger"))
        XCTAssertTrue(keys.contains("com.apple.security.temporary-exception.files.absolute-path.read-write"))
        XCTAssertTrue(n.allSatisfy { $0.severity == .high }, "these are all high-trust / broad escape hatches")
    }

    func testBenignEntitlementsNotFlagged() {
        // App's own app-groups / network client are common and must NOT be notable.
        let n = EntitlementsReader.notableEntitlements(in: [
            "com.apple.security.app-sandbox": .bool(true),
            "com.apple.security.network.client": .bool(true),
            "com.apple.security.application-groups": .array([.string("group.com.x")]),
        ])
        XCTAssertTrue(n.isEmpty)
    }

    // MARK: - Risk scoring

    func testSystemExtensionScoredForThirdPartyButNotApple() {
        let raw: [String: PlistValue] = ["com.apple.developer.system-extension.install": .bool(true)]
        let third = Fix.report(entitlements: ents(raw), codeSigning: Fix.signing(platform: false))
        XCTAssertTrue(categories(third).contains("high-trust-entitlement"))
        let apple = Fix.report(entitlements: ents(raw), codeSigning: Fix.signing(platform: true))
        XCTAssertFalse(categories(apple).contains("high-trust-entitlement"),
                       "Apple platform binaries legitimately hold these")
    }

    func testGetTaskAllowScoredOnlyInReleaseBuild() {
        let raw: [String: PlistValue] = ["com.apple.security.get-task-allow": .bool(true)]
        let release = Fix.report(entitlements: ents(raw), codeSigning: Fix.signing(platform: false), notarization: .notarized)
        XCTAssertTrue(categories(release).contains("get-task-allow"), "debuggable in a distributed build is a concern")
        let debug = Fix.report(entitlements: ents(raw), codeSigning: Fix.signing(platform: false), notarization: .unsigned)
        XCTAssertFalse(categories(debug).contains("get-task-allow"), "get-task-allow is expected in a debug build")
    }

    // MARK: - TCC usage-key filter

    func testTCCFilterCatchesNonNSAndDictionaryKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tcc-\(UUID().uuidString)")
        let contents = root.appendingPathComponent("X.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: [String: Any] = [
            "CFBundleExecutable": "X",
            "NSCameraUsageDescription": "cam",
            "NFCReaderUsageDescription": "nfc",                          // non-NS prefix
            "NSLocationTemporaryUsageDescriptionDictionary": ["k": "v"], // *Dictionary suffix
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = AppBundle(url: root.appendingPathComponent("X.app"), bundleID: "x", bundleName: "X",
                               bundleVersion: "1", executableURL: contents.appendingPathComponent("MacOS/X"),
                               architectures: [], minimumSystemVersion: nil)
        let keys = Set(InfoPlistReader.read(for: bundle, db: .builtin).declaredPrivacyKeys.map(\.rawKey))
        XCTAssertTrue(keys.contains("NSCameraUsageDescription"))
        XCTAssertTrue(keys.contains("NFCReaderUsageDescription"), "non-NS usage keys must be caught")
        XCTAssertTrue(keys.contains("NSLocationTemporaryUsageDescriptionDictionary"))
    }
}
