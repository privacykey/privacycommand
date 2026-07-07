import Foundation
import privacycommandCore

/// Builds a whole terminal frame as a single string. Pure: given a model and a
/// viewport it returns the bytes to paint, with no I/O and no mutation — so the
/// entire visual layout is unit-testable. The driver updates scroll, calls
/// `frame`, and writes the result in one `write()`.
public enum TUIRenderer {

    /// Layout must agree between the driver (which updates scroll) and the
    /// renderer (which paints), so both go through these.
    public static func bodyHeight(forHeight h: Int) -> Int { max(0, h - 3) }
    public static func listWidth(forWidth w: Int) -> Int { min(34, max(16, w / 2)) }

    static let minWidth = 40
    static let minHeight = 6

    public static func frame(model: AppBrowserModel, width: Int, height: Int, ansi: Ansi) -> String {
        guard width >= minWidth, height >= minHeight else {
            return "\u{1B}[H\u{1B}[2J" + "terminal too small (need \(minWidth)x\(minHeight))"
        }

        let bodyH = bodyHeight(forHeight: height)
        let listW = listWidth(forWidth: width)
        let detailW = max(1, width - listW - 1)

        var rows: [String] = []
        rows.append(titleRow(model, width: width, ansi: ansi))
        rows.append(filterRow(model, width: width, ansi: ansi))

        let listRows = listPane(model, width: listW, height: bodyH, ansi: ansi)
        let detailRows = detailPane(model, width: detailW, height: bodyH, ansi: ansi)
        for i in 0 ..< bodyH {
            let left = i < listRows.count ? listRows[i] : fit("", listW, ansi: ansi)
            let right = i < detailRows.count ? detailRows[i] : ""
            rows.append(left + ansi.paint("│", .dim) + right)
        }

        rows.append(footerRow(width: width, ansi: ansi))

        // Assemble: home, then each row cleared to EOL, CRLF between (raw mode).
        var out = "\u{1B}[H"
        for (i, row) in rows.enumerated() {
            out += row + "\u{1B}[K"
            if i < rows.count - 1 { out += "\r\n" }
        }
        out += "\u{1B}[J"   // clear anything below the last row
        return out
    }

    // MARK: - Header / footer

    private static func titleRow(_ m: AppBrowserModel, width: Int, ansi: Ansi) -> String {
        let title = fitPlain(" auditctl — static app browser", width)
        return ansi.paint(title, .reverse, .bold)
    }

    private static func filterRow(_ m: AppBrowserModel, width: Int, ansi: Ansi) -> String {
        let sortName = m.sort == .name ? "name" : "risk"
        let right = "sort:\(sortName)  \(m.visibleCount)/\(m.totalCount)  analyzed \(m.analyzedCount) "
        let caret = ansi.paint("▏", .dim)
        let leftPlain = " Filter: \(m.filter)"
        // Reserve room for the right-hand status; pad the gap between.
        let gap = max(1, width - leftPlain.count - 1 - right.count)
        let line = ansi.paint(" Filter: ", .cyan) + m.filter + caret
                 + String(repeating: " ", count: gap) + ansi.paint(right, .dim)
        return line
    }

    private static func footerRow(width: Int, ansi: Ansi) -> String {
        let hints = " ↑↓ move · type to filter · Tab sort · ⏎ re-scan · Esc clear/quit · ^C quit"
        return ansi.paint(fitPlain(hints, width), .dim)
    }

    // MARK: - List pane

    private static func listPane(_ m: AppBrowserModel, width: Int, height: Int, ansi: Ansi) -> [String] {
        let window = m.visibleWindow(height: height)
        guard !window.isEmpty else {
            var rows = [fit(m.visibleCount == 0 ? "  (no matches)" : "", width, ansi: ansi)]
            while rows.count < height { rows.append(fit("", width, ansi: ansi)) }
            return rows
        }
        var rows: [String] = []
        for (offsetIdx, entry) in window.enumerated() {
            let absolute = m.scrollOffset + offsetIdx
            let selected = absolute == m.selection
            rows.append(listRow(entry, state: m.state(of: entry),
                                width: width, selected: selected, ansi: ansi))
        }
        while rows.count < height { rows.append(fit("", width, ansi: ansi)) }
        return rows
    }

    private static func listRow(_ e: AppEntry, state: AuditState,
                                width: Int, selected: Bool, ansi: Ansi) -> String {
        let (marker, markerColor) = markerFor(state)
        let nameField = fitPlain(e.name, max(0, width - 2))   // 1 marker + 1 space
        if selected {
            return ansi.paint("\(marker) \(nameField)", .reverse)
        }
        return ansi.paint(String(marker), markerColor) + " " + nameField
    }

    private static func markerFor(_ state: AuditState) -> (Character, Ansi.Code) {
        switch state {
        case .notStarted:      return ("·", .dim)
        case .analyzing:       return ("~", .yellow)
        case .failed:          return ("✗", .red)
        case .done(let snap):  return snap.isNoteworthy ? ("⚠", .yellow) : ("✓", .green)
        }
    }

