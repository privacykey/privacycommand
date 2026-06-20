import XCTest
@testable import privacycommandCore

/// Wave 11 — privacy-manifest vs observed-tracking mismatch.
final class ManifestTrackingMismatchTests: XCTestCase {

    private func manifest(tracking: Bool,
                          domains: [String] = [],
                          collected: [PrivacyManifest.CollectedDataType] = []) -> PrivacyManifest {
        PrivacyManifest(
            url: URL(fileURLWithPath: "/tmp/PrivacyInfo.xcprivacy"),
            isTrackingDeclared: tracking,
            trackingDomains: domains,
            collectedDataTypes: collected,
            accessedAPITypes: [])
    }

    // MARK: - SDK contradiction

    func testTrackerSDKWhileTrackingNotDeclared_isContradiction() {
        let tx = PrivacyManifestReader.trackingCrossCheck(
            manifest: manifest(tracking: false),
            trackerSDKNames: ["AppLovin", "AdMob"],
            observedTrackerDomains: [])
        XCTAssertEqual(tx.trackerSDKsButTrackingNotDeclared, ["AdMob", "AppLovin"])
        XCTAssertFalse(tx.isClean)
    }

    func testTrackerSDKWhenTrackingDeclared_isClean() {
        let tx = PrivacyManifestReader.trackingCrossCheck(
            manifest: manifest(tracking: true),
            trackerSDKNames: ["AppLovin"],
            observedTrackerDomains: [])
        XCTAssertTrue(tx.trackerSDKsButTrackingNotDeclared.isEmpty)
    }

    func testTrackingDeclaredViaCollectedDataType_isClean() {
        // NSPrivacyTracking false, but a collected type marked usedForTracking
        // still counts as a tracking declaration.
        let tracked = PrivacyManifest.CollectedDataType(
            rawType: "NSPrivacyCollectedDataTypeDeviceID", displayName: "Device ID",
            linkedToUser: true, usedForTracking: true, purposes: [])
        let tx = PrivacyManifestReader.trackingCrossCheck(
            manifest: manifest(tracking: false, collected: [tracked]),
            trackerSDKNames: ["AppLovin"],
            observedTrackerDomains: [])
        XCTAssertTrue(tx.trackerSDKsButTrackingNotDeclared.isEmpty)
    }

    // MARK: - Undeclared tracking domains

    func testUndeclaredTrackerDomain_isFlagged() {
        let tx = PrivacyManifestReader.trackingCrossCheck(
            manifest: manifest(tracking: true, domains: ["declared.com"]),
            trackerSDKNames: [],
            observedTrackerDomains: ["tracker.io", "declared.com"])
        XCTAssertEqual(tx.undeclaredTrackingDomains, ["tracker.io"])
    }

    func testSubdomainOfDeclaredDomain_isNotFlagged() {
        // A sub-domain of a declared tracking domain counts as declared.
        let tx = PrivacyManifestReader.trackingCrossCheck(
            manifest: manifest(tracking: true, domains: ["graph.facebook.com"]),
            trackerSDKNames: [],
            observedTrackerDomains: ["api.graph.facebook.com"])
        XCTAssertTrue(tx.undeclaredTrackingDomains.isEmpty)
    }

    func testDomainComparisonIsCaseInsensitive() {
        let tx = PrivacyManifestReader.trackingCrossCheck(
            manifest: manifest(tracking: true, domains: ["Tracker.IO"]),
            trackerSDKNames: [],
            observedTrackerDomains: ["tracker.io"])
        XCTAssertTrue(tx.undeclaredTrackingDomains.isEmpty)
    }

    // MARK: - RiskScorer wiring

    private func trackerSDKHit() -> SDKHit {
        // Use a real advertising fingerprint so isTrackerLike is genuinely true.
        let fp = SDKFingerprintDatabase.advertising.first!
        return SDKHit(fingerprint: fp, evidence: [.framework(fp.displayName)])
    }

    func testRiskScorerFlagsManifestTrackingMismatch() {
        let hit = trackerSDKHit()
        XCTAssertTrue(hit.isTrackerLike, "precondition: fixture SDK must be tracker-like")
        let report = Fix.report(
            sdkHits: [hit],
            privacyManifest: manifest(tracking: false))
        let result = RiskScorer().score(staticReport: report, events: [])
        XCTAssertTrue(result.contributors.contains { $0.category == "manifest-tracking-mismatch" },
                      "expected a manifest-tracking-mismatch contributor")
    }

    func testRiskScorerNoMismatchWhenTrackingDeclared() {
        let report = Fix.report(
            sdkHits: [trackerSDKHit()],
            privacyManifest: manifest(tracking: true))
        let result = RiskScorer().score(staticReport: report, events: [])
        XCTAssertFalse(result.contributors.contains { $0.category == "manifest-tracking-mismatch" })
    }

    func testRiskScorerNoManifest_noMismatch() {
        let report = Fix.report(sdkHits: [trackerSDKHit()], privacyManifest: nil)
        let result = RiskScorer().score(staticReport: report, events: [])
        XCTAssertFalse(result.contributors.contains { $0.category == "manifest-tracking-mismatch" })
    }
}
