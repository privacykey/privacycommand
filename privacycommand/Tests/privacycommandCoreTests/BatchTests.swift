import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Tests for batch mode: the app enumerator, the static-signal derivation,
/// the filter predicate, and CSV export. The enumerator/filter/export tests
/// are hermetic (temp dirs + synthetic results); one end-to-end test runs the
/// real analyzer over Calculator.app and is skipped if it isn't installed.
final class BatchTests: XCTestCase {

    // MARK: - Enumerator

    func testEnumeratorTreatsAppsAsLeavesAndRespectsDepth() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("batchtest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        // Layout:
        //   Top.app                         (depth 0, found)
        //   Top.app/Contents/Helpers/Inner.app   (inside a bundle — never found)
        //   Utilities/Deep.app              (depth 1, found within maxDepth 2)
        //   a/b/c/TooFar.app                (depth 3, NOT found at maxDepth 2)
        let topApp   = root.appendingPathComponent("Top.app", isDirectory: true)
        let innerApp = topApp.appendingPathComponent("Contents/Helpers/Inner.app", isDirectory: true)
        let deepApp  = root.appendingPathComponent("Utilities/Deep.app", isDirectory: true)
        let tooFar   = root.appendingPathComponent("a/b/c/TooFar.app", isDirectory: true)
        for dir in [topApp, innerApp, deepApp, tooFar] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let shallow = Set(InstalledAppEnumerator.appBundles(in: [root], maxDepth: 2)
            .map { $0.lastPathComponent })
        XCTAssertTrue(shallow.contains("Top.app"), "top-level app should be found")
        XCTAssertTrue(shallow.contains("Deep.app"), "app one folder deep should be found within maxDepth 2")
        XCTAssertFalse(shallow.contains("Inner.app"), "apps embedded inside a bundle must NOT be enumerated")
        XCTAssertFalse(shallow.contains("TooFar.app"), "apps below maxDepth must NOT be enumerated")

        let recursive = Set(InstalledAppEnumerator.appBundles(inFolder: root)
            .map { $0.lastPathComponent })
        XCTAssertTrue(recursive.contains("TooFar.app"), "folder pick is fully recursive")
        XCTAssertFalse(recursive.contains("Inner.app"), "even recursively, never descend into a bundle")
    }

    // MARK: - Filter

    func testFilterRequiresAllFlagsTierAndText() {
        let rotten = makeResult(name: "Sketchy", bundleID: "com.evil.sketchy",
                                tier: .high, score: 65,
                                flags: [.unsigned, .trackers, .noSandbox])
        let clean = makeResult(name: "Tidy", bundleID: "com.good.tidy",
                               tier: .low, score: 5, flags: [])

        // Required flags: subset test.
        var f = BatchFilter(requiredFlags: [.trackers])
        XCTAssertTrue(f.matches(rotten))
        XCTAssertFalse(f.matches(clean))

        f = BatchFilter(requiredFlags: [.trackers, .secrets])  // rotten lacks .secrets
        XCTAssertFalse(f.matches(rotten))

        // Minimum tier.
        f = BatchFilter(minTier: .high)
        XCTAssertTrue(f.matches(rotten))
        XCTAssertFalse(f.matches(clean))

        // Text search hits name, bundle ID, or path.
        f = BatchFilter(searchText: "evil")
        XCTAssertTrue(f.matches(rotten))
        XCTAssertFalse(f.matches(clean))

        XCTAssertFalse(BatchFilter().isActive)
        XCTAssertTrue(BatchFilter(minTier: .medium).isActive)
    }

    // MARK: - Export

