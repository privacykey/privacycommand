import XCTest
@testable import privacycommandCore

/// Tests for the Tier-2 runtime tracer. The deterministic parsers are tested
/// directly; the end-to-end test compiles a real `connect()` program and runs
/// it under the interposer to prove the whole mechanism (inject → capture →
/// symbolicate → parse) works on this machine.
final class ConnectionTracerTests: XCTestCase {

    func testParseFrameNormalisesOffsetToHex() {
        let f = ConnectionTracer.parseFrame("2   myprog   0x000000010abcd1f0 main + 64", index: 2)
        XCTAssertEqual(f?.module, "myprog")
        XCTAssertEqual(f?.symbol, "main")
        XCTAssertEqual(f?.offset, "40")   // 64 decimal → 0x40
        XCTAssertEqual(f?.index, 2)
    }

    func testParseLogGroupsEventsAndFrames() {
        let log = """
        EVENT\t123\tconnect\t127.0.0.1:9
        FRAME\t2   myprog   0x100abc main + 64
        FRAME\t3   dyld   0x7fff00 start + 1
        END
        EVENT\t123\tgetaddrinfo\texample.com
        FRAME\t2   myprog   0x100abc resolve + 8
        END
        """
        let conns = ConnectionTracer.parseLog(log)
        XCTAssertEqual(conns.count, 2)
        XCTAssertEqual(conns[0].kind, .connect)
        XCTAssertEqual(conns[0].detail, "127.0.0.1:9")
        XCTAssertEqual(conns[0].stack.count, 2)
        XCTAssertEqual(conns[0].stack.first?.symbol, "main")
        XCTAssertEqual(conns[1].kind, .getaddrinfo)
        XCTAssertEqual(conns[1].detail, "example.com")
    }

    func testNetworkEventFromTracedConnectCarriesStack() {
        let c = ConnectionTracer.TracedConnection(
            pid: 42, kind: .connect, detail: "1.2.3.4:443",
            stack: [StackFrame(index: 0, module: "m", symbol: "f", offset: "0")])
        let e = ConnectionTracer.networkEvent(from: c, processName: "m", processPath: "/x")
        XCTAssertEqual(e?.remoteEndpoint.address, "1.2.3.4")
        XCTAssertEqual(e?.remoteEndpoint.port, 443)
        XCTAssertEqual(e?.callStack?.first?.symbol, "f")
        // getaddrinfo events don't map to a NetworkEvent.
        XCTAssertNil(ConnectionTracer.networkEvent(
            from: .init(pid: 1, kind: .getaddrinfo, detail: "x", stack: []),
            processName: "m", processPath: nil))
    }

    /// Build a tiny program that calls `connect()`, run it under the
    /// interposer, and confirm we captured the call with a real backtrace
    /// containing `main`.
    func testEndToEndCapturesConnectWithBacktrace() async throws {
        guard ConnectionTracer.isSupported() else { throw XCTSkip("clang unavailable") }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pc-tracer-e2e-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let src = dir.appendingPathComponent("target.c")
        try """
        #include <sys/socket.h>
        #include <netinet/in.h>
        #include <arpa/inet.h>
        int main(void) {
          int s = socket(AF_INET, SOCK_STREAM, 0);
          struct sockaddr_in a;
          a.sin_family = AF_INET; a.sin_port = htons(9);
          inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
          connect(s, (struct sockaddr*)&a, sizeof(a));
          return 0;
        }
        """.write(to: src, atomically: true, encoding: .utf8)

        let bin = dir.appendingPathComponent("target")
        let clang = try XCTUnwrap(ConnectionTracer.clangPath())
        let compile = ProcessRunner.runSync(launchPath: clang,
                                            arguments: ["-O0", "-o", bin.path, src.path],
                                            timeout: 60)
        XCTAssertTrue(compile.success, "compile failed: \(compile.stderr)")

        let conns = try await ConnectionTracer().trace(executable: bin, timeout: 15)
        let connects = conns.filter { $0.kind == .connect }

        if connects.isEmpty {
            // Some sandboxed CI environments strip DYLD_INSERT_LIBRARIES; don't
            // hard-fail the suite there, but record that injection was a no-op.
            throw XCTSkip("no connect captured — DYLD injection appears disabled in this environment")
        }
        let target = try XCTUnwrap(connects.first { $0.detail == "127.0.0.1:9" },
                                   "got \(connects.map(\.detail))")
        XCTAssertFalse(target.stack.isEmpty, "expected a non-empty backtrace")
        XCTAssertTrue(target.stack.contains { $0.symbol.contains("main") },
                      "expected main in the backtrace; got \(target.stack.map(\.symbol))")
    }
}
