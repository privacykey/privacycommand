import XCTest
import Foundation
@testable import privacycommandCore

/// Wave 13 — Mach-O packaging: LC_BUILD_VERSION, all-fat-slice load commands,
/// and runtime (Electron/Node/Catalyst/...) detection.
final class MachOPackagingTests: XCTestCase {

    // MARK: - byte helpers

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// A minimal 64-bit Mach-O slice with an LC_BUILD_VERSION (platform macOS)
    /// and, optionally, one LC_LOAD_DYLIB.
    private func thinSlice(cputype: UInt32, minos: UInt32, dylib: String?) -> [UInt8] {
        var lcs: [UInt8] = []
        var ncmds: UInt32 = 0
        // LC_BUILD_VERSION: cmd cmdsize platform minos sdk ntools  (24 bytes)
        lcs += le32(0x32) + le32(24) + le32(1) + le32(minos) + le32(0x000F0000) + le32(0)
        ncmds += 1
        if let d = dylib {
            var name = Array(d.utf8) + [0]
            while name.count % 8 != 0 { name.append(0) }
            let cmdsize = UInt32(24 + name.count)
            // cmd cmdsize | name_off timestamp current compat | name
            lcs += le32(0xC) + le32(cmdsize) + le32(24) + le32(0) + le32(0) + le32(0) + name
            ncmds += 1
        }
        var header: [UInt8] = []
        header += le32(0xFEEDFACF)            // mh_magic_64
        header += le32(cputype)
        header += le32(0)                     // cpusubtype
        header += le32(2)                     // MH_EXECUTE
        header += le32(ncmds)
        header += le32(UInt32(lcs.count))     // sizeofcmds
        header += le32(0)                     // flags
        header += le32(0)                     // reserved
        return header + lcs
    }

    private func writeTemp(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcmacho-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - LC_BUILD_VERSION (thin)

    func testThinBuildVersionParsed() throws {
        let url = try writeTemp(thinSlice(cputype: 0x0100000C, minos: 0x000E0000, dylib: nil)) // arm64, 14.0
        defer { try? FileManager.default.removeItem(at: url) }
        let lc = MachOInspector.loadCommands(of: url)
        XCTAssertEqual(lc.buildPlatform, "macOS")
        XCTAssertEqual(lc.minOSVersion, "14.0")
        XCTAssertEqual(lc.sdkVersion, "15.0")
        XCTAssertEqual(lc.sliceCount, 1)
    }

    // MARK: - all fat slices

    func testFatBinaryParsesBothSlices_andMergesSecondSliceDylib() throws {
        let s0 = thinSlice(cputype: 0x0100000C, minos: 0x000E0000, dylib: nil)                       // arm64 14.0
        let s1 = thinSlice(cputype: 0x01000007, minos: 0x000D0000, dylib: "@rpath/SecondSliceOnly.dylib") // x86_64 13.0
        let o0 = 8 + 40                 // header(8) + 2 fat_arch(20 each)
        let o1 = o0 + s0.count
        var fat: [UInt8] = []
        fat += be32(0xCAFEBABE) + be32(2)                                                  // fat_header
        fat += be32(0x0100000C) + be32(0) + be32(UInt32(o0)) + be32(UInt32(s0.count)) + be32(0)
        fat += be32(0x01000007) + be32(0) + be32(UInt32(o1)) + be32(UInt32(s1.count)) + be32(0)
        XCTAssertEqual(fat.count, o0, "fat header should end exactly at first slice offset")
        fat += s0 + s1

        let url = try writeTemp(fat)
        defer { try? FileManager.default.removeItem(at: url) }
        let lc = MachOInspector.loadCommands(of: url)
        XCTAssertEqual(lc.sliceCount, 2, "both fat slices should be parsed")
        XCTAssertTrue(lc.dylibs.contains("@rpath/SecondSliceOnly.dylib"),
                      "a dylib present only in the 2nd slice must surface, got \(lc.dylibs)")
        XCTAssertEqual(lc.minOSVersion, "14.0", "first slice's min OS wins")
        XCTAssertEqual(lc.buildPlatform, "macOS")
    }

    // MARK: - version / platform decode helpers

    func testDecodeVersionAndPlatform() {
        XCTAssertEqual(MachOInspector.decodeVersion(0x000E0500), "14.5")
        XCTAssertEqual(MachOInspector.decodeVersion(0x000E0501), "14.5.1")
        XCTAssertEqual(MachOInspector.platformName(1), "macOS")
        XCTAssertEqual(MachOInspector.platformName(6), "macCatalyst")
        XCTAssertNil(MachOInspector.platformName(99))
    }

    // MARK: - runtime detection

    func testElectronDetected() {
        let r = AppRuntimeDetector.detect(
            dylibs: ["@rpath/Electron Framework.framework/Electron Framework"],
            frameworkNames: ["Electron Framework.framework"],
            resourceNames: [])
        XCTAssertEqual(r.flavor, .electron)
        XCTAssertTrue(r.isSecuritySensitive)
    }

    func testElectronViaAsarResource() {
        let r = AppRuntimeDetector.detect(dylibs: [], frameworkNames: [], resourceNames: ["app.asar", "en.lproj"])
        XCTAssertEqual(r.flavor, .electron)
    }

    func testElectronWinsOverBareNode() {
        let r = AppRuntimeDetector.detect(
            dylibs: ["@rpath/Electron Framework.framework/Electron Framework", "@rpath/libnode.dylib"],
            frameworkNames: [], resourceNames: [])
        XCTAssertEqual(r.flavor, .electron, "Electron must take priority over the node it bundles")
    }

    func testBareNodeDetected() {
        let r = AppRuntimeDetector.detect(dylibs: ["@rpath/libnode.dylib"], frameworkNames: [], resourceNames: [])
        XCTAssertEqual(r.flavor, .node)
        XCTAssertTrue(r.isSecuritySensitive)
    }

    func testCatalystDetected() {
        let r = AppRuntimeDetector.detect(
            dylibs: ["/System/iOSSupport/System/Library/Frameworks/UIKit.framework/Versions/A/UIKit"],
            frameworkNames: [], resourceNames: [])
        XCTAssertEqual(r.flavor, .catalyst)
        XCTAssertFalse(r.isSecuritySensitive)
    }

    func testNativeWhenOnlyAppKit() {
        let r = AppRuntimeDetector.detect(
            dylibs: ["/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"],
            frameworkNames: [], resourceNames: [])
        XCTAssertEqual(r.flavor, .native)
        XCTAssertFalse(r.isSecuritySensitive)
    }

    func testJVMDetected() {
        let r = AppRuntimeDetector.detect(dylibs: ["@rpath/libjvm.dylib"], frameworkNames: [], resourceNames: [])
        XCTAssertEqual(r.flavor, .java)
    }
}
