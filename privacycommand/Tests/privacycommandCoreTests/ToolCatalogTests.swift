import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Sanity checks for the curated further-tools catalog (Feature C).
final class ToolCatalogTests: XCTestCase {

    func testCatalogCoversEveryCategory() {
        XCTAssertFalse(ToolCatalog.all.isEmpty)
        for category in AnalysisTool.Category.allCases {
            XCTAssertFalse(ToolCatalog.tools(in: category).isEmpty,
                           "category \(category.rawValue) should have at least one tool")
        }
    }

    func testEveryToolHasHTTPSURLAndBlurb() {
        for tool in ToolCatalog.all {
            XCTAssertEqual(tool.url?.scheme, "https", "\(tool.name) must have an https URL")
            XCTAssertFalse(tool.blurb.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(tool.name) needs a blurb")
        }
    }

    func testIDsAreUnique() {
        XCTAssertEqual(Set(ToolCatalog.all.map(\.id)).count, ToolCatalog.all.count,
                       "tool names (ids) must be unique")
    }
}
