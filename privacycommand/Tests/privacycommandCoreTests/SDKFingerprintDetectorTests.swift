import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Regression coverage for issue #3 — privacycommand reporting trackers in
/// itself. The SDK fingerprint database is compiled into our own binary, so a
/// self-scan finds every tracker URL/symbol as a string constant. The detector
/// must suppress those string-derived signals for our own bundle while leaving
/// detection of every other app untouched.
final class SDKFingerprintDetectorTests: XCTestCase {

    // A URL + domain that the Firebase Analytics fingerprint matches on.
    private let firebaseURL = "https://app-measurement.com/a"
    private let firebaseDomain = "firebaseio.com"

    /// The reported bug: scanning our own bundle flags Firebase from the
    /// database strings alone. After the fix, no string-only hit survives.
    func testSelfAnalysisSuppressesStringOnlyTrackerHits() {
        let report = Fix.report(
            bundle: Fix.bundle(bundleID: SDKFingerprintDetector.analyzerBundleID),
            hardcodedURLs: [firebaseURL],
            hardcodedDomains: [firebaseDomain]
        )
        let hits = SDKFingerprintDetector.detect(
            in: report, extraSymbols: ["FIRApp", "FIRAnalyticsConfiguration"])
        XCTAssertTrue(hits.isEmpty,
                      "Self-analysis should not report trackers matched only via embedded database strings.")
    }

    /// The same artefacts in *another* app are still a real finding — the fix
    /// must not weaken detection for everyone else.
    func testOtherAppStillFlaggedFromSameArtefacts() {
        let report = Fix.report(
            bundle: Fix.bundle(bundleID: "com.example.thirdparty"),
            hardcodedURLs: [firebaseURL],
            hardcodedDomains: [firebaseDomain]
        )
        let hits = SDKFingerprintDetector.detect(in: report, extraSymbols: ["FIRApp"])
        XCTAssertTrue(hits.contains { $0.fingerprint.id == "firebase-analytics" },
                      "A non-self app embedding Firebase strings must still be flagged.")
        XCTAssertTrue(hits.contains { $0.isTrackerLike })
    }

    /// Self-analysis suppresses *string* evidence only. A genuinely linked
    /// tracker framework (real dependency, not a database string) must still be
    /// reported even for our own bundle, so a future regression can't hide.
    func testSelfAnalysisStillCatchesLinkedFramework() {
        let firebaseFramework = FrameworkRef(
            url: URL(fileURLWithPath: "/tmp/x/Frameworks/FirebaseAnalytics.framework"),
            bundleID: "com.google.firebase.analytics",
            version: nil, teamID: nil, isAppleSigned: false)
        let report = Fix.report(
            bundle: Fix.bundle(bundleID: SDKFingerprintDetector.analyzerBundleID),
            frameworks: [firebaseFramework],
            hardcodedURLs: [firebaseURL]
        )
        let hits = SDKFingerprintDetector.detect(in: report)
        let firebase = hits.first { $0.fingerprint.id == "firebase-analytics" }
        XCTAssertNotNil(firebase, "A real linked tracker framework must survive self-analysis suppression.")
        // The surviving evidence must be the framework/bundle-ID signal, never
        // a suppressed URL string.
        let hasStringEvidence = firebase?.evidence.contains {
            if case .url = $0 { return true } else { return false }
        } ?? false
        XCTAssertFalse(hasStringEvidence, "URL/string evidence should be suppressed for self-analysis.")
    }

    // MARK: - Anchored matching (Wave 1: kill the substring false-positive class)

    private func framework(_ name: String, bundleID: String? = nil) -> FrameworkRef {
        FrameworkRef(url: URL(fileURLWithPath: "/tmp/x/Frameworks/\(name).framework"),
                     bundleID: bundleID, version: nil, teamID: nil, isAppleSigned: false)
    }
    private func sdkIDs(_ report: StaticReport) -> Set<String> {
        Set(SDKFingerprintDetector.detect(in: report).map { $0.fingerprint.id })
    }

    func testGenericAnalyticsFrameworkIsNotSegment() {
        let r = Fix.report(bundle: Fix.bundle(bundleID: "com.example.app"),
                           frameworks: [framework("FirebaseAnalytics", bundleID: "com.google.firebase.analytics")])
        let hit = sdkIDs(r)
        XCTAssertTrue(hit.contains("firebase-analytics"), "FirebaseAnalytics.framework is Firebase")
        XCTAssertFalse(hit.contains("segment"), "FirebaseAnalytics must NOT be attributed to Segment")
    }

    func testRealSegmentStillDetectedEveryWay() {
        XCTAssertTrue(sdkIDs(Fix.report(bundle: Fix.bundle(bundleID: "com.example.app"),
            frameworks: [framework("Segment")])).contains("segment"))
        XCTAssertTrue(sdkIDs(Fix.report(bundle: Fix.bundle(bundleID: "com.example.app"),
            frameworks: [framework("X", bundleID: "com.segment.analytics")])).contains("segment"))
        XCTAssertTrue(sdkIDs(Fix.report(bundle: Fix.bundle(bundleID: "com.example.app"),
            hardcodedDomains: ["api.segment.io"])).contains("segment"))
    }

    func testCommonWordFrameworksNoLongerOvermatch() {
        let r = Fix.report(bundle: Fix.bundle(bundleID: "com.example.app"),
            frameworks: [framework("ColorAdjust"), framework("GitBranch"), framework("MinHeap")])
        let hit = sdkIDs(r)
        for id in ["adjust","branch","heap"] {
            XCTAssertFalse(hit.contains(id), "generic-word framework must not flag \(id)")
        }
        XCTAssertTrue(sdkIDs(Fix.report(bundle: Fix.bundle(bundleID: "com.example.app"),
            frameworks: [framework("Adjust")])).contains("adjust"), "the real Adjust.framework still flags")
    }

    func testDomainMatchingIsHostBoundary() {
        XCTAssertFalse(sdkIDs(Fix.report(bundle: Fix.bundle(bundleID: "com.example.app"),
            hardcodedDomains: ["myadjust.com"])).contains("adjust"), "myadjust.com != adjust.com")
        XCTAssertTrue(sdkIDs(Fix.report(bundle: Fix.bundle(bundleID: "com.example.app"),
            hardcodedDomains: ["app.adjust.com"])).contains("adjust"), "app.adjust.com is a sub-domain")
    }

    func testBundleIDMatchingIsDotBoundary() {
        XCTAssertFalse(sdkIDs(Fix.report(bundle: Fix.bundle(bundleID: "com.example.app"),
            frameworks: [framework("X", bundleID: "com.example.segmentation")])).contains("segment"))
        XCTAssertTrue(sdkIDs(Fix.report(bundle: Fix.bundle(bundleID: "com.example.app"),
            frameworks: [framework("X", bundleID: "com.segment.analytics")])).contains("segment"))
    }

    func testApplePlatformBinaryGetsNoSDKHits() {
        let r = Fix.report(bundle: Fix.bundle(bundleID: "com.apple.something"),
            codeSigning: Fix.signing(platform: true),
            frameworks: [framework("FirebaseAnalytics", bundleID: "com.google.firebase.analytics")],
            hardcodedDomains: ["api.segment.io"])
        XCTAssertTrue(sdkIDs(r).isEmpty, "Apple platform binaries never carry third-party SDKs")
    }
}
