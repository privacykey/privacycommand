import Foundation

/// Renders a `RunReport` as a self-contained HTML document. No external assets,
/// no scripts. Intended to be opened in any browser or printed to PDF.
public enum HTMLExporter {

    public static func write(report: RunReport, to url: URL) throws {
        let html = render(report: report)
        try html.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    public static func render(report: RunReport) -> String {
        var s = ""
        s += "<!doctype html>\n"
        s += "<html><head><meta charset='utf-8'>\n"
        s += "<title>\(escape(report.bundle.bundleName ?? "Untitled")) — privacycommand</title>\n"
        s += "<style>\n\(css)\n</style></head><body>\n"
        s += "<h1>\(escape(report.bundle.bundleName ?? "Untitled"))</h1>\n"
        s += "<p class='meta'>\(escape(report.bundle.bundleID ?? "")) · v\(escape(report.bundle.bundleVersion ?? ""))<br/>"
        s += "Auditor v\(escape(report.auditorVersion)) · \(formatDate(report.startedAt)) → \(formatDate(report.endedAt))</p>\n"

        s += renderFidelity(report.fidelityNotes)
        s += renderStaticReport(report.staticReport)
        s += renderSummary(report.summary)
        s += renderEvents(report.events)

        s += "</body></html>\n"
        return s
    }

    // MARK: - Sections

    private static func renderFidelity(_ notes: [String]) -> String {
        guard !notes.isEmpty else { return "" }
        var s = "<section class='fidelity'><h2>Fidelity notes</h2><ul>\n"
        for n in notes { s += "<li>\(escape(n))</li>\n" }
        s += "</ul></section>\n"
        return s
    }

    private static func renderStaticReport(_ r: StaticReport) -> String {
        var s = "<section><h2>Static analysis <span class='badge'>static</span></h2>\n"
        s += "<h3>Code signing</h3><table>"
        s += row("Team identifier", r.codeSigning.teamIdentifier ?? "—")
        s += row("Identifier",      r.codeSigning.signingIdentifier ?? "—")
        s += row("Hardened Runtime", r.codeSigning.hardenedRuntime ? "yes" : "no")
        s += row("Validates",       r.codeSigning.validates ? "yes" : "no")
        s += row("Notarization",    String(describing: r.notarization))
        s += "</table>"

        s += "<h3>Declared privacy keys</h3>"
        if r.declaredPrivacyKeys.isEmpty {
            s += "<p class='dim'>(none)</p>"
        } else {
            s += "<table><tr><th>Key</th><th>Category</th><th>Purpose string</th></tr>"
            for k in r.declaredPrivacyKeys {
                s += "<tr><td><code>\(escape(k.rawKey))</code></td><td>\(escape(k.category.rawValue))</td><td>\(escape(k.purposeString.isEmpty ? "(empty)" : k.purposeString))</td></tr>"
            }
            s += "</table>"
        }

        s += "<h3>Inferred capabilities</h3>"
        if r.inferredCapabilities.isEmpty {
            s += "<p class='dim'>(none)</p>"
        } else {
            s += "<table><tr><th>Category</th><th>Confidence</th><th>Evidence</th><th>Note</th></tr>"
            for c in r.inferredCapabilities {
                let note = c.declaredButNotJustified ? "declared but no symbol/framework"
                    : c.inferredButNotDeclared ? "inferred but not declared"
                    : ""
                s += "<tr><td>\(escape(c.category.rawValue))</td><td>\(escape(c.confidence.rawValue))</td><td>\(escape(c.evidence.joined(separator: "; ")))</td><td>\(escape(note))</td></tr>"
            }
            s += "</table>"
        }

        if !r.warnings.isEmpty {
            s += "<h3>Findings</h3><ul>"
            for f in r.warnings {
                s += "<li><strong>\(escape(f.severity.rawValue))</strong>: \(escape(f.message))</li>"
            }
            s += "</ul>"
        }

        if !r.hardcodedDomains.isEmpty {
            s += "<h3>Hard-coded domains</h3><pre>\(escape(r.hardcodedDomains.joined(separator: "\n")))</pre>"
        }
        if !r.hardcodedPaths.isEmpty {
            s += "<h3>Hard-coded paths</h3><pre>\(escape(r.hardcodedPaths.joined(separator: "\n")))</pre>"
        }
        s += "</section>"
        return s
    }

    private static func renderSummary(_ summary: RunSummary) -> String {
        var s = "<section><h2>Run summary <span class='badge bestEffort'>best-effort</span></h2>"
        // Risk score at the top — most consequential single number.
        let r = summary.riskScore
        s += "<div class='risk risk-\(r.tier.rawValue)'>"
        s += "<div class='risk-headline'><span class='risk-tier'>\(escape(r.tier.label))</span> <span class='risk-num'>\(r.score)/100</span></div>"
        if !r.contributors.isEmpty {
            s += "<ul class='risk-contributors'>"
            for c in r.contributors.prefix(8) {
                s += "<li><span class='risk-impact'>+\(c.impact)</span> \(escape(c.detail)) <span class='risk-source'>(\(escape(c.source.rawValue)))</span></li>"
            }
            s += "</ul>"
        }
        s += "</div>"
        s += "<table>"
        s += row("Processes observed",        "\(summary.processCount)")
        s += row("File events",               "\(summary.fileEventCount)")
        s += row("Network events",            "\(summary.networkEventCount)")
        s += row("Surprising events",         "\(summary.surprisingEventCount)")
        s += "</table>"
        if !summary.topRemoteHosts.isEmpty {
            s += "<h3>Top remote hosts</h3><table><tr><th>Host</th><th>Conns</th><th>Bytes Tx</th><th>Bytes Rx</th></tr>"
            for h in summary.topRemoteHosts {
                s += "<tr><td>\(escape(h.host))</td><td>\(h.connectionCount)</td><td>\(h.bytesSent)</td><td>\(h.bytesReceived)</td></tr>"
            }
            s += "</table>"
        }
        s += "</section>"
        return s
    }

    private static func renderEvents(_ events: [DynamicEvent]) -> String {
        guard !events.isEmpty else { return "" }
        var s = "<section><h2>Event log</h2><table><tr><th>Time</th><th>Kind</th><th>Detail</th></tr>"
        for e in events {
            switch e {
            case .process(let p):
                s += "<tr><td>\(formatDate(p.timestamp))</td><td>process.\(p.kind.rawValue)</td><td>[\(p.pid)] \(escape(p.path))</td></tr>"
            case .file(let f):
                s += "<tr><td>\(formatDate(f.timestamp))</td><td>file.\(f.op.rawValue)</td><td>[\(f.pid)] \(escape(f.path)) <em>\(escape(f.risk.rawValue))</em></td></tr>"
            case .network(let n):
                let host = n.remoteHostname ?? n.remoteEndpoint.address
                s += "<tr><td>\(formatDate(n.lastSeen))</td><td>net.\(n.netProto.rawValue)</td><td>[\(n.pid)] \(escape(host)):\(n.remoteEndpoint.port)</td></tr>"
            }
        }
        s += "</table></section>"
        return s
    }

    // MARK: - Helpers

    private static func row(_ k: String, _ v: String) -> String {
        "<tr><td class='dim'>\(escape(k))</td><td>\(escape(v))</td></tr>"
    }

    private static func formatDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; max-width: 980px; margin: 32px auto; padding: 0 20px; color: #1a1a1a; }
    h1 { margin-bottom: 4px; }
    .meta { color: #666; margin-top: 0; }
    section { margin: 28px 0; }
    table { border-collapse: collapse; width: 100%; margin: 8px 0; }
    th, td { border: 1px solid #e2e2e2; padding: 6px 8px; vertical-align: top; text-align: left; }
    th { background: #f6f6f6; }
    pre { background: #f6f6f6; padding: 8px; overflow-x: auto; white-space: pre-wrap; word-break: break-all; font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; }
    code { font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; }
    .dim { color: #888; }
    .badge { font-size: 11px; padding: 2px 6px; border-radius: 999px; background: #eee; color: #333; vertical-align: middle; margin-left: 8px; }
    .badge.bestEffort { background: #fff1d6; color: #884d00; }
    .fidelity { background: #fafafa; padding: 12px 16px; border-left: 3px solid #c0c0c0; }
    .risk { padding: 14px 18px; border-radius: 8px; margin: 10px 0 16px; }
    .risk-low      { background: #ecfdf3; border: 1px solid #b9efc5; }
    .risk-medium   { background: #fffbeb; border: 1px solid #fbe7a3; }
    .risk-high     { background: #fff5e6; border: 1px solid #ffd6a3; }
    .risk-critical { background: #fef2f2; border: 1px solid #fcb5b5; }
    .risk-headline { font-size: 18px; font-weight: 700; }
    .risk-tier { text-transform: uppercase; letter-spacing: 0.04em; margin-right: 8px; }
    .risk-num { color: #555; font-weight: 600; }
    .risk-contributors { margin: 10px 0 0; padding-left: 20px; }
    .risk-contributors li { margin: 3px 0; }
    .risk-impact { display: inline-block; min-width: 32px; font-variant-numeric: tabular-nums; color: #b45309; font-weight: 600; }
    .risk-source { color: #888; font-size: 11px; }
    """
}
