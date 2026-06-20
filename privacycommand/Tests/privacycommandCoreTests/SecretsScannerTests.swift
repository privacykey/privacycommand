import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

final class SecretsScannerTests: XCTestCase {

    /// A PEM header in the middle of a blob is found, and its byteOffset
    /// points at the start of the printable run (right after the padding).
    func testPEMPrivateKeyDetectedWithByteOffset() throws {
        var bytes = [UInt8](repeating: 0, count: 100)            // NUL padding
        bytes.append(contentsOf: Array("-----BEGIN RSA PRIVATE KEY-----".utf8))
        bytes.append(0)
        let result = SecretsScanner.scan(data: bytes)
        let f = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(f.kind, .pemPrivateKey)
        XCTAssertEqual(f.byteOffset, 100)
        // scan(data:) has no file context, so sourceFile is left nil for
        // the executable-level caller to fill in.
        XCTAssertNil(f.sourceFile)
    }

    /// scan(executable:) tags findings with the file's name and a real offset.
    func testScanExecutableSetsSourceFileAndOffset() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pc-secrets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exec = dir.appendingPathComponent("FakeBinary")

        var blob = Data(count: 8)                                // NUL padding
        blob.append("AKIA3X7QPL9ZK2WMN4VT".data(using: .ascii)!) // isolated 20-char run
        blob.append(0)
        try blob.write(to: exec)

        let result = SecretsScanner.scan(executable: exec)
        let f = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(f.kind, .awsAccessKey)
        XCTAssertEqual(f.sourceFile, "FakeBinary")
        XCTAssertEqual(f.byteOffset, 8)
    }

    /// Identity is still kind:masked, so two findings of the same secret at
    /// different locations don't break SwiftUI ForEach / report dedup.
    func testIdentityIgnoresLocation() {
        let a = SecretFinding(kind: .pemPrivateKey, vendor: "v", masked: "AAAA…BBBB",
                              rawLength: 40, confidence: .high, kbArticleID: nil,
                              sourceFile: "Contents/MacOS/X", byteOffset: 10)
        let b = SecretFinding(kind: .pemPrivateKey, vendor: "v", masked: "AAAA…BBBB",
                              rawLength: 40, confidence: .high, kbArticleID: nil,
                              sourceFile: "Contents/MacOS/Y", byteOffset: 99)
        XCTAssertEqual(a.id, b.id)
    }

    /// Old reports (no location keys) still decode — fields default to nil.
    func testBackwardCompatibleDecodingWithoutLocation() throws {
        let legacy = """
        {"kind":"PEM private key","vendor":"PEM private key","masked":"----…----","rawLength":30,"confidence":"high","kbArticleID":"secret-private-key"}
        """.data(using: .utf8)!
        let f = try JSONDecoder().decode(SecretFinding.self, from: legacy)
        XCTAssertEqual(f.kind, .pemPrivateKey)
        XCTAssertNil(f.sourceFile)
        XCTAssertNil(f.byteOffset)
    }

    /// Multiple files: each finding is attributed to its file, and a secret
    /// present in two files is reported once, against the FIRST file passed.
    func testScanFilesAttributesAndDeduplicates() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pc-secrets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let awsKey = "AKIA3X7QPL9ZK2WMN4VT"              // isolated 20-char run
        let ghToken = "ghp_aB3xK9mZ2qWvL7pR4tY1nC8sD6fG0hJ5kE2Q"

        var a = Data(count: 4)
        a.append(awsKey.data(using: .ascii)!); a.append(0)
        let aURL = dir.appendingPathComponent("A"); try a.write(to: aURL)

        var b = Data(count: 4)
        b.append(awsKey.data(using: .ascii)!); b.append(0)   // same AWS key…
        b.append(ghToken.data(using: .ascii)!); b.append(0)  // …plus a GitHub token
        let bURL = dir.appendingPathComponent("B"); try b.write(to: bURL)

        let result = SecretsScanner.scan(files: [(aURL, "A"), (bURL, "B")])
        XCTAssertEqual(result.findings.count, 2)             // AWS once + GitHub once
        XCTAssertEqual(result.findings.first { $0.kind == .awsAccessKey }?.sourceFile, "A")
        XCTAssertEqual(result.findings.first { $0.kind == .githubToken }?.sourceFile, "B")
    }
}
