import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Wave 8 — coverage: additional widely-used SDKs and high-volume tracker
/// domains the database was missing.
final class ExtendedCoverageTests: XCTestCase {

    private func framework(_ name: String, bundleID: String? = nil) -> FrameworkRef {
        FrameworkRef(url: URL(fileURLWithPath: "/x/Frameworks/\(name).framework"),
                     bundleID: bundleID, version: nil, teamID: nil, isAppleSigned: false)
    }
    private func ids(_ report: StaticReport) -> Set<String> {
        Set(SDKFingerprintDetector.detect(in: report).map { $0.fingerprint.id })
    }
    private func report(frameworks: [FrameworkRef] = [], domains: [String] = []) -> StaticReport {
        Fix.report(bundle: Fix.bundle(bundleID: "com.example.app"), frameworks: frameworks, hardcodedDomains: domains)
    }

    func testNewSDKsDetectedViaFramework() {
        XCTAssertTrue(ids(report(frameworks: [framework("CleverTapSDK")])).contains("clevertap"))
        XCTAssertTrue(ids(report(frameworks: [framework("VungleAdsSDK")])).contains("vungle"))
        XCTAssertTrue(ids(report(frameworks: [framework("SuperwallKit")])).contains("superwall"))
        XCTAssertTrue(ids(report(frameworks: [framework("EmbraceIO")])).contains("embrace"))
    }

    func testNewSDKsDetectedViaBundleIDPrefix() {
        XCTAssertTrue(ids(report(frameworks: [framework("X", bundleID: "com.superwall.app")])).contains("superwall"))
        XCTAssertTrue(ids(report(frameworks: [framework("X", bundleID: "io.customer.sdk")])).contains("customerio"))
    }

    func testNewSDKsDetectedViaDomain() {
        XCTAssertTrue(ids(report(domains: ["api.adapty.io"])).contains("adapty"))
        XCTAssertTrue(ids(report(domains: ["track.tenjin.com"])).contains("tenjin"))
        XCTAssertTrue(ids(report(domains: ["live.chartboost.com"])).contains("chartboost"))
    }

    func testNoOverMatchFromAnchoring() {
        // "Batch" is a generic word, but anchored matching means an unrelated
        // framework like "BatchProcessor" must NOT match the Batch SDK.
        XCTAssertFalse(ids(report(frameworks: [framework("BatchProcessor")])).contains("batch"))
        XCTAssertTrue(ids(report(frameworks: [framework("Batch")])).contains("batch"))
    }

    func testNewTrackerDomainsClassified() {
        let c = DomainClassifier()
        XCTAssertEqual(c.classify("connect.facebook.net").category, .adTech)
        XCTAssertEqual(c.classify("app-measurement.com").category, .analytics)
        XCTAssertEqual(c.classify("firebase-settings.crashlytics.com").category, .errorReporting)
    }
}
