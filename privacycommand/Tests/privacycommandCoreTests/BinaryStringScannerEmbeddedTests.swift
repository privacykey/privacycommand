import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Wave 4 — coverage: endpoints from EMBEDDED Mach-Os (frameworks, XPC,
/// helpers, .appex), not just the main executable. An SDK's network domains
/// usually live in its embedded framework binary.
final class BinaryStringScannerEmbeddedTests: XCTestCase {

    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("emb-\(UUID().uuidString).bin")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testScanMergesEndpointsAcrossFiles() throws {
        let f1 = try tempFile("api.foo.com")
        let f2 = try tempFile("https://bar.example.com/track\u{0}tracker.example.net")
        defer { for u in [f1, f2] { try? FileManager.default.removeItem(at: u) } }

        let r = BinaryStringScanner.scan(executables: [f1, f2])
        XCTAssertTrue(r.domains.contains("api.foo.com"), "domain from the first embedded file")
        XCTAssertTrue(r.domains.contains("tracker.example.net"), "domain from the second embedded file")
        XCTAssertTrue(r.urls.contains { $0.contains("bar.example.com") }, "URL from the second embedded file")
    }

    func testScanRespectsMaxFiles() throws {
        let a = try tempFile("alpha.example.com")
        let b = try tempFile("bravo.example.com")
        let c = try tempFile("charlie.example.com")
        defer { for u in [a, b, c] { try? FileManager.default.removeItem(at: u) } }

        let r = BinaryStringScanner.scan(executables: [a, b, c], maxFiles: 2)
        XCTAssertTrue(r.domains.contains("alpha.example.com"))
        XCTAssertTrue(r.domains.contains("bravo.example.com"))
        XCTAssertFalse(r.domains.contains("charlie.example.com"), "third file is beyond maxFiles and must be skipped")
    }

    func testEmptyInputIsEmptyResult() {
        let r = BinaryStringScanner.scan(executables: [])
        XCTAssertTrue(r.domains.isEmpty && r.urls.isEmpty && r.paths.isEmpty && r.foundFrameworkSymbols.isEmpty)
    }
}
