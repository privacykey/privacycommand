import XCTest
@testable import privacycommandCLIKit

/// Covers the pure layout of the live progress board: column widths, what
/// gets dropped on a narrow terminal, which rows are hidden when there are
/// more than fit, and that colour never leaks into a plain run.
final class ProgressBoardTests: XCTestCase {

    private let plain = Ansi(enabled: false)

    private func row(_ name: String, _ state: ProgressBoard.Row.State = .queued,
                     version: String? = "1.0 → 1.1", status: String = "queued") -> ProgressBoard.Row {
        ProgressBoard.Row(id: name, state: state, name: name, version: version, status: status)
    }

    func testRowsAlignIntoColumnsWithMarkers() {
        let lines = ProgressBoard.render(
            rows: [row("Cursor", .working, version: "3.23.12 → 3.24.9", status: "scanning frameworks"),
                   row("iTerm", .clean, version: "3.7.0 → 3.7.4", status: "low risk 14 · 2 findings"),
                   row("OpenDisk", version: "1.2.0 → 1.2.7")],
            footer: "1 of 3 done · 15s", frame: "⠹", width: 100, maxRows: 10, ansi: plain)

        XCTAssertEqual(lines, [
            "  ~ Cursor    3.23.12 → 3.24.9  scanning frameworks",
            "  ✓ iTerm     3.7.0 → 3.7.4     low risk 14 · 2 findings",
            "  · OpenDisk  1.2.0 → 1.2.7     queued",
            "⠹ 1 of 3 done · 15s",
        ])
    }

    func testEveryLineFitsInsideTheWidth() {
        let rows = [row("A very long application name indeed", .working,
                        version: "2026.1.2,abcdef → 2026.1.3,fedcba",
                        status: "checking code signature & notarization and more words")]
        for width in [20, 35, 50, 80] {
            let lines = ProgressBoard.render(rows: rows, footer: String(repeating: "x", count: 200),
                                             frame: "⠋", width: width, maxRows: 5, ansi: plain)
            for line in lines {
                XCTAssertLessThanOrEqual(line.count, width - 1, "width \(width): \(line)")
            }
        }
    }

    func testVersionColumnGoesFirstWhenNarrow() {
        let rows = [row("Firefox", .working, version: "155.0.1 → 157.0.1", status: "checking code signature")]
        let wide = ProgressBoard.render(rows: rows, footer: "", frame: nil, width: 80, maxRows: 5, ansi: plain)
        XCTAssertTrue(wide[0].contains("155.0.1 → 157.0.1"))

        let narrow = ProgressBoard.render(rows: rows, footer: "", frame: nil, width: 40, maxRows: 5, ansi: plain)
        XCTAssertFalse(narrow[0].contains("155.0.1"), narrow[0])
        XCTAssertTrue(narrow[0].hasPrefix("  ~ Firefox  checking"), narrow[0])
    }

    func testFinishedRowsAreHiddenFirstWhenTooTall() {
        let rows = [row("A", .clean, status: "done"), row("B", .working, status: "scanning"),
                    row("C", .queued), row("D", .queued), row("E", .noteworthy, status: "done")]
        let (shown, hidden) = ProgressBoard.visibleRows(rows, maxRows: 3)
        // Two slots for rows (one is kept for the "+N more" line): the row
        // being worked on survives, then the first queued one.
        XCTAssertEqual(shown.map(\.name), ["B", "C"])
        XCTAssertEqual(hidden.map(\.name), ["A", "D", "E"])

        let lines = ProgressBoard.render(rows: rows, footer: "f", frame: nil, width: 80, maxRows: 3, ansi: plain)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[2], "  … +3 more (2 done, 1 queued)")
    }

    func testAllRowsShownWhenTheyFit() {
        let rows = [row("A"), row("B")]
        let (shown, hidden) = ProgressBoard.visibleRows(rows, maxRows: 2)
        XCTAssertEqual(shown.count, 2)
        XCTAssertTrue(hidden.isEmpty)
    }

    func testFooterOnlyWhenThereAreNoRows() {
        let lines = ProgressBoard.render(rows: [], footer: "Asking Homebrew what's outdated · 3s",
                                         frame: "⠋", width: 80, maxRows: 10, ansi: plain)
        XCTAssertEqual(lines, ["⠋ Asking Homebrew what's outdated · 3s"])
    }

    func testColourIsAppliedPerCellAndNeverWhenDisabled() {
        let rows = [row("iTerm", .clean, status: "low risk")]
        let plainLines = ProgressBoard.render(rows: rows, footer: "f", frame: nil, width: 80, maxRows: 5, ansi: plain)
        XCTAssertFalse(plainLines.joined().contains("\u{1B}["))

        let colour = Ansi(enabled: true)
        let coloured = ProgressBoard.render(rows: rows, footer: "f", frame: nil, width: 80, maxRows: 5, ansi: colour)
        XCTAssertTrue(coloured[0].contains("\u{1B}[32m✓\u{1B}[0m"), coloured[0])   // green marker
        XCTAssertFalse(coloured[0].contains("…"))                                    // nothing clipped mid-escape
    }

    func testMarkersMatchTheInteractiveBrowser() {
        XCTAssertEqual(ProgressBoard.marker(for: .queued).0, "·")
        XCTAssertEqual(ProgressBoard.marker(for: .working).0, "~")
        XCTAssertEqual(ProgressBoard.marker(for: .downloading).0, "↓")
        XCTAssertEqual(ProgressBoard.marker(for: .clean).0, "✓")
        XCTAssertEqual(ProgressBoard.marker(for: .noteworthy).0, "⚠")
        XCTAssertEqual(ProgressBoard.marker(for: .failed).0, "✗")
        XCTAssertEqual(ProgressBoard.marker(for: .skipped).0, "–")
    }
}
