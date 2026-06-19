import XCTest
import Foundation
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Resolution of the three bundle shapes (standard macOS, flat iOS, and
/// wrapped iOS-on-Mac) plus the failure taxonomy that lets batch runs explain
/// — rather than silently drop — apps they couldn't analyse.
final class WrappedBundleTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pc-wrapped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    // MARK: - Fixture builders

    private func writePlist(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
    }

    private func writeExecutable(at url: URL) throws {
        // resolve() only needs the file to exist; MachOInspector tolerates a
        // non-Mach-O (architectures come back empty).
        try Data([0xCA, 0xFE, 0xBA, 0xBE]).write(to: url)
    }

    /// A flat (iOS-style) bundle: Info.plist + executable directly at the root.
    @discardableResult
    private func makeFlatBundle(named name: String, in parent: URL,
                               bundleID: String = "com.example.ipadapp",
                               exec: String = "iPadApp") throws -> URL {
        let app = parent.appendingPathComponent("\(name).app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writePlist(["CFBundleIdentifier": bundleID,
                        "CFBundleName": name,
                        "CFBundleExecutable": exec,
                        "CFBundleShortVersionString": "2.5"],
                       to: app.appendingPathComponent("Info.plist"))
        try writeExecutable(at: app.appendingPathComponent(exec))
        return app
    }

    /// A standard macOS bundle: Contents/Info.plist + Contents/MacOS/<exec>.
    private func makeStandardBundle(named name: String, in parent: URL) throws -> URL {
        let app = parent.appendingPathComponent("\(name).app", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try writePlist(["CFBundleIdentifier": "com.example.mac",
                        "CFBundleName": name,
                        "CFBundleExecutable": name],
                       to: app.appendingPathComponent("Contents/Info.plist"))
        try writeExecutable(at: macos.appendingPathComponent(name))
        return app
    }

    // MARK: - Layout resolution

    func testStandardBundleResolvesAsMacOS() throws {
        let app = try makeStandardBundle(named: "MacApp", in: tmp)
        let bundle = try AppBundle.resolve(bundleURL: app)
        XCTAssertEqual(bundle.layout, .standard)
        XCTAssertEqual(bundle.platform, .macOS)
        XCTAssertEqual(bundle.bundleID, "com.example.mac")
        XCTAssertEqual(bundle.executableURL.lastPathComponent, "MacApp")
        XCTAssertTrue(bundle.infoPlistURL.path.contains("/Contents/"))
    }

    func testFlatBundleResolvesAsIOS() throws {
        let app = try makeFlatBundle(named: "FlatApp", in: tmp)
        let bundle = try AppBundle.resolve(bundleURL: app)
        XCTAssertEqual(bundle.layout, .flat)
        XCTAssertEqual(bundle.platform, .iOS)
        XCTAssertEqual(bundle.bundleID, "com.example.ipadapp")
        XCTAssertEqual(bundle.bundleVersion, "2.5")
        XCTAssertEqual(bundle.executableURL.lastPathComponent, "iPadApp")
        // Flat layout: Info.plist + executable live at the bundle root.
        XCTAssertFalse(bundle.infoPlistURL.path.contains("/Contents/"))
        XCTAssertEqual(bundle.executableURL.deletingLastPathComponent().path, app.path)
    }

    func testWrappedIOSBundleRedirectsToInnerViaSymlink() throws {
        // Outer.app/Wrapper/WrappedApp.app (flat) + WrappedBundle symlink.
        let outer = tmp.appendingPathComponent("WrappedApp.app", isDirectory: true)
        let wrapper = outer.appendingPathComponent("Wrapper", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        let inner = try makeFlatBundle(named: "WrappedApp", in: wrapper,
                                       bundleID: "com.example.wrapped", exec: "WrappedApp")
        try FileManager.default.createSymbolicLink(
            atPath: outer.appendingPathComponent("WrappedBundle").path,
            withDestinationPath: "Wrapper/WrappedApp.app")

        let bundle = try AppBundle.resolve(bundleURL: outer)
        XCTAssertEqual(bundle.layout, .flat)
        XCTAssertEqual(bundle.platform, .iOS)
        XCTAssertEqual(bundle.bundleID, "com.example.wrapped")
        // Resolved to the inner bundle, not the outer shell. Normalise the
        // /var ↔ /private/var symlink so the comparison is path-form agnostic.
        XCTAssertEqual(bundle.url.resolvingSymlinksInPath().path,
                       inner.resolvingSymlinksInPath().path)
    }

    func testWrappedFallsBackToWrapperDirWithoutSymlink() throws {
        let outer = tmp.appendingPathComponent("NoLink.app", isDirectory: true)
        let wrapper = outer.appendingPathComponent("Wrapper", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        let inner = try makeFlatBundle(named: "NoLink", in: wrapper, bundleID: "com.example.nolink")

        let bundle = try AppBundle.resolve(bundleURL: outer)
        XCTAssertEqual(bundle.platform, .iOS)
        XCTAssertEqual(bundle.url.resolvingSymlinksInPath().path,
                       inner.resolvingSymlinksInPath().path)
    }

    // MARK: - Layout-aware location helpers

    func testLocationHelpersFollowLayout() throws {
        let flat = try AppBundle.resolve(bundleURL: try makeFlatBundle(named: "Loc", in: tmp))
        XCTAssertEqual(flat.contentsURL.path, flat.url.path)
        XCTAssertEqual(flat.resourcesURL.path, flat.url.path)
        XCTAssertEqual(flat.masReceiptURL.path, flat.url.appendingPathComponent("_MASReceipt/receipt").path)

        let std = try AppBundle.resolve(bundleURL: try makeStandardBundle(named: "Std", in: tmp))
        XCTAssertTrue(std.frameworksURL.path.hasSuffix("/Contents/Frameworks"))
        XCTAssertTrue(std.resourcesURL.path.hasSuffix("/Contents/Resources"))
    }

    // MARK: - Failure paths

    func testMissingInfoPlistThrowsUnreadable() throws {
        let app = tmp.appendingPathComponent("Empty.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AppBundle.resolve(bundleURL: app)) { error in
            XCTAssertEqual(ScanFailureKind.classify(error), .unreadableMetadata)
        }
    }

    func testNonexistentPathThrowsNotFound() {
        let missing = tmp.appendingPathComponent("Ghost.app")
        XCTAssertThrowsError(try AppBundle.resolve(bundleURL: missing)) { error in
            XCTAssertEqual(ScanFailureKind.classify(error), .notFound)
        }
    }

    func testNonAppPathThrowsNotAnApp() throws {
        let file = tmp.appendingPathComponent("notanapp.txt")
        try Data("hi".utf8).write(to: file)
        XCTAssertThrowsError(try AppBundle.resolve(bundleURL: file)) { error in
            XCTAssertEqual(ScanFailureKind.classify(error), .notAnApp)
        }
    }

    // MARK: - ScanFailureKind classification

    func testClassifyMapsAppBundleErrors() {
        let u = URL(fileURLWithPath: "/x.app")
        XCTAssertEqual(ScanFailureKind.classify(AppBundleError.notFound(u)), .notFound)
        XCTAssertEqual(ScanFailureKind.classify(AppBundleError.notAnApp(u)), .notAnApp)
        XCTAssertEqual(ScanFailureKind.classify(AppBundleError.unreadablePlist(u)), .unreadableMetadata)
        XCTAssertEqual(ScanFailureKind.classify(AppBundleError.executableMissing(u)), .executableMissing)
        XCTAssertEqual(ScanFailureKind.classify(AppBundleError.permissionDenied(u)), .permissionDenied)
    }

    func testClassifyMapsCocoaErrors() {
        XCTAssertEqual(
            ScanFailureKind.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)),
            .permissionDenied)
        XCTAssertEqual(
            ScanFailureKind.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)),
            .notFound)
        XCTAssertEqual(ScanFailureKind.classify(NSError(domain: "weird", code: 1)), .unknown)
    }
}
