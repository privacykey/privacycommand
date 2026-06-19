import XCTest
@testable import privacycommandCore

/// Covers the volatile-build-token coalescing that keeps the run-comparison
/// readable for hash-stamped binaries (notably Rust's `/rustc/<commit>/…`
/// paths), folding an otherwise-noisy added+removed pair into one "modified".
final class ReportDifferVolatileTests: XCTestCase {

    private let differ = ReportDiffer()

    func testRustcBuildHashCollapsesToModified() {
        let before = "/rustc/a1b2c3d4e5f60718293a4b5c6d7e8f9012345678/library/std/src/panic.rs"
        let after  = "/rustc/0f9e8d7c6b5a4039281716253443526170890abc/library/std/src/panic.rs"

        let r = differ.coalesceVolatile(added: [after], removed: [before])

        XCTAssertTrue(r.added.isEmpty, "the rebuilt path should not show as added")
        XCTAssertTrue(r.removed.isEmpty, "the old path should not show as removed")
        XCTAssertEqual(r.modified.count, 1)
        XCTAssertEqual(r.modified.first?.display, "/rustc/<hash>/library/std/src/panic.rs")
        XCTAssertEqual(r.modified.first?.before, before)
        XCTAssertEqual(r.modified.first?.after, after)
        // The actual changed hash is preserved so it stays comparable.
        XCTAssertEqual(r.modified.first?.tokens.count, 1)
        XCTAssertEqual(r.modified.first?.tokens.first?.before, "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
        XCTAssertEqual(r.modified.first?.tokens.first?.after, "0f9e8d7c6b5a4039281716253443526170890abc")
    }

    func testTokenChangesExtractsBothEnds() {
        let changes = ReportDiffer.tokenChanges(
            before: "/var/folders/AAAAAAAA-1111-2222-3333-444444444444/T/x.o",
            after:  "/var/folders/BBBBBBBB-5555-6666-7777-888888888888/T/x.o")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.before, "AAAAAAAA-1111-2222-3333-444444444444")
        XCTAssertEqual(changes.first?.after, "BBBBBBBB-5555-6666-7777-888888888888")
    }

    func testDifferentFileUnderSameTokenStaysAddedRemoved() {
        // Same volatile slot but a genuinely different file — not a modification.
        let r = differ.coalesceVolatile(
            added:   ["/rustc/aaaaaaaaaaaaaaaa/library/std/src/new.rs"],
            removed: ["/rustc/bbbbbbbbbbbbbbbb/library/std/src/old.rs"])

        XCTAssertEqual(r.modified.count, 0)
        XCTAssertEqual(r.added.count, 1)
        XCTAssertEqual(r.removed.count, 1)
    }

    func testNonVolatilePathsAreUntouched() {
        let r = differ.coalesceVolatile(
            added:   ["/Applications/Foo.app/added.txt"],
            removed: ["/Applications/Foo.app/removed.txt"])

        XCTAssertEqual(r.modified.count, 0)
        XCTAssertEqual(r.added, ["/Applications/Foo.app/added.txt"])
        XCTAssertEqual(r.removed, ["/Applications/Foo.app/removed.txt"])
    }

    func testUUIDTokenCollapses() {
        let before = "/var/folders/AAAAAAAA-1111-2222-3333-444444444444/T/x.o"
        let after  = "/var/folders/BBBBBBBB-5555-6666-7777-888888888888/T/x.o"

        let r = differ.coalesceVolatile(added: [after], removed: [before])

        XCTAssertEqual(r.modified.count, 1)
        XCTAssertEqual(r.modified.first?.display, "/var/folders/<id>/T/x.o")
    }

    func testNormalizeReplacesHashAndID() {
        XCTAssertEqual(
            ReportDiffer.normalizeVolatile("/rustc/0123456789abcdef0123456789abcdef01234567/x"),
            "/rustc/<hash>/x")
        XCTAssertEqual(
            ReportDiffer.normalizeVolatile("plain/path/no/tokens"),
            "plain/path/no/tokens")
    }
}