    // MARK: - Detail pane

    private static func detailPane(_ m: AppBrowserModel, width: Int, height: Int, ansi: Ansi) -> [String] {
        var lines = detailLines(m, width: width, ansi: ansi)
        if lines.count > height {
            let more = lines.count - (height - 1)
            lines = Array(lines.prefix(max(0, height - 1)))
            lines.append(ansi.paint(clipPlain("  … \(more) more line\(more == 1 ? "" : "s")", width), .dim))
        }
        while lines.count < height { lines.append("") }
        return lines
    }

    /// One coloured, width-clipped line per row. Colours are applied to whole
    /// lines only (after clipping) so we never slice an ANSI escape in half.
    private static func detailLines(_ m: AppBrowserModel, width: Int, ansi: Ansi) -> [String] {
        guard let app = m.selectedApp else { return [ansi.paint(clipPlain("  nothing selected", width), .dim)] }

        func plain(_ s: String) -> String { clipPlain(" " + s, width) }
        func colored(_ s: String, _ c: Ansi.Code...) -> String { ansi.paint(clipPlain(" " + s, width), c) }

        switch m.state(of: app) {
        case .notStarted, .analyzing:
            return ["", colored("Analyzing \(app.name)…", .yellow)]
        case .failed(let err):
            return [ansi.paint(clipPlain(" \(app.name)", width), .bold), "",
                    colored("analysis failed:", .red), plain("  \(err)")]
        case .done(let s):
            return doneLines(s, width: width, plain: plain, colored: colored, ansi: ansi)
        }
    }

    private static func doneLines(_ s: AuditSnapshot, width: Int,
                                  plain: (String) -> String,
                                  colored: (String, Ansi.Code...) -> String,
                                  ansi: Ansi) -> [String] {
        var out: [String] = []
        let marker = s.isNoteworthy ? "⚠" : "✓"
        out.append(ansi.paint(clipPlain(" \(marker) \(s.name)", width), .bold))
        out.append(plain("\(s.bundleID ?? "no-id")  v\(s.version ?? "?")"))
        out.append("")
        out.append(colored("Risk: \(s.tier.label) (\(s.riskScore)/100)", tierColor(s.tier), .bold))
        out.append(plain("Signing: \(s.signing)"))
        out.append(plain("Sandbox: \(s.sandboxed ? "yes" : "no")"))
        out.append(plain("Arch: \(s.architectures.joined(separator: ", "))"))
        out.append(plain("Components: \(s.components.frameworks) fw · \(s.components.xpc) xpc · "
                         + "\(s.components.helpers) helpers · \(s.components.loginItems) login"))
        if !s.capabilities.isEmpty { out.append(plain("Capabilities: \(s.capabilities.joined(separator: ", "))")) }
        if !s.privacyKeys.isEmpty { out.append(plain("Privacy keys: \(s.privacyKeys.joined(separator: ", "))")) }

        if !s.signals.isEmpty {
            out.append("")
            out.append(colored("Signals", .cyan, .bold))
            for sig in s.signals { out.append(plain("• \(sig)")) }
        }
        if !s.findings.isEmpty {
            out.append("")
            out.append(colored("Findings (\(s.findings.count))", .cyan, .bold))
            for f in orderedFindings(s.findings) {
                out.append(colored("[\(f.severity.rawValue)] \(f.message)", severityColor(f.severity)))
            }
        }
        return out
    }

    private static func orderedFindings(_ f: [AuditSnapshot.FindingLine]) -> [AuditSnapshot.FindingLine] {
        let rank: (Finding.Severity) -> Int = { switch $0 { case .error: return 0; case .warn: return 1; case .info: return 2 } }
        return f.sorted { rank($0.severity) < rank($1.severity) }
    }

    // MARK: - Colour maps (kept local to the TUI; the one-shot command has its own)

    private static func tierColor(_ t: RiskTier) -> Ansi.Code {
        switch t {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        case .critical: return .brightRed
        }
    }

    private static func severityColor(_ s: Finding.Severity) -> Ansi.Code {
        switch s {
        case .error: return .red
        case .warn: return .yellow
        case .info: return .dim
        }
    }

    // MARK: - Width helpers (grapheme-count as the width proxy)

    /// Clip to `width` graphemes, adding an ellipsis when truncated.
    static func clipPlain(_ s: String, _ width: Int) -> String {
        if width <= 0 { return "" }
        if s.count <= width { return s }
        if width == 1 { return "…" }
        return String(s.prefix(width - 1)) + "…"
    }

    /// Clip then right-pad to exactly `width` graphemes.
    static func fitPlain(_ s: String, _ width: Int) -> String {
        let clipped = clipPlain(s, width)
        return clipped + String(repeating: " ", count: max(0, width - clipped.count))
    }

    /// `fitPlain` but returns an (uncoloured) cell; kept for symmetry with the
    /// coloured call sites so empty cells still occupy their width.
    static func fit(_ s: String, _ width: Int, ansi: Ansi) -> String {
        fitPlain(s, width)
    }
}
