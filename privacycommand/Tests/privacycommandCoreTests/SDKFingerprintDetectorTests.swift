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
}
