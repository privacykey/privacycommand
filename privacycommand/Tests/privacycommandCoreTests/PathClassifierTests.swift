import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

final class PathClassifierTests: XCTestCase {

    func testClassifiesUserDocuments() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let c = PathClassifier(homeURL: home)
        XCTAssertEqual(c.classify("/Users/alice/Documents/budget.numbers"), .userDocuments)
        XCTAssertEqual(c.classify("/Users/alice/Documents"),                .userDocuments)
    }

    func testClassifiesKeychainsAsItsOwnCategory() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let c = PathClassifier(homeURL: home)
        XCTAssertEqual(c.classify("/Users/alice/Library/Keychains/login.keychain-db"), .userLibraryKeychains)
        // Mail and Keychains both live under ~/Library; ensure ordering picks the
        // most specific rule first.
        XCTAssertEqual(c.classify("/Users/alice/Library/Mail/V10/foo.mbox"), .userLibraryMail)
    }

    func testClassifiesContainersBeforeAppSupport() {
        // ~/Library/Containers is more specific than ~/Library/Application Support
        // and the rule ordering preserves that.
        let home = URL(fileURLWithPath: "/Users/alice")
        let c = PathClassifier(homeURL: home)
        XCTAssertEqual(
            c.classify("/Users/alice/Library/Containers/com.example/Data/Documents/foo.txt"),
            .userLibraryContainers
        )
    }

    func testClassifiesTempFolders() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let c = PathClassifier(homeURL: home)
        XCTAssertEqual(c.classify("/private/var/folders/x/y/z/T/scratch.tmp"), .temporary)
        XCTAssertEqual(c.classify("/tmp/foo"), .temporary)
    }

    func testBundleInternalWins() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let c = PathClassifier(homeURL: home)
        let appURL = URL(fileURLWithPath: "/Applications/Foo.app")
        // A path inside the bundle should be classified as bundleInternal even
        // though `/Applications/...` would otherwise hit the `.applications` rule.
        XCTAssertEqual(c.classify("/Applications/Foo.app/Contents/Resources/foo.bin",
                                  ownerBundleURL: appURL), .bundleInternal)
    }

    func testUnknownPathIsUnknown() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let c = PathClassifier(homeURL: home)
        XCTAssertEqual(c.classify("/opt/something/odd"), .unknown)
    }
}
