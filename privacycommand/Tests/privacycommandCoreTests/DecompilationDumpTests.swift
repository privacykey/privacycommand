import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Unit tests for the whole-app decompilation pieces: the JSON-Lines parser
/// (`GhidraProgramDump.parse`), the scope keys, and the on-disk store. The
/// Ghidra run itself is integration-only (like `GhidraDecompiler`); here we
/// test the deterministic seams.
final class DecompilationDumpTests: XCTestCase {

    // MARK: - Parser

    func testParseGroupsFunctionsByClass() throws {
        let jsonl = """
        {"class":"ClassA","function":"foo","signature":"void foo(void)","entryHex":"1000","c":"void foo(void){return;}"}
        {"class":"ClassA","function":"bar","signature":null,"entryHex":"1010","c":"int bar(void){return 1;}"}
        {"class":null,"function":"FUN_2000","signature":null,"entryHex":"2000","c":"void FUN_2000(void){}"}
        {"__meta__":true,"truncated":true,"functionCount":3}
        """
        let index = try GhidraProgramDump.parse(jsonl: jsonl, binaryPath: "/bin/x", scope: .namedClasses)

        XCTAssertEqual(index.functionCount, 3)
        XCTAssertTrue(index.truncated)
        XCTAssertEqual(index.source, .ghidra)
        XCTAssertEqual(index.scope, "namedClasses-1500")

        let classA = index.classes.first { $0.name == "ClassA" }
        XCTAssertEqual(classA?.functions.count, 2)
        XCTAssertEqual(index.classes.first { $0.name == "(global)" }?.functions.count, 1)
        XCTAssertEqual(classA?.functions.first?.signature, "void foo(void)")
        XCTAssertNil(classA?.functions.last?.signature, "JSON null signature → nil")
    }

    func testParseSkipsNoiseAndIncompleteLines() throws {
        let jsonl = """
        INFO  analyzeHeadless noise that isn't JSON
        {"class":"C","function":"ok","signature":null,"entryHex":"1","c":"x"}
        {"class":"C","function":"noBody","signature":null,"entryHex":"2"}
        {"__meta__":true,"truncated":false,"functionCount":1}
        """
        let index = try GhidraProgramDump.parse(jsonl: jsonl, binaryPath: "/bin/x", scope: .namedClasses)
        XCTAssertEqual(index.functionCount, 1, "noise + line missing 'c' are skipped")
        XCTAssertFalse(index.truncated)
    }

    func testParseErrorMarkerThrows() {
        XCTAssertThrowsError(
            try GhidraProgramDump.parse(jsonl: "DUMP_ERROR: something exploded",
                                        binaryPath: "/bin/x", scope: .namedClasses)
        ) { error in
            XCTAssertEqual(error as? GhidraProgramDump.DumpError, .dumpFailed("something exploded"))
        }
    }

    func testParseEmptyYieldsEmptyIndex() throws {
        let index = try GhidraProgramDump.parse(jsonl: "", binaryPath: "/bin/x", scope: .everything(cap: 10))
        XCTAssertEqual(index.classCount, 0)
        XCTAssertEqual(index.functionCount, 0)
        XCTAssertFalse(index.truncated)
        XCTAssertEqual(index.scope, "everything-10")
    }

    // MARK: - Scope

    func testScopeKeys() {
        XCTAssertEqual(DecompileScope.namedClasses.key, "namedClasses-1500")
        XCTAssertEqual(DecompileScope.everything(cap: 50).key, "everything-50")
        XCTAssertEqual(DecompileScope(kind: .namedClasses, cap: 200).key, "namedClasses-200")
    }

    func testDisplayNameFallsBackToRawName() {
        let raw = DecompiledFunction(className: "C", name: "$s3FooC", signature: nil, entryHex: "1", cCode: "")
        XCTAssertEqual(raw.displayName, "$s3FooC")
        let demangled = DecompiledFunction(className: "C", name: "$s3FooC", demangled: "Foo.init",
                                           signature: nil, entryHex: "1", cCode: "")
        XCTAssertEqual(demangled.displayName, "Foo.init")
    }

    // MARK: - Store

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-decompstore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try DecompilationIndexStore(directory: dir)

        let index = DecompilationIndex(
            source: .ghidra, binaryPath: "/Applications/Foo.app/Contents/MacOS/Foo",
            scope: "namedClasses-1500",
            classes: [DecompiledClass(name: "Foo", functions: [
                DecompiledFunction(className: "Foo", name: "bar", signature: "void bar()",
                                   entryHex: "1000", cCode: "void bar(){}")
            ])],
            functionCount: 1, truncated: false,
            // Whole-second date: the store encodes ISO-8601 (second precision,
            // matching JSONExporter), so a sub-second date wouldn't round-trip.
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertNil(store.load(key: "missing"))
        try store.save(index, key: "k1")
        XCTAssertEqual(store.load(key: "k1"), index, "round-trips through Codable")
    }

    func testCacheKeyIncludesScopeAndIsStable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-cachekey-\(UUID().uuidString).bin")
        try Data([0x01, 0x02, 0x03]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let k1 = GhidraProgramDump.cacheKey(for: tmp, scope: .namedClasses)
        let k1again = GhidraProgramDump.cacheKey(for: tmp, scope: .namedClasses)
        let k2 = GhidraProgramDump.cacheKey(for: tmp, scope: .everything(cap: 100))
        XCTAssertEqual(k1, k1again, "same binary+scope → stable key")
        XCTAssertNotEqual(k1, k2, "different scope → different cache entry")
        XCTAssertTrue(k1.hasSuffix("namedClasses-1500"))
    }
}
