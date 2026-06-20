import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Wave 2 — capability-inference false-positive fixes:
/// no "permanent undeclared" categories, no double-firing bluetooth, no
/// "declared but unused" for undetectable categories, no risk score on Apple's
/// own apps, and word-bounded (not substring) symbol matching.
final class CapabilityInferenceTests: XCTestCase {

    private let analyzer = StaticAnalyzer()

    private func infer(symbols: Set<String> = [],
                       declared: [PrivacyKey] = [],
                       frameworks: [FrameworkRef] = [],
                       entitlements: Entitlements = Fix.entitlements()) -> [InferredCapability] {
        var scan = BinaryStringScanner.Result()
        scan.foundFrameworkSymbols = symbols
        return analyzer.inferCapabilities(entitlements: entitlements, declaredKeys: declared,
                                          scan: scan, frameworks: frameworks)
    }
    private func key(_ raw: String, _ cat: PrivacyCategory) -> PrivacyKey {
        PrivacyKey(rawKey: raw, category: cat, humanLabel: raw, purposeString: "Because reasons")
    }

    // MARK: - The removed mislabels (HIGH false positives)

    func testRemovedMislabelMappingsInferNothing() {
        // Screen-capture, accessibility and generic networking were mislabelled
        // as desktop-folder / automation / local-network. They now infer nothing.
        let caps = infer(symbols: ["CGDisplayStream", "ScreenCaptureKit", "AXIsProcessTrusted", "NWConnection"])
        XCTAssertTrue(caps.isEmpty, "removed mislabels must not produce capabilities, got \(caps.map(\.category.rawValue))")
    }

    // MARK: - Bluetooth no longer double-fires

    func testBluetoothPeripheralKeyWithCentralManagerDoesNotDoubleFire() {
        let caps = infer(symbols: ["CBCentralManager"],
                         declared: [key("NSBluetoothPeripheralUsageDescription", .bluetooth)])
        XCTAssertFalse(caps.contains { $0.inferredButNotDeclared },
                       "a declared BLE app must not be 'used but not declared'")
        XCTAssertFalse(caps.contains { $0.declaredButNotJustified },
                       "a BLE app that uses CoreBluetooth must not be 'declared but unused'")
    }

    // MARK: - declaredButNotJustified only for detectable categories

    func testUndetectableCategoryNotFlaggedUnjustified() {
        // We have no way to detect Motion usage, so declaring it must NOT read
        // as "declared but unused".
        let caps = infer(declared: [key("NSMotionUsageDescription", .motion)])
        XCTAssertFalse(caps.contains { $0.declaredButNotJustified },
                       "motion is not coverable — declaring it isn't an 'unused' finding")
    }

    func testDetectableButTrulyUnusedStillFlagged() {
        // Camera IS detectable; declaring it with no camera API present is a
        // real 'declared but unused' signal — we must keep that.
        let caps = infer(declared: [key("NSCameraUsageDescription", .camera)])
        XCTAssertTrue(caps.contains { $0.category == .camera && $0.declaredButNotJustified },
                      "declared-but-unused camera is a legitimate finding")
    }

    // MARK: - Genuine "used but not declared" preserved

    func testUndeclaredCameraUseStillFlagged() {
        let caps = infer(symbols: ["AVCaptureDevice"])
        XCTAssertTrue(caps.contains { $0.category == .camera && $0.inferredButNotDeclared },
                      "camera API used with no usage key is a real undeclared-API finding")
    }

    // MARK: - RiskScorer skips Apple platform binaries

    func testRiskScorerIgnoresInferredCapsForApplePlatformBinary() {
        let cap = InferredCapability(category: .camera, confidence: .high, evidence: ["x"],
                                     declaredButNotJustified: false, inferredButNotDeclared: true)
        let apple = Fix.report(codeSigning: Fix.signing(platform: true), inferredCapabilities: [cap])
        XCTAssertFalse(RiskScorer().score(staticReport: apple).contributors.contains { $0.category == "undeclared-api" },
                       "Apple platform binaries must not be scored for undeclared APIs")
        // …but a normal third-party app with the same cap still is.
        let thirdParty = Fix.report(codeSigning: Fix.signing(platform: false), inferredCapabilities: [cap])
        XCTAssertTrue(RiskScorer().score(staticReport: thirdParty).contributors.contains { $0.category == "undeclared-api" },
                      "third-party apps must still be scored")
    }

    // MARK: - Symbol matching is word-bounded, not substring

    func testSymbolMatchingIsWordBounded() throws {
        let dir = FileManager.default.temporaryDirectory
        let longer = dir.appendingPathComponent("wb-long-\(UUID().uuidString).bin")
        let exact  = dir.appendingPathComponent("wb-exact-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: longer); try? FileManager.default.removeItem(at: exact) }

        try Data("AVCaptureDeviceInput\u{0}padding".utf8).write(to: longer)
        try Data("AVCaptureDevice\u{0}padding".utf8).write(to: exact)

        let rLong = BinaryStringScanner.scan(executable: longer, symbols: ["AVCaptureDevice"])
        XCTAssertFalse(rLong.foundFrameworkSymbols.contains("AVCaptureDevice"),
                       "AVCaptureDeviceInput must NOT match the token AVCaptureDevice")
        let rExact = BinaryStringScanner.scan(executable: exact, symbols: ["AVCaptureDevice"])
        XCTAssertTrue(rExact.foundFrameworkSymbols.contains("AVCaptureDevice"),
                      "the exact symbol must still match")

        // Regression guard: the dominant Mach-O symbol-table form is the
        // underscore-prefixed ObjC class symbol. It MUST match (word boundary
        // must not treat the leading "_" as part of an identifier).
        let mangled = dir.appendingPathComponent("wb-mangled-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: mangled) }
        try Data("_OBJC_CLASS_$_AVCaptureDevice\u{0}padding".utf8).write(to: mangled)
        let rMangled = BinaryStringScanner.scan(executable: mangled, symbols: ["AVCaptureDevice"])
        XCTAssertTrue(rMangled.foundFrameworkSymbols.contains("AVCaptureDevice"),
                      "_OBJC_CLASS_$_AVCaptureDevice must match the token AVCaptureDevice")
    }
}
