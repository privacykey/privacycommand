import XCTest
import privacycommandGuestProtocol

/// Wire round-trip tests for the v2 decompile-in-guest protocol additions —
/// the command and the three observations must survive `GuestWireCodec`
/// framing + JSON encode/decode intact.
final class GuestProtocolDecompileTests: XCTestCase {

    private func roundTrip(_ payload: GuestEnvelope.Payload) throws -> GuestEnvelope {
        let data = try GuestWireCodec.encode(GuestEnvelope(payload: payload))
        let decoded = try GuestWireCodec.decodeOne(from: data)
        XCTAssertNotNil(decoded, "one framed envelope should decode")
        XCTAssertEqual(decoded?.bytesConsumed, data.count, "consumes the whole frame")
        return decoded!.envelope
    }

    func testProtocolVersionIsV2() {
        XCTAssertEqual(GuestProtocolVersion.current, 2)
    }

    func testDecompileBundleCommandRoundTrips() throws {
        let env = try roundTrip(.command(.decompileBundle(
            bundlePathInGuest: "/Users/x/Downloads/Foo.app",
            scopeKind: "namedClasses", cap: 1500)))
        guard case .command(.decompileBundle(let path, let kind, let cap)) = env.payload else {
            return XCTFail("expected a decompileBundle command")
        }
        XCTAssertEqual(path, "/Users/x/Downloads/Foo.app")
        XCTAssertEqual(kind, "namedClasses")
        XCTAssertEqual(cap, 1500)
    }

    func testDecompiledClassObservationRoundTrips() throws {
        // A realistic per-class JSON payload with embedded newlines in the C.
        let json = "{\"name\":\"Foo\",\"functions\":[{\"className\":\"Foo\",\"name\":\"bar\",\"signature\":null,\"entryHex\":\"1000\",\"cCode\":\"void bar(void){\\n  return;\\n}\"}]}"
        let env = try roundTrip(.observation(.decompiledClass(json: json)))
        guard case .observation(.decompiledClass(let decoded)) = env.payload else {
            return XCTFail("expected a decompiledClass observation")
        }
        XCTAssertEqual(decoded, json, "opaque JSON survives framing verbatim")
    }

    func testDecompileCompleteRoundTrips() throws {
        let env = try roundTrip(.observation(.decompileComplete(truncated: true, functionCount: 42)))
        guard case .observation(.decompileComplete(let truncated, let count)) = env.payload else {
            return XCTFail("expected a decompileComplete observation")
        }
        XCTAssertTrue(truncated)
        XCTAssertEqual(count, 42)
    }

    func testDecompileFailedRoundTrips() throws {
        let env = try roundTrip(.observation(.decompileFailed(message: "Ghidra isn't installed")))
        guard case .observation(.decompileFailed(let message)) = env.payload else {
            return XCTFail("expected a decompileFailed observation")
        }
        XCTAssertEqual(message, "Ghidra isn't installed")
    }
}
