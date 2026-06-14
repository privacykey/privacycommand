import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Parser coverage for the App Store privacy-label fetcher, centred on issue
/// #1 — a Mac App Store app that declared **"Data Not Collected"** was being
/// reported as **"No Details Provided"** (the opposite, "developer never filled
/// in the form" state).
///
/// `parse(html:)` is pure, so every state is exercised against canned HTML with
/// no network. The synthetic `serialized-server-data` JSON below mirrors the
/// shapes Apple ships; the live shape isn't pinned by these tests (see the
/// note in the fix), but the classification logic across all four outcomes is.
final class AppStorePrivacyLabelFetcherTests: XCTestCase {

    /// Wrap a JSON payload in the `serialized-server-data` script the parser
    /// scrapes, optionally trailing some visible page chrome.
    private func page(json: String, chrome: String = "") -> String {
        """
        <html><head></head><body>
        <script type="application/json" id="serialized-server-data">\(json)</script>
        \(chrome)
        </body></html>
        """
    }

    /// JSON with nothing under any recognised privacy-types path.
    private let emptyDataJSON = #"[{"data":{}}]"#

    // MARK: - Happy path: structured labels with real data

    func testStructuredLabelsParseAsProvided() throws {
        let json = """
        [{"data":{"shelfMapping":{"privacyTypes":{"items":[
          {"identifier":"DATA_LINKED_TO_YOU","title":"Data Linked to You","detail":"",
           "categories":[{"identifier":"USAGE_DATA","title":"Usage Data"}]}
        ]}}}}]
        """
        let result = try AppStorePrivacyLabelFetcher.parse(html: page(json: json))
        XCTAssertEqual(result.detailsStatus, .provided)
        XCTAssertEqual(result.labels?.types.first?.identifier, "DATA_LINKED_TO_YOU")
        XCTAssertEqual(result.labels?.types.first?.categories.first?.identifier, "USAGE_DATA")
        XCTAssertFalse(result.labels?.isExplicitlyNotCollected ?? true)
    }

    // MARK: - Issue #1: "Data Not Collected"

    /// The structured paths miss the sparse not-collected payload (here it's
    /// nested off the recognised shelves), but the graph-wide fallback finds
    /// the `DATA_NOT_COLLECTED` item by its identifier. No "Data Not Collected"
    /// prose is present, so this isolates the JSON fallback, not the text one.
    func testDataNotCollectedFoundByDeepJSONFallback() throws {
        let json = """
        [{"data":{"unexpectedShelf":{"nested":[
          {"identifier":"DATA_NOT_COLLECTED","title":"Data Not Collected","detail":"","categories":[]}
        ]}}}]
        """
        let result = try AppStorePrivacyLabelFetcher.parse(html: page(json: json))
        XCTAssertEqual(result.detailsStatus, .provided)
        XCTAssertEqual(result.labels?.isExplicitlyNotCollected, true)
    }

    /// No structured privacy items at all, but the page shows Apple's positive
    /// "does not collect any data" disclaimer — classify as a real declaration,
    /// not "no details".
    func testDataNotCollectedFoundByTextFallback() throws {
        let chrome = "<p>The developer does not collect any data from this app.</p>"
        let result = try AppStorePrivacyLabelFetcher.parse(
            html: page(json: emptyDataJSON, chrome: chrome))
        XCTAssertEqual(result.detailsStatus, .provided)
        XCTAssertEqual(result.labels?.isExplicitlyNotCollected, true)
    }

    /// The exact reported failure: a not-collected app whose page *also*
    /// contains the "No Details Provided" string somewhere in its chrome. The
    /// positive declaration must win — pre-fix this returned `.noDetailsProvided`.
    func testNotCollectedWinsOverNoDetailsBoilerplate() throws {
        let chrome = """
        <p>The developer does not collect any data from this app.</p>
        <div class="page-chrome" hidden>No Details Provided</div>
        """
        let result = try AppStorePrivacyLabelFetcher.parse(
            html: page(json: emptyDataJSON, chrome: chrome))
        XCTAssertEqual(result.detailsStatus, .provided)
        XCTAssertEqual(result.labels?.isExplicitlyNotCollected, true)
    }

    // MARK: - Genuine "No Details Provided"

    func testGenuineNoDetailsThrows() {
        let chrome = "<p>The developer will be required to provide privacy details when they submit their next update.</p>"
        XCTAssertThrowsError(
            try AppStorePrivacyLabelFetcher.parse(html: page(json: emptyDataJSON, chrome: chrome))
        ) { error in
            guard case AppStorePrivacyLabelFetcher.FetchError.noDetailsProvided = error else {
                return XCTFail("Expected .noDetailsProvided, got \(error)")
            }
        }
    }

    // MARK: - Layout change / unknown shape

    func testNoSignalsThrowsParseFailure() {
        XCTAssertThrowsError(
            try AppStorePrivacyLabelFetcher.parse(html: page(json: emptyDataJSON))
        ) { error in
            guard case AppStorePrivacyLabelFetcher.FetchError.parseFailure = error else {
                return XCTFail("Expected .parseFailure, got \(error)")
            }
        }
    }
}
