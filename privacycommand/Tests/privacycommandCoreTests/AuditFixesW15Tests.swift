import XCTest
import Foundation
@testable import privacycommandCore

/// Wave 15 — fixes for the 6 defects the adversarial audit of Waves 10-14
/// confirmed. Each test pins the corrected behaviour so it can't regress.
final class AuditFixesW15Tests: XCTestCase {

    // MARK: - #1 dict-form usage key is not "empty purpose"

    func testPurposeStringFromDictionaryIsNonEmpty() {
        // NSLocationTemporaryUsageDescriptionDictionary holds [purpose: description].
        XCTAssertEqual(InfoPlistReader.purposeString(from: ["explore": "because reasons"]),
                       "because reasons")
        XCTAssertFalse(InfoPlistReader.purposeString(from: ["a": "x", "b": "y"]).isEmpty)
    }

    func testPurposeStringFromStringAndEmpty() {
        XCTAssertEqual(InfoPlistReader.purposeString(from: "plain reason"), "plain reason")
        XCTAssertEqual(InfoPlistReader.purposeString(from: [String: Any]()), "")
        XCTAssertEqual(InfoPlistReader.purposeString(from: ["k": ""]), "")
        XCTAssertEqual(InfoPlistReader.purposeString(from: 42), "")
    }

    // MARK: - #3 declared subdomain must not excuse the contacted apex

    func testContactedApexNotSuppressedByDeclaredSubdomain() {
        let m = PrivacyManifest(url: URL(fileURLWithPath: "/x"),
                                isTrackingDeclared: true, trackingDomains: ["widget.criteo.com"],
                                collectedDataTypes: [], accessedAPITypes: [])
        let tx = PrivacyManifestReader.trackingCrossCheck(
            manifest: m, trackerSDKNames: [], observedTrackerDomains: ["criteo.com"])
        XCTAssertEqual(tx.undeclaredTrackingDomains, ["criteo.com"],
                       "apex must still be flagged when only a subdomain is declared")
    }

    func testDeclaredParentStillCoversContactedSubdomain() {
        // The legitimate direction must keep working.
        let m = PrivacyManifest(url: URL(fileURLWithPath: "/x"),
                                isTrackingDeclared: true, trackingDomains: ["criteo.com"],
                                collectedDataTypes: [], accessedAPITypes: [])
        let tx = PrivacyManifestReader.trackingCrossCheck(
            manifest: m, trackerSDKNames: [], observedTrackerDomains: ["widget.criteo.com"])
        XCTAssertTrue(tx.undeclaredTrackingDomains.isEmpty)
    }

    // MARK: - #4 polluted URL host must not leak into domains

    func testResourceScannerDoesNotLeakPollutedHost() {
        var r = EmbeddedResourceScanner.Result()
        EmbeddedResourceScanner.extractText(
            "see (https://a.example.com) and url=https://c.example.com;next=1", into: &r)
        XCTAssertFalse(r.domains.contains { $0.contains(")") || $0.contains(";") || $0.contains(",") },
                       "no punctuation-polluted host should leak, got \(r.domains)")
        // The clean host is still captured (via the validated bare-domain path).
        XCTAssertTrue(r.domains.contains("a.example.com"), "clean host should survive, got \(r.domains)")
    }

    // MARK: - #6 Wine must not match a bare "wine" substring

    func testTwineFrameworkIsNotMisclassifiedAsWine() {
        let r = AppRuntimeDetector.detect(dylibs: [], frameworkNames: ["Twine.framework"], resourceNames: [])
        XCTAssertNotEqual(r.flavor, .wine)
        XCTAssertFalse(r.isSecuritySensitive)
    }

    func testRealWineStillDetectedViaLibwine() {
        let r = AppRuntimeDetector.detect(dylibs: ["@rpath/libwine.1.0.dylib"],
                                          frameworkNames: [], resourceNames: [])
        XCTAssertEqual(r.flavor, .wine)
    }

    // MARK: - #5 unaligned fat slice offset must not trap

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private func thinSlice() -> [UInt8] {
        let lcs = le32(0x32) + le32(24) + le32(1) + le32(0x000E0000) + le32(0x000F0000) + le32(0) // LC_BUILD_VERSION 14.0
        let header = le32(0xFEEDFACF) + le32(0x0100000C) + le32(0) + le32(2) + le32(1) + le32(UInt32(lcs.count)) + le32(0) + le32(0)
        return header + lcs
    }

    func testUnalignedFatSliceOffsetDoesNotTrap() throws {
        let s = thinSlice()
        let oddOffset = 49            // deliberately not 4-byte aligned
        var fat = be32(0xCAFEBABE) + be32(1)
        fat += be32(0x0100000C) + be32(0) + be32(UInt32(oddOffset)) + be32(UInt32(s.count)) + be32(0)
        while fat.count < oddOffset { fat.append(0) }   // pad header out to the odd slice offset
        fat += s

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcw15-\(UUID().uuidString).bin")
        try Data(fat).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Before the fix this trapped ("load from misaligned raw pointer") in
        // debug/test builds. A passing assertion proves it no longer traps AND
        // that the unaligned magic/load were read correctly.
        let lc = MachOInspector.loadCommands(of: url)
        XCTAssertEqual(lc.sliceCount, 1)
        XCTAssertEqual(lc.minOSVersion, "14.0")
    }

    // MARK: - #2 get-task-allow flagged for MAS apps (and still not for local builds)

    private func getTaskAllowEntitlements() -> Entitlements {
        Entitlements(
            raw: ["com.apple.security.get-task-allow": .bool(true)],
            isSandboxed: false, appGroups: [], appleEvents: nil,
            networkClient: false, networkServer: false, allowsJIT: false,
            allowsDyldEnvironmentVariables: false, disablesLibraryValidation: false,
            endpointSecurityClient: false, networkExtension: [])
    }
    private func hasGetTaskAllow(_ report: StaticReport) -> Bool {
        RiskScorer().score(staticReport: report).contributors.contains { $0.category == "get-task-allow" }
    }

    func testGetTaskAllowFlaggedForMASApp() {
        let report = Fix.report(entitlements: getTaskAllowEntitlements(),
                                notarization: .unknown(""),
                                appStoreInfo: AppStoreInfo(isMASApp: true))
        XCTAssertTrue(hasGetTaskAllow(report), "MAS app with get-task-allow is a real anomaly")
    }

    func testGetTaskAllowStillNotFlaggedForUnknownNonMAS() {
        // Deliberate precision trade-off: an un-assessable non-MAS binary could
        // be a local debug build, so we don't flag it (avoids the FP).
        let report = Fix.report(entitlements: getTaskAllowEntitlements(),
                                notarization: .unknown(""),
                                appStoreInfo: .notMAS)
        XCTAssertFalse(hasGetTaskAllow(report))
    }

    func testGetTaskAllowFlaggedForNotarized() {
        let report = Fix.report(entitlements: getTaskAllowEntitlements(),
                                notarization: .notarized,
                                appStoreInfo: .notMAS)
        XCTAssertTrue(hasGetTaskAllow(report))
    }
}
