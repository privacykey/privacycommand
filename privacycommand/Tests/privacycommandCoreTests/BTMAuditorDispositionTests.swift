import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Wave 5 — BTM disposition parsing: tokenize so "disabled"/"disallowed" don't
/// read as enabled/allowed (the old `dispo.contains("enabled")` inverted them).
final class BTMAuditorDispositionTests: XCTestCase {

    func testDisabledIsNotReadAsEnabled() {
        let output = """
        Type: agent
        Identifier: com.foo.off
        Disposition: [disabled, disallowed, visible]

        Type: agent
        Identifier: com.foo.on
        Disposition: [enabled, allowed, visible, notified]
        """
        let records = BTMAuditor.parse(output: output)
        let off = records.first { $0.identifier == "com.foo.off" }
        let on = records.first { $0.identifier == "com.foo.on" }

        XCTAssertEqual(off?.isEnabled, false, "'disabled' must not be read as enabled")
        XCTAssertEqual(off?.isAllowed, false, "'disallowed' must not be read as allowed")
        XCTAssertEqual(on?.isEnabled, true)
        XCTAssertEqual(on?.isAllowed, true)
    }
}
