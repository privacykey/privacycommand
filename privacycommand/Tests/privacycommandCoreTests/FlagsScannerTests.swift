import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Regression tests for `FlagsScanner` false positives.
///
/// Background: the Unleash rule used to include a bare `isEnabled` token, which
/// is the getter selector for `NSControl`/`UIControl.enabled` and ships as a
/// `__cstring` in essentially every Cocoa/SwiftUI binary — so any app matched
/// "Unleash" (e.g. Afolio, which has no feature-flag SDK at all). The fix:
/// vendor rules must key on vendor-*specific* tokens, never generic API names.
final class FlagsScannerTests: XCTestCase {

    /// Run the scanner over a single printable run and return the matched kinds.
    private func kinds(_ token: String) -> Set<FlagFinding.Kind> {
        Set(FlagsScanner.scan(data: Data(token.utf8)).findings.map(\.kind))
    }

    // MARK: - The false positive that started this

    func testBareIsEnabledIsNotUnleash() {
        // `isEnabled` is a ubiquitous Cocoa selector — it must produce NO
        // feature-flag attribution at all, least of all Unleash.
        let k = kinds("isEnabled")
        XCTAssertFalse(k.contains(.unleash), "bare isEnabled must not be attributed to Unleash")
        XCTAssertTrue(k.isEmpty, "bare isEnabled should match no flag rule, got \(k)")
    }

    func testGenericControlSelectorsDoNotMatchUnleash() {
        for token in ["setIsEnabled:", "isUserInteractionEnabled", "enabled"] {
            XCTAssertFalse(kinds(token).contains(.unleash),
                           "\(token) must not be attributed to Unleash")
        }
    }

    // MARK: - Real Unleash signals still detected

    func testGenuineUnleashTokensStillMatch() {
        for token in ["UnleashClient", "unleash_toggle", "unleash_api", "unleash_context", "getunleash.io"] {
            XCTAssertTrue(kinds(token).contains(.unleash), "\(token) should still flag Unleash")
        }
    }

    // MARK: - PostHog: generic flag methods demoted to generic, vendor tokens kept

    func testGenericFlagMethodsAreGenericNotPostHog() {
        for token in ["getFeatureFlag", "isFeatureEnabled"] {
            let k = kinds(token)
            XCTAssertTrue(k.contains(.featureFlag), "\(token) should be a generic feature-flag signal")
            XCTAssertFalse(k.contains(.posthogFlag), "\(token) must NOT be attributed to PostHog specifically")
        }
    }

    func testGenuinePostHogTokenStillMatches() {
        XCTAssertTrue(kinds("PHGPostHog").contains(.posthogFlag))
        XCTAssertTrue(kinds("posthog").contains(.posthogFlag))
    }

    // MARK: - Sanity: unrelated strings stay quiet, real generic flags still fire

    func testUnrelatedStringsProduceNoFindings() {
        for token in ["RebrickableInventory", "priceGuide.reloadVariant", "CheckboxToggleStyle"] {
            XCTAssertTrue(kinds(token).isEmpty, "\(token) should not match any flag rule, got \(kinds(token))")
        }
    }

    func testRealGenericFeatureFlagsStillFire() {
        XCTAssertTrue(kinds("feature_flag").contains(.featureFlag))
        XCTAssertTrue(kinds("FeatureToggle").contains(.featureFlag))
    }
}