    func testCSVHasHeaderAndEscapesSeparators() {
        let tricky = makeResult(name: "Comma, \"Quoted\" App", bundleID: "com.x.y",
                                tier: .medium, score: 40, flags: [.trackers])
        let csv = BatchReport.csv([tricky])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 2, "header + one row")
        XCTAssertTrue(lines[0].hasPrefix("App,Bundle ID,Version,Risk Tier,Risk Score,Signing"))
        XCTAssertTrue(lines[1].contains("\"Comma, \"\"Quoted\"\" App\""),
                      "fields with commas/quotes must be RFC-4180 escaped")
    }

    func testFailedResultIsFilterableNotDropped() {
        let bad = BatchAppResult.failed(url: URL(fileURLWithPath: "/tmp/Broken.app"),
                                        name: "Broken", error: "boom")
        XCTAssertTrue(bad.flags.contains(.analysisFailed))
        XCTAssertEqual(bad.analysisError, "boom")
        XCTAssertTrue(BatchFilter(requiredFlags: [.analysisFailed]).matches(bad))
    }

    // MARK: - Architecture / Rosetta

    func testArchClassificationCoversRosettaSunset() {
        XCTAssertEqual(ArchClass.classify(["arm64", "x86_64"]), .universal)
        XCTAssertEqual(ArchClass.classify(["x86_64", "arm64"]), .universal)
        XCTAssertEqual(ArchClass.classify(["arm64"]), .appleSilicon)
        XCTAssertEqual(ArchClass.classify(["arm64e"]), .appleSilicon)
        // The headline case: Intel-only → will break when Rosetta is removed.
        XCTAssertEqual(ArchClass.classify(["x86_64"]), .intel)
        XCTAssertEqual(ArchClass.classify(["i386"]), .other)
        XCTAssertEqual(ArchClass.classify([]), .other)
    }

    func testMinOSSortKeyOrdersByVersionNotString() {
        let nine   = makeResult(name: "Nine", bundleID: "a", tier: .low, score: 0, flags: [], minimumOS: "9.0")
        let ten    = makeResult(name: "Ten", bundleID: "b", tier: .low, score: 0, flags: [], minimumOS: "10.0")
        let modern = makeResult(name: "Modern", bundleID: "c", tier: .low, score: 0, flags: [], minimumOS: "14.2")
        let none   = makeResult(name: "None", bundleID: "d", tier: .low, score: 0, flags: [], minimumOS: nil)
        // String order would put "10.0" < "9.0"; the sort key must not.
        XCTAssertLessThan(nine.minOSSortKey, ten.minOSSortKey)
        XCTAssertLessThan(ten.minOSSortKey, modern.minOSSortKey)
        XCTAssertEqual(none.minOSSortKey, 0)
    }

    func testCategoricalFacetsFilterCorrectly() {
        let intelSparkle = makeResult(name: "OldApp", bundleID: "com.old.app", tier: .medium, score: 30,
                                      flags: [.intelOnly], archClass: .intel,
                                      updateKind: .sparkle, sandboxed: false, hasDownloadMetadata: false)
        let cleanUniversal = makeResult(name: "NewApp", bundleID: "com.new.app", tier: .low, score: 5,
                                        flags: [], archClass: .universal,
                                        updateKind: .appStore, sandboxed: true, hasDownloadMetadata: true)

        XCTAssertTrue(BatchFilter(archClass: .intel).matches(intelSparkle))
        XCTAssertFalse(BatchFilter(archClass: .intel).matches(cleanUniversal))

        XCTAssertTrue(BatchFilter(updateFilter: .kind(.sparkle)).matches(intelSparkle))
        XCTAssertFalse(BatchFilter(updateFilter: .kind(.sparkle)).matches(cleanUniversal))
        // "No updater" facet — must be written `.some(.none)`; a bare `.none`
        // would bind to Optional.none ("any"). Rejects apps that have an
        // updater, matches apps that don't.
        let noUpdater = makeResult(name: "Plain", bundleID: "com.plain.app", tier: .low, score: 0,
                                   flags: [], updateKind: nil)
        XCTAssertFalse(BatchFilter(updateFilter: .some(.none)).matches(intelSparkle))
        XCTAssertTrue(BatchFilter(updateFilter: .some(.none)).matches(noUpdater))

        XCTAssertTrue(BatchFilter(sandboxed: false).matches(intelSparkle))
        XCTAssertFalse(BatchFilter(sandboxed: false).matches(cleanUniversal))

        XCTAssertTrue(BatchFilter(hasDownloadMetadata: false).matches(intelSparkle))
        XCTAssertFalse(BatchFilter(hasDownloadMetadata: false).matches(cleanUniversal))

        // Facets compose with flags (AND semantics).
        XCTAssertTrue(BatchFilter(requiredFlags: [.intelOnly], archClass: .intel).matches(intelSparkle))
        XCTAssertFalse(BatchFilter(requiredFlags: [.intelOnly], archClass: .universal).matches(intelSparkle))
    }

    func testCSVIncludesNewColumns() {
        let r = makeResult(name: "X", bundleID: "com.x", tier: .low, score: 0, flags: [],
                           archClass: .intel, minimumOS: "12.3", updateKind: .sparkle)
        let csv = BatchReport.csv([r])
        let header = csv.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(header.contains("Architecture"))
        XCTAssertTrue(header.contains("Min macOS"))
        XCTAssertTrue(header.contains("Update Mechanism"))
        let row = csv.split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertTrue(row.contains("Intel only"))
        XCTAssertTrue(row.contains("12.3"))
        XCTAssertTrue(row.contains("Sparkle"))
    }

    // MARK: - End to end

    func testCalculatorBatchResultIsCleanAndAppleSigned() async throws {
        #if !os(macOS)
        throw XCTSkip("macOS-only")
        #else
        let path = "/System/Applications/Calculator.app"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Calculator.app not present on this runner")
        }
        let results = await BatchAnalyzer().analyzeAll(urls: [URL(fileURLWithPath: path)])
        XCTAssertEqual(results.count, 1)
        let r = try XCTUnwrap(results.first)

        XCTAssertEqual(r.signing, .apple, "Calculator is an Apple platform binary")
        XCTAssertEqual(r.bundleID, "com.apple.calculator")
        XCTAssertEqual(r.trackerCount, 0, "Calculator ships no tracker SDKs")
        XCTAssertEqual(r.risk.tier, .low, "Apple's own apps should score low")
        XCTAssertNil(r.analysisError)
        XCTAssertNotEqual(r.archClass, .intel, "a current macOS system app is never Intel-only")
        XCTAssertNotEqual(r.archClass, .other, "Calculator's main executable should classify cleanly")
        for rotten in [BatchFlag.unsigned, .adHoc, .invalidSignature, .trackers, .secrets, .analysisFailed, .intelOnly] {
            XCTAssertFalse(r.flags.contains(rotten), "Calculator should not trip \(rotten.rawValue)")
        }
        #endif
    }

    // MARK: - Regression: verified-bug fixes

    func testMinOSSortKeyClampsHostileInputWithoutCrashing() {
        // A malformed Info.plist could carry a huge LSMinimumSystemVersion;
        // the sort key must clamp rather than trap on Int overflow.
        let hostile = makeResult(name: "Evil", bundleID: "com.evil", tier: .low, score: 0, flags: [],
                                 minimumOS: "9999999999999999.0")
        XCTAssertEqual(hostile.minOSSortKey, 9_999 * 10_000, "major segment clamps to 9999")
        // A minor >= 100 must not carry into the major place and break ordering.
        let weird = makeResult(name: "Weird", bundleID: "com.weird", tier: .low, score: 0, flags: [],
                               minimumOS: "13.150")
        let normal = makeResult(name: "Normal", bundleID: "com.normal", tier: .low, score: 0, flags: [],
                                minimumOS: "14.0")
        XCTAssertLessThan(weird.minOSSortKey, normal.minOSSortKey)
    }

    func testDownloadSourceFallsBackForFileURLs() {
        // file:// / local where-froms have an empty host — must fall through to
        // the quarantine agent, not return "".
        XCTAssertEqual(BatchAppResult.downloadSource(whereFromURLs: ["file:///Users/x/App.dmg"],
                                                     agentName: "AirDrop"), "AirDrop")
        XCTAssertEqual(BatchAppResult.downloadSource(whereFromURLs: ["https://dl.example.com/app.zip"],
                                                     agentName: "Safari"), "dl.example.com")
        XCTAssertEqual(BatchAppResult.downloadSource(whereFromURLs: [], agentName: "Safari"), "Safari")
        XCTAssertNil(BatchAppResult.downloadSource(whereFromURLs: [], agentName: nil))
    }

    func testMinOSBucketClassificationAndFilter() {
        XCTAssertEqual(MinOSBucket.from(minimumOS: "10.15"), .legacy)
        XCTAssertEqual(MinOSBucket.from(minimumOS: "13.0"), .v11to15)
        XCTAssertEqual(MinOSBucket.from(minimumOS: "26.0"), .v16plus)
        XCTAssertEqual(MinOSBucket.from(minimumOS: nil), .unknown)

        let legacy = makeResult(name: "Old", bundleID: "com.old", tier: .low, score: 0, flags: [],
                                minimumOS: "10.14")
        XCTAssertEqual(legacy.minOSBucket, .legacy)
        XCTAssertTrue(BatchFilter(minOSBucket: .legacy).matches(legacy))
        XCTAssertFalse(BatchFilter(minOSBucket: .v16plus).matches(legacy))
    }

    // MARK: - Helpers

    private func makeResult(name: String, bundleID: String, tier: RiskTier, score: Int,
                            flags: Set<BatchFlag>,
                            archClass: ArchClass = .universal,
                            minimumOS: String? = "13.0",
                            updateKind: UpdateMechanism.Kind? = nil,
                            sandboxed: Bool = true,
                            hasDownloadMetadata: Bool = true) -> BatchAppResult {
        BatchAppResult(
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            displayName: name, bundleID: bundleID, version: "1.0",
            risk: RiskScore(score: score, tier: tier, contributors: []),
            signing: flags.contains(.unsigned) ? .unsigned : .developerID,
            flags: flags,
            isSandboxed: sandboxed, hardenedRuntime: true, isAppStore: false,
            architectures: [], archClass: archClass, minimumOS: minimumOS,
            updateKind: updateKind, hasDownloadMetadata: hasDownloadMetadata,
            downloadSource: hasDownloadMetadata ? "example.com" : nil,
            trackerCount: flags.contains(.trackers) ? 2 : 0,
            trackerNames: flags.contains(.trackers) ? ["AdMob", "Firebase"] : [],
            sdkCount: flags.contains(.trackers) ? 2 : 0,
            secretCount: flags.contains(.secrets) ? 1 : 0,
            antiAnalysisCount: 0, launchItemCount: 0, hardcodedDomainCount: 0,
            analysisError: nil)
    }
}
