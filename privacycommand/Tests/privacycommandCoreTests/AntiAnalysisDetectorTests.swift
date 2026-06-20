import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Wave 3 — anti-analysis: resurrect the dead ptrace detector, keep sysctl
/// precise, MAS-gate encrypted segments, corroboration-gate stripped, and
/// raise confidence only when signals combine.
final class AntiAnalysisDetectorTests: XCTestCase {

    private typealias Kind = AntiAnalysisDetector.Result.Finding.Kind
    private typealias Conf = AntiAnalysisDetector.Result.Finding.Confidence

    private func f(symbols: Set<String> = [], encrypted: Bool = false,
                   stripped: Bool = false, mas: Bool = false) -> [AntiAnalysisDetector.Result.Finding] {
        AntiAnalysisDetector.findings(symbols: symbols, hasEncryptedSegment: encrypted,
                                      isStripped: stripped, isMASApp: mas)
    }
    private func kinds(_ fs: [AntiAnalysisDetector.Result.Finding]) -> Set<Kind> { Set(fs.map(\.kind)) }
    private func conf(_ fs: [AntiAnalysisDetector.Result.Finding], _ k: Kind) -> Conf? {
        fs.first { $0.kind == k }?.confidence
    }

    // MARK: - Dead detector resurrected

    func testPtraceDetectorFiresOnImportedSymbol() {
        XCTAssertTrue(kinds(f(symbols: ["_ptrace"])).contains(.ptraceDenyAttach))
        XCTAssertTrue(kinds(f(symbols: ["ptrace"])).contains(.ptraceDenyAttach))
        XCTAssertEqual(conf(f(symbols: ["_ptrace"]), .ptraceDenyAttach), .medium, "a lone deliberate signal stays medium")
    }

    func testScanSymbolSetWiresPtraceEndToEnd() throws {
        XCTAssertTrue(AntiAnalysisDetector.scanSymbols.contains("_ptrace"),
                      "scanSymbols must request _ptrace so the scan captures it")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aa-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("_ptrace\u{0}padding".utf8).write(to: url)
        let scan = BinaryStringScanner.scan(executable: url, symbols: AntiAnalysisDetector.scanSymbols)
        XCTAssertTrue(scan.foundFrameworkSymbols.contains("_ptrace"),
                      "the (now word-bounded) scan must capture the _ptrace token")
        XCTAssertTrue(kinds(f(symbols: scan.foundFrameworkSymbols)).contains(.ptraceDenyAttach))
    }

    // MARK: - Combination gating

    func testTwoDeliberateSignalsCorroborateToHigh() {
        let fs = f(symbols: ["_ptrace", "DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(conf(fs, .ptraceDenyAttach), .high)
        XCTAssertEqual(conf(fs, .dyldInsertReference), .high)
    }

    // MARK: - Stripped is corroboration-gated

    func testLoneStrippedProducesNothing() {
        XCTAssertTrue(f(stripped: true).isEmpty, "a normal stripped release binary alone is not a finding")
    }
    func testStrippedSurfacedWhenCorroborated() {
        XCTAssertTrue(kinds(f(symbols: ["_ptrace"], stripped: true)).contains(.stripped))
    }

    // MARK: - Encrypted-segment MAS gate

    func testEncryptedSegmentOnMASAppIsLowAndExpected() {
        let fs = f(encrypted: true, mas: true)
        XCTAssertEqual(conf(fs, .encryptedSegment), .low, "FairPlay encryption is expected for App Store apps")
        XCTAssertEqual(kinds(fs), [.encryptedSegment], "a clean MAS app shows only the expected, low note")
    }
    func testEncryptedSegmentOutsideAppStoreIsDeliberateMedium() {
        XCTAssertEqual(conf(f(encrypted: true, mas: false), .encryptedSegment), .medium)
    }
    func testEncryptedMASStaysLowEvenAlongsideDeliberateSignal() {
        let fs = f(symbols: ["_ptrace"], encrypted: true, mas: true)
        XCTAssertEqual(conf(fs, .encryptedSegment), .low, "App Store encryption never becomes a concern")
    }

    // MARK: - sysctl precision (no bare-sysctl false positive)

    func testSysctlRequiresBothDistinguishingConstants() {
        XCTAssertFalse(kinds(f(symbols: ["KERN_PROC"])).contains(.sysctlDebugCheck))
        XCTAssertFalse(kinds(f(symbols: ["_sysctl"])).contains(.sysctlDebugCheck), "bare sysctl is ubiquitous, not anti-debug")
        XCTAssertTrue(kinds(f(symbols: ["KERN_PROC", "P_TRACED"])).contains(.sysctlDebugCheck))
    }

    func testCleanBinaryHasNoFindings() {
        XCTAssertTrue(f(symbols: ["AVCaptureDevice", "CLLocationManager"]).isEmpty)
    }
}
