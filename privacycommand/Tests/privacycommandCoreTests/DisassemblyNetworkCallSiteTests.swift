import XCTest
@testable import privacycommandCore

/// Tests for the per-function network call-site attribution added to
/// `DisassemblyAnalyzer`. These cover the "what code could open a connection?"
/// static-capability map that backs the timeline's call-site disclosure.
final class DisassemblyNetworkCallSiteTests: XCTestCase {

    /// A function that calls `getaddrinfo` + `connect` and references a host
    /// literal should be reported, with both symbols and the host hint, while
    /// a purely-computational neighbour is excluded.
    func testAttributesNetworkingCallsToEnclosingFunction() {
        let dis = """
        foo.o:\tfile format mach-o-arm64
        _start_network:
        100003abc:\tbl\t0x100\t; symbol stub for: _getaddrinfo
        100003ac0:\tbl\t0x108\t; symbol stub for: _connect
        100003ac4:\tadr\tx0, 0x200\t; literal pool for: "api.cloudflare.com"
        _do_math:
        100003b00:\tadd\tx0, x0, x1
        100003b04:\tbl\t0x110\t; symbol stub for: _memcpy
        _resolve_only:
        100003c00:\tbl\t0x118\t; symbol stub for: _getaddrinfo
        """

        let summary = DisassemblyAnalyzer.analyse(disassembly: dis)

        let functions = Set(summary.networkCallSites.map(\.function))
        XCTAssertTrue(functions.contains("_start_network"))
        XCTAssertTrue(functions.contains("_resolve_only"))
        XCTAssertFalse(functions.contains("_do_math"),
                       "a function with only non-networking calls must not appear")

        let net = try! XCTUnwrap(summary.networkCallSites.first { $0.function == "_start_network" })
        XCTAssertEqual(Set(net.calls.map(\.symbol)), ["_getaddrinfo", "_connect"])
        XCTAssertTrue(net.hostHints.contains("api.cloudflare.com"),
                      "the host literal inside the function should be surfaced")
    }

    /// Busiest network function ranks first.
    func testCallSitesRankedByNetworkingCallCount() {
        let dis = """
        _light:
        1000:\tbl\t0x1\t; symbol stub for: _connect
        _heavy:
        2000:\tbl\t0x2\t; symbol stub for: _connect
        2004:\tbl\t0x3\t; symbol stub for: _send
        2008:\tbl\t0x4\t; symbol stub for: _recv
        """
        let summary = DisassemblyAnalyzer.analyse(disassembly: dis)
        XCTAssertEqual(summary.networkCallSites.first?.function, "_heavy")
    }

    /// A binary with no networking stubs yields an empty map.
    func testNoNetworkingMeansNoCallSites() {
        let dis = """
        _f:
        1000:\tbl\t0x1\t; symbol stub for: _memcpy
        1004:\tbl\t0x2\t; symbol stub for: _malloc
        """
        let summary = DisassemblyAnalyzer.analyse(disassembly: dis)
        XCTAssertTrue(summary.networkCallSites.isEmpty)
    }

    /// `isHostLike` accepts hostnames/URLs and rejects assembly noise and paths.
    func testHostLikeHeuristic() {
        XCTAssertTrue(DisassemblyAnalyzer.isHostLike("api.cloudflare.com"))
        XCTAssertTrue(DisassemblyAnalyzer.isHostLike("https://example.com/path"))
        XCTAssertFalse(DisassemblyAnalyzer.isHostLike("mov x0, x1"))
        XCTAssertFalse(DisassemblyAnalyzer.isHostLike("/usr/lib/libSystem.dylib"))
        XCTAssertFalse(DisassemblyAnalyzer.isHostLike("hello"))
    }
}
