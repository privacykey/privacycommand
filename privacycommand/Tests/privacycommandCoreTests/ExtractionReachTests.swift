import XCTest
import Foundation
@testable import privacycommandCore

/// Wave 12 — extraction reach: UTF-16LE wide strings, base64/hex decode in the
/// binary scanner, and the new resource-file endpoint scanner.
final class ExtractionReachTests: XCTestCase {

    // MARK: - UTF-16LE wide strings

    func testUTF16LE_URL_isExtracted() {
        var d = Data([0, 0])
        d.append("https://wide.example.com/x".data(using: .utf16LittleEndian)!)
        d.append(contentsOf: [0, 0])
        let r = BinaryStringScanner.scan(data: d)
        XCTAssertTrue(r.urls.contains("https://wide.example.com/x"),
                      "UTF-16LE URL should be decoded, got \(r.urls)")
    }

    func testUTF16LE_bareDomain_isExtracted() {
        var d = Data([0, 0])
        d.append("telemetry.example.org".data(using: .utf16LittleEndian)!)
        d.append(contentsOf: [0, 0])
        let r = BinaryStringScanner.scan(data: d)
        XCTAssertTrue(r.domains.contains("telemetry.example.org"),
                      "UTF-16LE bare domain should be decoded, got \(r.domains)")
    }

    func testASCII_stillExtractedAlongsideUTF16() {
        // Regression: the ASCII pass must keep working after the refactor.
        let d = Data("https://ascii.example.net/api".utf8)
        let r = BinaryStringScanner.scan(data: d)
        XCTAssertTrue(r.urls.contains("https://ascii.example.net/api"))
    }

    // MARK: - base64 / hex decode

    func testBase64Blob_decodesToURL() {
        let payload = "https://b64.example.net/p"
        let b64 = Data(payload.utf8).base64EncodedString()
        var d = Data([0])
        d.append(Data(b64.utf8))
        d.append(contentsOf: [0])
        let r = BinaryStringScanner.scan(data: d)
        XCTAssertTrue(r.urls.contains(payload), "base64 blob should decode to its URL, got \(r.urls)")
    }

    func testHexBlob_decodesToURL() {
        let payload = "https://hexd.example.net"
        let hex = Data(payload.utf8).map { String(format: "%02x", $0) }.joined()
        var d = Data([0])
        d.append(Data(hex.utf8))
        d.append(contentsOf: [0])
        let r = BinaryStringScanner.scan(data: d)
        XCTAssertTrue(r.urls.contains(payload), "hex blob should decode to its URL, got \(r.urls)")
    }

    func testBinaryBase64Blob_isNotSurfaced() {
        // base64 of non-printable bytes must NOT be re-ingested (no noise).
        let binary = Data((0..<24).map { UInt8($0) })
        let b64 = binary.base64EncodedString()
        var d = Data([0])
        d.append(Data(b64.utf8))
        d.append(contentsOf: [0])
        let r = BinaryStringScanner.scan(data: d)
        XCTAssertTrue(r.urls.isEmpty && r.domains.isEmpty,
                      "binary base64 must not surface endpoints, got urls=\(r.urls) domains=\(r.domains)")
    }

    // MARK: - Resource-file scanner

    func testResourceScanner_jsonURLAndHost() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcres-\(UUID().uuidString)")
        let res = tmp.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = #"{"api":"https://res.example.com/v1","host":"telemetry.contoso.io"}"#
        try Data(json.utf8).write(to: res.appendingPathComponent("config.json"))

        let r = EmbeddedResourceScanner.scan(root: tmp)
        XCTAssertTrue(r.urls.contains("https://res.example.com/v1"), "got urls=\(r.urls)")
        XCTAssertTrue(r.domains.contains("res.example.com"), "URL host should be captured, got \(r.domains)")
        XCTAssertTrue(r.domains.contains("telemetry.contoso.io"), "bare host should be captured, got \(r.domains)")
    }

    func testResourceScanner_binaryPlist() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcres-\(UUID().uuidString)")
        let res = tmp.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dict: [String: Any] = ["endpoint": "https://plist.example.org/x"]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .binary, options: 0)
        try plistData.write(to: res.appendingPathComponent("Settings.plist"))

        let r = EmbeddedResourceScanner.scan(root: tmp)
        XCTAssertTrue(r.urls.contains("https://plist.example.org/x"),
                      "binary-plist string should be walked, got \(r.urls)")
    }

    func testResourceScanner_ignoresNonConfigExtensions() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcres-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A .png "file" containing a URL must be ignored (not a text config).
        try Data("https://ignored.example.com/x".utf8)
            .write(to: tmp.appendingPathComponent("image.png"))
        let r = EmbeddedResourceScanner.scan(root: tmp)
        XCTAssertTrue(r.urls.isEmpty, "non-config extensions must be skipped, got \(r.urls)")
    }
}
