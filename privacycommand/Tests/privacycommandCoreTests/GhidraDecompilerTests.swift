import XCTest
@testable import privacycommandCore

/// Tests for the deterministic seams of `GhidraDecompiler` — output parsing,
/// the stable project hash, and Ghidra location. The live `decompile(...)`
/// path needs a real Ghidra install and is exercised manually.
final class GhidraDecompilerTests: XCTestCase {

    // MARK: - parseOutput

    func testParseOutputReturnsCodeForPlainC() throws {
        let c = "void FUN_0001(void)\n{\n  connect(s,addr,len);\n  return;\n}\n"
        let d = try GhidraDecompiler.parseOutput(c, function: "_main")
        XCTAssertEqual(d.function, "_main")
        XCTAssertEqual(d.cCode, c)
    }

    func testParseOutputMapsNotFoundMarker() {
        XCTAssertThrowsError(try GhidraDecompiler.parseOutput("DECOMPILE_NOT_FOUND: _main",
                                                              function: "_main")) { err in
            XCTAssertEqual(err as? GhidraDecompiler.DecompileError, .functionNotFound("_main"))
        }
    }

    func testParseOutputMapsFailedMarker() {
        XCTAssertThrowsError(try GhidraDecompiler.parseOutput("DECOMPILE_FAILED: bad timing",
                                                              function: "f")) { err in
            XCTAssertEqual(err as? GhidraDecompiler.DecompileError, .decompileFailed("bad timing"))
        }
    }

    func testParseOutputEmptyIsFailure() {
        XCTAssertThrowsError(try GhidraDecompiler.parseOutput("   \n\t", function: "f"))
    }

    // MARK: - stableHash

    func testStableHashIsDeterministicAndPathSensitive() {
        XCTAssertEqual(GhidraDecompiler.stableHash("/a/b/c"),
                       GhidraDecompiler.stableHash("/a/b/c"))
        XCTAssertNotEqual(GhidraDecompiler.stableHash("/a/b/c"),
                          GhidraDecompiler.stableHash("/a/b/d"))
        XCTAssertEqual(GhidraDecompiler.stableHash("/a/b/c").count, 16)
    }

    // MARK: - projectKey (cache invalidation)

    func testProjectKeyChangesWithContent() throws {
        let fm = FileManager.default
        let a = fm.temporaryDirectory.appendingPathComponent("pc-key-a-\(UUID().uuidString).bin")
        let b = fm.temporaryDirectory.appendingPathComponent("pc-key-b-\(UUID().uuidString).bin")
        try Data("hello".utf8).write(to: a)
        try Data("a longer payload".utf8).write(to: b)
        defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }

        // Same file → stable key; different size → different key.
        XCTAssertEqual(GhidraDecompiler.projectKey(for: a, fm: fm),
                       GhidraDecompiler.projectKey(for: a, fm: fm))
        XCTAssertNotEqual(GhidraDecompiler.projectKey(for: a, fm: fm),
                          GhidraDecompiler.projectKey(for: b, fm: fm))
    }

    // MARK: - locateAnalyzeHeadless

    func testLocateAnalyzeHeadlessFindsExecutableUnderGhidraDir() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pc-ghidra-\(UUID().uuidString)")
        let support = root.appendingPathComponent("ghidra_11.3_PUBLIC/support")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let headless = support.appendingPathComponent("analyzeHeadless")
        XCTAssertTrue(fm.createFile(atPath: headless.path,
                                    contents: Data("#!/bin/sh\n".utf8),
                                    attributes: [.posixPermissions: 0o755]))
        defer { try? fm.removeItem(at: root) }

        let found = GhidraDecompiler.locateAnalyzeHeadless(searchRoots: [root])
        // Compare resolved paths: /var/folders symlinks to /private/var/folders,
        // and the directory scan returns the resolved form.
        XCTAssertEqual(found?.resolvingSymlinksInPath().path,
                       headless.resolvingSymlinksInPath().path)
        XCTAssertTrue(GhidraDecompiler.isAvailable(searchRoots: [root]))
    }

    func testLocateAnalyzeHeadlessNilWhenAbsentOrNonExecutable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pc-empty-\(UUID().uuidString)")
        // A ghidra dir whose analyzeHeadless is NOT executable must not match.
        let support = root.appendingPathComponent("ghidra_11.3/support")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: support.appendingPathComponent("analyzeHeadless").path,
                                    contents: Data(),
                                    attributes: [.posixPermissions: 0o644]))
        defer { try? fm.removeItem(at: root) }

        XCTAssertNil(GhidraDecompiler.locateAnalyzeHeadless(searchRoots: [root]))
        XCTAssertFalse(GhidraDecompiler.isAvailable(searchRoots: [root]))
    }
}
