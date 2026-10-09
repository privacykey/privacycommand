import Foundation

/// Lays out the live progress board `preview` / `upgrade` draw while they
/// work: one row per app plus a footer carrying the spinner, every line
/// clipped to the terminal so nothing wraps (a wrapped line would break the
/// redraw-in-place cursor maths). Pure — rows, a width and a row budget in,
/// lines out — so the layout is unit-testable. Markers and colours match the
/// interactive browser's list: `·` queued, `~` working, `↓` downloading,
/// `✓` clean, `⚠` noteworthy, `✗` failed, `–` skipped.
public enum ProgressBoard {

    public struct Row: Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case queued
            case working
            case downloading
            case clean
            case noteworthy
            case failed
            case skipped

            /// Finished one way or another — the first rows hidden when the
            /// board is taller than the terminal.
            public var isDone: Bool {
                switch self {
                case .clean, .noteworthy, .failed, .skipped: return true
                case .queued, .working, .downloading:        return false
                }
            }
        }

        public var id: String
        public var state: State
        public var name: String
        /// e.g. `3.7.0 → 3.7.4`. The first column dropped on a narrow terminal.
        public var version: String?
        /// What's happening to it right now, or how it ended.
        public var status: String

        public init(id: String, state: State, name: String, version: String? = nil, status: String) {
            self.id = id
            self.state = state
            self.name = name
            self.version = version
            self.status = status
        }
    }

    public static func marker(for state: Row.State) -> (Character, Ansi.Code) {
        switch state {
        case .queued:      return ("·", .dim)
        case .working:     return ("~", .yellow)
        case .downloading: return ("↓", .cyan)
        case .clean:       return ("✓", .green)
        case .noteworthy:  return ("⚠", .yellow)
        case .failed:      return ("✗", .red)
        case .skipped:     return ("–", .dim)
        }
    }

    static let indent = 2
    static let maxNameWidth = 28
    static let maxVersionWidth = 24
    /// The status is the useful column, so it keeps at least this much before
    /// the version column goes (a 50-column terminal shows name + status).
    static let minStatusWidth = 24

    /// The lines to paint, top to bottom: the app rows (at most `maxRows`,
    /// see `visibleRows`), then the footer. Every line is at most `width - 1`
    /// characters, colour excluded; colour is applied per cell after clipping
    /// so an escape sequence is never cut in half.
    public static func render(rows: [Row], footer: String, frame: Character?,
                              width: Int, maxRows: Int, ansi: Ansi) -> [String] {
        let usable = max(0, width - 1)
        var lines: [String] = []

        let (shown, hidden) = visibleRows(rows, maxRows: maxRows)
        if !shown.isEmpty {
            let layout = columns(for: shown, usable: usable)
            for row in shown {
                lines.append(line(row, layout: layout, ansi: ansi))
            }
        }
        if !hidden.isEmpty {
            let done = hidden.filter { $0.state.isDone }.count
            let queued = hidden.filter { $0.state == .queued }.count
            var parts: [String] = []
            if done > 0 { parts.append("\(done) done") }
            if queued > 0 { parts.append("\(queued) queued") }
            let detail = parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
            let text = String(repeating: " ", count: indent) + "… +\(hidden.count) more" + detail
            lines.append(ansi.paint(clip(text, usable), .dim))
        }

        let footerText = frame.map { "\($0) " + footer } ?? footer
        lines.append(clip(footerText, usable))
        return lines
    }

    /// Which rows fit in `maxRows`. In order, but when there are too many,
    /// finished rows are hidden first (their outcome is in the report
    /// anyway), then queued rows from the end — so the rows being worked on
    /// stay visible. One slot is kept for the "… +N more" line.
    public static func visibleRows(_ rows: [Row], maxRows: Int) -> (shown: [Row], hidden: [Row]) {
        guard rows.count > maxRows else { return (rows, []) }
        let budget = max(0, maxRows - 1)
        var keep = Array(rows.indices)
        while keep.count > budget {
            if let i = keep.firstIndex(where: { rows[$0].state.isDone }) {
                keep.remove(at: i)
            } else if let i = keep.lastIndex(where: { rows[$0].state == .queued }) {
                keep.remove(at: i)
            } else {
                keep.removeLast()
            }
        }
        let kept = Set(keep)
        return (keep.map { rows[$0] }, rows.indices.filter { !kept.contains($0) }.map { rows[$0] })
    }

    // MARK: - Layout

    struct Columns {
        var name: Int
        var version: Int      // 0 = column dropped
        var status: Int
    }

    /// Column widths for these rows in `usable` characters: the name column
    /// fits the longest name (capped), the version column the longest version;
    /// the version column goes first when the status would get too narrow,
    /// then the name column shrinks.
    static func columns(for rows: [Row], usable: Int) -> Columns {
        let fixed = indent + 1 + 1   // marker + space
        var name = min(maxNameWidth, rows.map { $0.name.count }.max() ?? 0)
        var version = min(maxVersionWidth, rows.compactMap { $0.version?.count }.max() ?? 0)

        func status() -> Int {
            usable - fixed - name - 2 - (version > 0 ? version + 2 : 0)
        }
        if version > 0 && status() < minStatusWidth { version = 0 }
        if status() < minStatusWidth {
            name = max(4, min(name, usable - fixed - 2 - 8))
        }
        return Columns(name: name, version: version, status: max(0, status()))
    }

    static func line(_ row: Row, layout: Columns, ansi: Ansi) -> String {
        let (marker, color) = marker(for: row.state)
        let dimmed = row.state == .queued || row.state == .skipped
        var out = String(repeating: " ", count: indent) + ansi.paint(String(marker), color) + " "
        out += ansi.paint(pad(row.name, layout.name), dimmed ? [.dim] : [])
        if layout.version > 0 {
            out += "  " + ansi.paint(pad(row.version ?? "", layout.version), .dim)
        }
        if layout.status > 0 {
            out += "  " + ansi.paint(clip(row.status, layout.status), dimmed ? [.dim] : [])
        }
        return out
    }

    static func clip(_ s: String, _ width: Int) -> String {
        if width <= 0 { return "" }
        if s.count <= width { return s }
        if width == 1 { return "…" }
        return String(s.prefix(width - 1)) + "…"
    }

    static func pad(_ s: String, _ width: Int) -> String {
        let clipped = clip(s, width)
        return clipped + String(repeating: " ", count: max(0, width - clipped.count))
    }
}
