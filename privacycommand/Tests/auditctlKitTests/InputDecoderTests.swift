import XCTest
@testable import auditctlKit

final class InputDecoderTests: XCTestCase {

    func testPrintableChars() {
        XCTAssertEqual(InputDecoder.decode(Array("hi".utf8)), [.char("h"), .char("i")])
    }

    func testEnterCRAndLF() {
        XCTAssertEqual(InputDecoder.decode([0x0d]), [.enter])
        XCTAssertEqual(InputDecoder.decode([0x0a]), [.enter])
    }

    func testCRLFCollapsesToOneEnter() {
        XCTAssertEqual(InputDecoder.decode([0x0d, 0x0a]), [.enter])
    }

    func testBackspaceVariants() {
        XCTAssertEqual(InputDecoder.decode([0x7f]), [.backspace])
        XCTAssertEqual(InputDecoder.decode([0x08]), [.backspace])
    }

    func testTabAndCtrlC() {
        XCTAssertEqual(InputDecoder.decode([0x09]), [.tab])
        XCTAssertEqual(InputDecoder.decode([0x03]), [.ctrlC])
    }

    func testCSIArrows() {
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x5b, 0x41]), [.up])
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x5b, 0x42]), [.down])
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x5b, 0x43]), [.right])
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x5b, 0x44]), [.left])
    }

    func testSS3Arrows() {
        // Application-cursor mode: ESC O A .. D
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x4f, 0x41]), [.up])
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x4f, 0x44]), [.left])
    }

    func testHomeEndAndPaging() {
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x5b, 0x48]), [.home])
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x5b, 0x46]), [.end])
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x5b, 0x35, 0x7e]), [.pageUp])
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x5b, 0x36, 0x7e]), [.pageDown])
    }

    func testLoneEscape() {
        XCTAssertEqual(InputDecoder.decode([0x1b]), [.escape])
    }

    func testDeleteKeyIsIgnored() {
        // ESC [ 3 ~  (forward-delete) — consumed, no event emitted.
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x5b, 0x33, 0x7e]), [])
    }

    func testArrowThenCharInOneChunk() {
        XCTAssertEqual(InputDecoder.decode([0x1b, 0x5b, 0x42, 0x78]), [.down, .char("x")])
    }

    func testUTF8MultibyteChar() {
        // "é" == 0xC3 0xA9
        XCTAssertEqual(InputDecoder.decode([0xc3, 0xa9]), [.char("é")])
    }

    func testStrayControlBytesIgnored() {
        XCTAssertEqual(InputDecoder.decode([0x00, 0x01, 0x1f]), [])
    }

    func testSpaceIsAChar() {
        XCTAssertEqual(InputDecoder.decode([0x20]), [.char(" ")])
    }
}
