import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Covers the static-report cache that lets a single-app open reuse the work a
/// "Scan all apps" pass already did, instead of re-running the analysis.
final class StaticReportCacheTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("srcache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Build a minimal but realistic `.app` on disk: `Contents/Info.plist`
    /// (with the keys the fingerprint reads) plus a `Contents/MacOS/<exec>`.
    private func makeAppBundle(version: String, execBytes: Data) throws -> URL {
        let app = tmp.appendingPathComponent("Sample.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleExecutable": "Sample",
            "CFBundleIdentifier": "com.example.sample",
            "CFBundleVersion": version,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try execBytes.write(to: macOS.appendingPathComponent("Sample"))
        return app
    }

    func testStoreThenLoadReturnsTheSameReport() throws {
        let cache = StaticReportCache(baseURL: tmp.appendingPathComponent("cache"))
        let app = try makeAppBundle(version: "1.0", execBytes: Data([0x01, 0x02, 0x03]))
        let report = Fix.report(bundle: Fix.bundle(bundleID: "com.example.sample"))

        XCTAssertNil(cache.load(for: app, auditorVersion: "9.9.9"),
                     "cold cache should miss")

        cache.store(report, for: app, auditorVersion: "9.9.9")
        let loaded = cache.load(for: app, auditorVersion: "9.9.9")

        // The cache persists through JSON with second-granularity dates (same
        // as `RunStore`), so compare against that same normalisation rather than
        // the in-memory original, whose `analyzedAt` carries sub-second slop.
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let expected = try dec.decode(StaticReport.self, from: enc.encode(report))
        XCTAssertEqual(loaded, expected, "a stored report round-trips on a hit")
    }

    func testChangedExecutableInvalidatesEntry() throws {
        let cache = StaticReportCache(baseURL: tmp.appendingPathComponent("cache"))
        let app = try makeAppBundle(version: "1.0", execBytes: Data([0x01, 0x02, 0x03]))
        cache.store(Fix.report(), for: app, auditorVersion: "9.9.9")
        XCTAssertNotNil(cache.load(for: app, auditorVersion: "9.9.9"))

        // Simulate an app update: the main executable's bytes (size) change.
        try Data([0x09, 0x09, 0x09, 0x09, 0x09])
            .write(to: app.appendingPathComponent("Contents/MacOS/Sample"))

        XCTAssertNil(cache.load(for: app, auditorVersion: "9.9.9"),
                     "a changed binary must invalidate the cached report")
    }

    func testNewerAuditorVersionInvalidatesEntry() throws {
        let cache = StaticReportCache(baseURL: tmp.appendingPathComponent("cache"))
        let app = try makeAppBundle(version: "1.0", execBytes: Data([0x01, 0x02, 0x03]))
        // The auditor version is an injected parameter, not read from the app's
        // real MARKETING_VERSION, so any two distinct strings prove the point —
        // these are intentionally not real version numbers and never need to
        // track a release.
        cache.store(Fix.report(), for: app, auditorVersion: "older-auditor")

        XCTAssertNotNil(cache.load(for: app, auditorVersion: "older-auditor"))
        XCTAssertNil(cache.load(for: app, auditorVersion: "newer-auditor"),
                     "a report from an older auditor build must not be served to a newer one")
    }

    func testCountAndClear() throws {
        let cache = StaticReportCache(baseURL: tmp.appendingPathComponent("cache"))
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.sizeBytes, 0)

        let a = try makeAppBundle(version: "1.0", execBytes: Data([0x01, 0x02, 0x03]))
        cache.store(Fix.report(), for: a, auditorVersion: "1.0.0")
        XCTAssertEqual(cache.count, 1, "storing one report yields one cached entry")
        XCTAssertGreaterThan(cache.sizeBytes, 0)

        cache.clear()
        XCTAssertEqual(cache.count, 0, "clear() removes every cached report")
        XCTAssertNil(cache.load(for: a, auditorVersion: "1.0.0"))
    }

    func testUnreadableBundleIsAMissNotACrash() {
        let cache = StaticReportCache(baseURL: tmp.appendingPathComponent("cache"))
        let missing = tmp.appendingPathComponent("DoesNotExist.app", isDirectory: true)
        // No fingerprint can be computed → store is a no-op, load is a miss.
        cache.store(Fix.report(), for: missing, auditorVersion: "1.0.0")
        XCTAssertNil(cache.load(for: missing, auditorVersion: "1.0.0"))
    }
}
