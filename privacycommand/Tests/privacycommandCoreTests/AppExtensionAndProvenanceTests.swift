import XCTest
import Foundation
@testable import privacycommandCore

/// Wave 14 — .appex extension-point enumeration + vendored launch-plist
/// provenance.
final class AppExtensionAndProvenanceTests: XCTestCase {

    // MARK: - extension-point classification

    func testHighPrivilegeExtensionPoints() {
        XCTAssertTrue(AppExtensionScanner.classify("com.apple.networkextension.packet-tunnel").highPrivilege)
        XCTAssertTrue(AppExtensionScanner.classify("com.apple.endpoint-security.client").highPrivilege)
        XCTAssertTrue(AppExtensionScanner.classify("com.apple.fileprovider-nonui").highPrivilege)
        XCTAssertEqual(AppExtensionScanner.classify("com.apple.networkextension.packet-tunnel").display,
                       "Network Extension (VPN packet tunnel)")
    }

    func testOrdinaryExtensionPointsAreNotHighPrivilege() {
        XCTAssertFalse(AppExtensionScanner.classify("com.apple.share-services").highPrivilege)
        XCTAssertFalse(AppExtensionScanner.classify("com.apple.widgetkit-extension").highPrivilege)
        XCTAssertEqual(AppExtensionScanner.classify("com.apple.share-services").display, "Share extension")
    }

    func testUnknownExtensionPointFallsBackToRaw() {
        let (display, high) = AppExtensionScanner.classify("com.acme.custom-thing")
        XCTAssertEqual(display, "com.acme.custom-thing")
        XCTAssertFalse(high)
        XCTAssertEqual(AppExtensionScanner.classify(nil).display, "Unknown extension")
    }

    func testParseExtractsPointAndIdentity() {
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.foo.app.NetExt",
            "CFBundleShortVersionString": "2.1",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.networkextension.app-proxy"]
        ]
        let ref = AppExtensionScanner.parse(infoPlist: info, url: URL(fileURLWithPath: "/x/NetExt.appex"))
        XCTAssertEqual(ref.bundleID, "com.foo.app.NetExt")
        XCTAssertEqual(ref.version, "2.1")
        XCTAssertEqual(ref.extensionPointID, "com.apple.networkextension.app-proxy")
        XCTAssertTrue(ref.isHighPrivilege)
    }

    // MARK: - directory scan

    func testScanPluginsDirReadsAppex() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcappex-\(UUID().uuidString)")
        let appexContents = tmp.appendingPathComponent("Share.appex/Contents")
        try FileManager.default.createDirectory(at: appexContents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.foo.share",
            "NSExtension": ["NSExtensionPointIdentifier": "com.apple.share-services"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: appexContents.appendingPathComponent("Info.plist"))

        let refs = AppExtensionScanner.scan(pluginsDir: tmp)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.extensionPointID, "com.apple.share-services")
        XCTAssertEqual(refs.first?.bundleID, "com.foo.share")
        XCTAssertEqual(refs.first?.isHighPrivilege, false)
    }

    func testScanMissingPluginsDirIsEmpty() {
        let refs = AppExtensionScanner.scan(pluginsDir:
            URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/PlugIns"))
        XCTAssertTrue(refs.isEmpty)
    }

    // MARK: - vendored launch-plist provenance

    func testAppOwnLaunchPlistHasNoVendorProvenance() {
        let main = URL(fileURLWithPath: "/Applications/Foo.app")
        let plist = URL(fileURLWithPath: "/Applications/Foo.app/Contents/Resources/io.foo.helper.plist")
        XCTAssertNil(EmbeddedAssetScanner.enclosingVendorBundle(of: plist, mainBundle: main))
    }

    func testVendoredLaunchPlistReportsSubBundle() {
        let main = URL(fileURLWithPath: "/Applications/Foo.app")
        let plist = URL(fileURLWithPath:
            "/Applications/Foo.app/Contents/Frameworks/Sparkle.framework/Resources/Autoupdate.plist")
        XCTAssertEqual(EmbeddedAssetScanner.enclosingVendorBundle(of: plist, mainBundle: main),
                       "Sparkle.framework")
    }

    func testNestedAppexLaunchPlistAttributedToAppex() {
        let main = URL(fileURLWithPath: "/Applications/Foo.app")
        let plist = URL(fileURLWithPath:
            "/Applications/Foo.app/Contents/PlugIns/Helper.appex/Contents/Resources/agent.plist")
        XCTAssertEqual(EmbeddedAssetScanner.enclosingVendorBundle(of: plist, mainBundle: main),
                       "Helper.appex")
    }
}
