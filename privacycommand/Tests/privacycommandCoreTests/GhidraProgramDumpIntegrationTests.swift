import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// **Opt-in integration test** — actually runs Ghidra headless, so it's skipped
/// unless `PC_GHIDRA_INTEGRATION=1` is set *and* a Ghidra install is
/// discoverable. It needs a JDK reachable by Ghidra's launcher, so run it with
/// `JAVA_HOME` pointing at a JDK, e.g.:
///
///     PC_GHIDRA_INTEGRATION=1 \
///     JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
///     swift test --filter GhidraProgramDumpIntegrationTests
///
/// This is the one test that exercises the real `PCDumpProgram.py` under a
/// genuine Ghidra — everything else about the dump is unit-tested against
/// fixture output.
final class GhidraProgramDumpIntegrationTests: XCTestCase {

    private func requireGhidra() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PC_GHIDRA_INTEGRATION"] == "1",
                          "set PC_GHIDRA_INTEGRATION=1 (and JAVA_HOME) to run the Ghidra integration test")
        try XCTSkipUnless(GhidraProgramDump.isAvailable(),
                          "no Ghidra install found in the standard search roots")
    }

    /// Decompile a tiny real Mach-O with `.everything` and assert we got real C
    /// back. Proves: analyzeHeadless invocation, the materialised Jython script,
    /// its JSON-Lines output, and the parser — end to end.
    func testEverythingScopeProducesRealC() async throws {
        try requireGhidra()
        let index = try await GhidraProgramDump().dump(
            binary: URL(fileURLWithPath: "/bin/echo"),
            scope: .everything(cap: 15),
            timeout: 900)

        XCTAssertEqual(index.source, .ghidra)
        XCTAssertGreaterThan(index.functionCount, 0, "should decompile at least one function")
        let functions = index.classes.flatMap(\.functions)
        XCTAssertTrue(functions.contains { !$0.cCode.isEmpty },
                      "at least one function should have decompiled C")
        XCTAssertTrue(functions.contains { $0.cCode.contains("{") },
                      "decompiled C should look like C")
    }

    /// `.namedClasses` on the same (now-analysed, cached) binary must not crash
    /// and must return a valid index. A pure-C binary has no named classes, so
    /// an empty-but-valid result is the expected, correct outcome — the point is
    /// that the namespace-filter branch of the script runs cleanly.
    func testNamedClassesScopeRunsCleanly() async throws {
        try requireGhidra()
        let index = try await GhidraProgramDump().dump(
            binary: URL(fileURLWithPath: "/bin/echo"),
            scope: .namedClasses,
            timeout: 900)
        XCTAssertEqual(index.source, .ghidra)
        XCTAssertFalse(index.truncated)
        // classCount may legitimately be 0 for a C binary — no assertion needed.
    }

    /// Also exercise the single-function decompiler's Java script (used by the
    /// network call-site "Decompile" action): dump to find a real function,
    /// then decompile it by name + address and assert we get C, not a marker.
    func testSingleFunctionDecompileProducesC() async throws {
        try requireGhidra()
        let binary = URL(fileURLWithPath: "/bin/echo")
        let index = try await GhidraProgramDump().dump(
            binary: binary, scope: .everything(cap: 8), timeout: 900)
        let target = try XCTUnwrap(index.classes.flatMap(\.functions).first { !$0.cCode.isEmpty },
                                   "need at least one decompiled function to target")

        let decompiled = try await GhidraDecompiler().decompile(
            binary: binary, function: target.name, address: target.entryHex, timeout: 900)

        XCTAssertFalse(decompiled.cCode.isEmpty)
        XCTAssertFalse(decompiled.cCode.hasPrefix("DECOMPILE_"),
                       "should be real C, not a not-found/failed marker")
    }
}
