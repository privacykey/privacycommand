import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

final class BinaryStringScannerTests: XCTestCase {

    func testFindsURLsAndDomainsInData() throws {
        let payload = """
        00 some preamble
        https://api.example.com/v1/health
        zoom.us
        /Users/alice/Documents/secret.txt
        AVCaptureDevice
        garbage
        \0
        """
        let url = makeFixture(named: "scanner-fixture", contents: payload)

        let result = BinaryStringScanner.scan(executable: url, timeoutSeconds: 5)

        XCTAssertTrue(result.urls.contains("https://api.example.com/v1/health"),
                      "should pick up https URLs")
        XCTAssertTrue(result.domains.contains("zoom.us"),
                      "should pick up bare domains")
        XCTAssertTrue(result.paths.contains(where: { $0.contains("/Users/alice/Documents") }),
                      "should pick up user-folder paths")
        XCTAssertTrue(result.foundFrameworkSymbols.contains("AVCaptureDevice"),
                      "should find privacy-sensitive symbol references")
    }

    func testRejectsReverseDNSAndCertFieldFalsePositives() throws {
        // Mix one real domain in with the look-alikes that used to leak through.
        let payload = [
            "api.segment.io",                      // real domain — keep
            "com.apple.security.device.usb",       // entitlement key — drop
            "com.google.chrome.beta",              // bundle ID — drop
            "subject.ou",                          // cert field — drop
            "config.plist"                         // file name — drop
        ].joined(separator: "\u{0}")
        let url = makeFixture(named: "domain-fp-fixture", contents: payload)

        let result = BinaryStringScanner.scan(executable: url, timeoutSeconds: 5)

        XCTAssertEqual(result.domains, ["api.segment.io"],
                       "only the real hostname should survive; got \(result.domains.sorted())")
    }

    private func makeFixture(named: String, contents: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(named + ".bin")
        try? contents.data(using: .utf8)!.write(to: url)
        return url
    }
}
