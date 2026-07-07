import XCTest
@testable import auditctlKit

final class AnsiTests: XCTestCase {

    func testDisabledIsPlain() {
        let a = Ansi(enabled: false)
        XCTAssertEqual(a.paint("hello", .red, .bold), "hello")
    }

    func testEnabledWrapsInSGR() {
        let a = Ansi(enabled: true)
        XCTAssertEqual(a.paint("hi", .red), "\u{001B}[31mhi\u{001B}[0m")
    }

    func testEnabledJoinsMultipleCodes() {
        let a = Ansi(enabled: true)
        XCTAssertEqual(a.paint("x", .bold, .cyan), "\u{001B}[1;36mx\u{001B}[0m")
    }

    func testEmptyStyleListReturnsInput() {
        let a = Ansi(enabled: true)
        XCTAssertEqual(a.paint("x", []), "x")
    }
}
