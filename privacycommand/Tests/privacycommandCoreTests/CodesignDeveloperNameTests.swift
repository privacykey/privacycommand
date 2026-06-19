import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Covers `CodesignWrapper.developerName(fromCommonName:)` — the parser
/// that expands a signing certificate's common name into the developer /
/// organization name shown in the header's signing-team badge.
final class CodesignDeveloperNameTests: XCTestCase {

    func testDeveloperIDApplication() {
        XCTAssertEqual(
            CodesignWrapper.developerName(
                fromCommonName: "Developer ID Application: ACME Inc. (AB12CD34EF)"),
            "ACME Inc.")
    }

    func testAppleDistribution() {
        XCTAssertEqual(
            CodesignWrapper.developerName(
                fromCommonName: "Apple Distribution: Globex Corporation (1A2B3C4D5E)"),
            "Globex Corporation")
    }

    func testNameContainingParensAndColon() {
        // A colon and parens inside the org name shouldn't trip the parser:
        // only the trailing 10-char Team-ID suffix is stripped, and only the
        // role prefix before the FIRST ": " is removed.
        XCTAssertEqual(
            CodesignWrapper.developerName(
                fromCommonName: "Developer ID Application: Foo: Bar (Holdings) (0011223344)"),
            "Foo: Bar (Holdings)")
    }

    func testAppleResignedLeafHasNoName() {
        // App-Store-resigned binaries carry Apple's leaf, which has no
        // "(TeamID)" suffix — we must not surface it as a developer name.
        XCTAssertNil(
            CodesignWrapper.developerName(
                fromCommonName: "Apple Mac OS Application Signing"))
    }

    func testNonTeamParenIsNotMistakenForTeamID() {
        // A trailing paren that isn't a 10-char alphanumeric Team ID is not
        // a Team-ID suffix, so there's nothing to expand.
        XCTAssertNil(
            CodesignWrapper.developerName(
                fromCommonName: "Some Authority (Root)"))
    }
}
