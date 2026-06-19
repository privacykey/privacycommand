import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Tests for the import-table-based forensic summary that replaced the
/// brittle "parse objdump text" path. The mapping / narrative logic is
/// hermetic (synthetic inputs); two tests run against real system binaries
/// and are skipped if those binaries aren't present.
final class BinaryCapabilityAnalyzerTests: XCTestCase {

    // MARK: - MachOInspector.importedSymbols (native symbol-table parse)

    func testImportedSymbolsReadsSystemBinary() throws {
        let url = URL(fileURLWithPath: "/bin/ls")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let imports = MachOInspector.importedSymbols(of: url)
        XCTAssertFalse(imports.isEmpty, "ls should import libc functions")
        // ls links libSystem and calls into it. Underscore-prefixed (Mach-O).
        let names = Set(imports)
        XCTAssertTrue(names.contains(where: { $0.hasPrefix("_") }),
                      "imported symbols keep their leading underscore")
        // A couple of ubiquitous libc imports ls is guaranteed to use.
        XCTAssertTrue(names.contains("_printf") || names.contains("_fwrite")
                      || names.contains("_write") || names.contains("_exit"),
                      "expected a common libc import, got: \(imports.prefix(20))")
    }

    func testImportedSymbolsRespectsLimit() throws {
        let url = URL(fileURLWithPath: "/usr/lib/dyld")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let capped = MachOInspector.importedSymbols(of: url, limit: 5)
        XCTAssertLessThanOrEqual(capped.count, 5)
    }

    func testImportedSymbolsOnNonMachOIsEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-macho-\(UUID().uuidString).txt")
        try "hello world, not a binary".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(MachOInspector.importedSymbols(of: tmp), [])
    }

    // MARK: - Linked-library → capability mapping (hermetic)

    func testLinkedCapabilitiesMapsKnownFrameworks() {
        let dylibs = [
            "/System/Library/Frameworks/Security.framework/Versions/A/Security",
            "/System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork",
            "/System/Library/Frameworks/AVFoundation.framework/Versions/A/AVFoundation",
            "/System/Library/Frameworks/CoreLocation.framework/Versions/A/CoreLocation",
            "/usr/lib/libSystem.B.dylib",   // unmapped — should be ignored
        ]
        let caps = BinaryCapabilityAnalyzer.linkedCapabilities(for: dylibs)
        let titles = Set(caps.map(\.title))
        XCTAssertTrue(titles.contains("Cryptography & keychain"))
        XCTAssertTrue(titles.contains("Networking"))
        XCTAssertTrue(titles.contains("Camera / microphone"))
        XCTAssertTrue(titles.contains("Location"))
        // Privacy-sensitive capabilities sort first.
        XCTAssertTrue(caps.first?.privacySensitive == true)
    }

    func testPrivacySensitivityIsReservedForHighStakesFrameworks() {
        // Camera/mic, location, contacts, screen recording etc. ARE
        // privacy-sensitive. CoreMedia (codecs) and MediaPlayer (now-playing)
        // and Carbon (legacy plumbing) are NOT — flagging them caused
        // false-positive alarms on playback-only and menu-bar apps.
        func cap(_ name: String, _ lib: String) -> BinaryCapabilityAnalyzer.LinkedCapability? {
            BinaryCapabilityAnalyzer.linkedCapabilities(for: [lib]).first
        }
        XCTAssertEqual(cap("avf", "/S/AVFoundation.framework/AVFoundation")?.privacySensitive, true)
        XCTAssertEqual(cap("cl", "/S/CoreLocation.framework/CoreLocation")?.privacySensitive, true)
        XCTAssertEqual(cap("sck", "/S/ScreenCaptureKit.framework/ScreenCaptureKit")?.privacySensitive, true)
        XCTAssertEqual(cap("cm", "/S/CoreMedia.framework/CoreMedia")?.privacySensitive, false)
        XCTAssertEqual(cap("mp", "/S/MediaPlayer.framework/MediaPlayer")?.privacySensitive, false)
        XCTAssertEqual(cap("carbon", "/S/Carbon.framework/Carbon")?.privacySensitive, false)
    }

    func testLinkedCapabilitiesMergesEvidence() {
        // Photos + PhotosUI both map to the "Photo library" capability and
        // should merge into one entry carrying both as evidence.
        let dylibs = [
            "/System/Library/Frameworks/Photos.framework/Versions/A/Photos",
            "/System/Library/Frameworks/PhotosUI.framework/Versions/A/PhotosUI",
        ]
        let caps = BinaryCapabilityAnalyzer.linkedCapabilities(for: dylibs)
        let photo = caps.first { $0.title == "Photo library" }
        XCTAssertNotNil(photo)
        XCTAssertEqual(Set(photo?.evidence ?? []), ["Photos", "PhotosUI"])
    }

    // MARK: - Narrative assembly (hermetic)

    func testNarrativeNeverEmptyAndExplainsEncryptedBinaries() {
        var lc = MachOInspector.LoadCommandsSummary.empty
        lc.hasEncryptedSegment = true
        lc.dylibs = ["/System/Library/Frameworks/Security.framework/Versions/A/Security"]
        let report = BinaryCapabilityAnalyzer.analyse(
            architectures: ["arm64"],
            loadCommands: lc,
            importedSymbols: ["_SecItemCopyMatching", "_connect"],
            strings: .init())
        XCTAssertFalse(report.narrative.isEmpty)
        XCTAssertTrue(report.narrative.contains("arm64"))
        XCTAssertTrue(report.narrative.lowercased().contains("encrypt"),
                      "encrypted binaries must say so:\n\(report.narrative)")
        // The keychain import is classified and surfaced.
        XCTAssertTrue(report.importedCalls.contains { $0.symbol == "_SecItemCopyMatching" })
    }

    func testEmptyInputStillProducesAHonestNarrative() {
        let report = BinaryCapabilityAnalyzer.analyse(
            architectures: [],
            loadCommands: .empty,
            importedSymbols: [],
            strings: .init())
        XCTAssertFalse(report.narrative.isEmpty)
        XCTAssertTrue(report.narrative.contains("not be read")
                      || report.narrative.lowercased().contains("unknown architecture"))
    }

    // MARK: - End-to-end on a real binary

    func testAnalyseRealBinaryProducesCapabilities() throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app/Contents/MacOS/Calculator")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        let report = BinaryCapabilityAnalyzer.analyse(executable: url)
        XCTAssertFalse(report.narrative.isEmpty)
        XCTAssertGreaterThan(report.linkedLibraryCount, 0)
        XCTAssertGreaterThan(report.importedSymbolCount, 0)
        XCTAssertFalse(report.architectures.isEmpty)
        // Calculator links security/networking-ish frameworks; at minimum it
        // should surface *some* capability from its large link list.
        XCTAssertFalse(report.linkedCapabilities.isEmpty,
                       "expected at least one linked capability")
    }
}
