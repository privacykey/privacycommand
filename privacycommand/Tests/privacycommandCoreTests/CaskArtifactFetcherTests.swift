import XCTest
@testable import privacycommandCore

/// Covers the pure pieces of `CaskArtifactFetcher` — format detection and
/// cache-path parsing. The download/mount/extract lifecycle is integration-only
/// (needs brew + network) and is exercised manually.
final class CaskArtifactFetcherTests: XCTestCase {

    // MARK: - detectFormat

    func testDetectFormatKnownExtensions() {
        XCTAssertEqual(CaskArtifactFetcher.detectFormat(cacheExtension: "dmg"), .dmg)
        XCTAssertEqual(CaskArtifactFetcher.detectFormat(cacheExtension: "zip"), .zip)
        XCTAssertEqual(CaskArtifactFetcher.detectFormat(cacheExtension: "pkg"), .pkg)
        XCTAssertEqual(CaskArtifactFetcher.detectFormat(cacheExtension: "mpkg"), .pkg)
    }

    func testDetectFormatIsCaseInsensitive() {
        XCTAssertEqual(CaskArtifactFetcher.detectFormat(cacheExtension: "DMG"), .dmg)
        XCTAssertEqual(CaskArtifactFetcher.detectFormat(cacheExtension: "Zip"), .zip)
    }

    func testDetectFormatUnknownExtensions() {
        XCTAssertEqual(CaskArtifactFetcher.detectFormat(cacheExtension: "tar"), .unknown("tar"))
        XCTAssertEqual(CaskArtifactFetcher.detectFormat(cacheExtension: "xz"), .unknown("xz"))
        XCTAssertEqual(CaskArtifactFetcher.detectFormat(cacheExtension: ""), .unknown(""))
    }

    func testSupportedFormats() {
        // .dmg / .zip / .pkg can be previewed; anything else is skipped (no download).
        XCTAssertTrue(CaskArtifactFetcher.Format.dmg.isSupported)
        XCTAssertTrue(CaskArtifactFetcher.Format.zip.isSupported)
        XCTAssertTrue(CaskArtifactFetcher.Format.pkg.isSupported)
        XCTAssertFalse(CaskArtifactFetcher.Format.unknown("tar").isSupported)
    }

    // MARK: - parseCachePath

    func testParseCachePathTrimsAndKeepsExtension() {
        // Real `brew --cache --cask firefox` shape: one path, trailing newline.
        let stdout = "/Users/me/Library/Caches/Homebrew/downloads/abc--Firefox 152.0.1.dmg\n"
            .data(using: .utf8)!
        let url = CaskArtifactFetcher.parseCachePath(stdout)
        XCTAssertEqual(url?.pathExtension, "dmg")
        XCTAssertEqual(url?.lastPathComponent, "abc--Firefox 152.0.1.dmg")
    }

    func testParseCachePathZip() {
        let stdout = "/Users/me/Library/Caches/Homebrew/downloads/def--Claude.zip".data(using: .utf8)!
        XCTAssertEqual(CaskArtifactFetcher.parseCachePath(stdout)?.pathExtension, "zip")
    }

    func testParseCachePathEmptyIsNil() {
        XCTAssertNil(CaskArtifactFetcher.parseCachePath(Data()))
        XCTAssertNil(CaskArtifactFetcher.parseCachePath("   \n  ".data(using: .utf8)!))
    }

    // MARK: - Choosing the app

    func testPickAppPrefersInstalledNameThenNonUninstaller() {
        let app = URL(fileURLWithPath: "/m/Foo.app")
        let uninstaller = URL(fileURLWithPath: "/m/Uninstall Foo.app")
        let other = URL(fileURLWithPath: "/m/Bar.app")
        XCTAssertEqual(CaskArtifactFetcher.pickApp([uninstaller, other, app], preferredName: "foo.app"), app)
        XCTAssertEqual(CaskArtifactFetcher.pickApp([uninstaller, other], preferredName: "Foo.app"), other)
        XCTAssertEqual(CaskArtifactFetcher.pickApp([uninstaller], preferredName: nil), uninstaller)
        XCTAssertNil(CaskArtifactFetcher.pickApp([], preferredName: "Foo.app"))
    }

    func testAppBundlesSkipsSymlinksAndBundleInternals() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("appbundles-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        // An expanded .pkg: <component>.pkg/Payload/Applications/Foo.app
        let payload = root.appendingPathComponent("foo.pkg/Payload/Applications")
        try fm.createDirectory(at: payload.appendingPathComponent("Foo.app/Contents/Helpers/Inner.app"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Top.app"), withIntermediateDirectories: true)
        // A DMG-style alias to the host's /Applications must not be followed.
        try fm.createSymbolicLink(at: root.appendingPathComponent("Applications"),
                                  withDestinationURL: URL(fileURLWithPath: "/Applications"))

        let found = CaskArtifactFetcher.appBundles(in: root).map(\.lastPathComponent)
        XCTAssertEqual(found, ["Top.app", "Foo.app"])   // shallowest first, no Inner.app
    }

    /// Live end-to-end `.pkg`-in-`.dmg` check (downloads GPG Suite, ~30 MB).
    /// Opt in with `AUDITCTL_LIVE_FETCH=1`.
    func testLiveFetchExpandsPkgInsideDmg() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AUDITCTL_LIVE_FETCH"] == "1",
                          "set AUDITCTL_LIVE_FETCH=1 to run")
        let name = try await CaskArtifactFetcher.withDownloadedApp(
            token: "gpg-suite", preferredAppName: "GPG Keychain.app", pkgPath: "Install.pkg"
        ) { app in app.lastPathComponent }
        XCTAssertEqual(name, "GPG Keychain.app")
    }
}
