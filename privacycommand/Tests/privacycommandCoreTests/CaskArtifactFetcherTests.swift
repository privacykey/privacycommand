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
        // .dmg / .zip can be previewed; everything else is skipped (no download).
        XCTAssertTrue(CaskArtifactFetcher.Format.dmg.isSupported)
        XCTAssertTrue(CaskArtifactFetcher.Format.zip.isSupported)
        XCTAssertFalse(CaskArtifactFetcher.Format.pkg.isSupported)
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
}
