import Foundation
import privacycommandCore
import auditctlKit

/// `auditctl --tui-selftest` — a hidden, headless driver of the TUI pipeline
/// (decode → reduce → model → render). It feeds scripted keystrokes to a
/// synthetic model and prints the resulting frames with escape sequences
/// stripped, so the interactive layout can be eyeballed / grepped in CI
/// without a real terminal. Not shown in `--help`.
enum TUISelfTest {

    static func run() -> Never {
        let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel"]
        var model = AppBrowserModel(apps: names.map {
            AppEntry(name: $0, url: URL(fileURLWithPath: "/Applications/\($0).app"))
        })
        model.setState(.analyzing, forPath: "/Applications/Alpha.app")
        model.setState(.done(sample(name: "Bravo", tier: .medium, noteworthy: true,
                                     findings: [(.error, "Hard-coded secret in binary"),
                                                (.warn, "Arbitrary network loads allowed")])),
                       forPath: "/Applications/Bravo.app")
        model.setState(.done(sample(name: "Charlie", tier: .low, noteworthy: false, findings: [])),
                       forPath: "/Applications/Charlie.app")

        let ansi = Ansi(enabled: false)
        let (width, height) = (80, 24)

        func show(_ label: String) {
            model.updateScroll(viewportHeight: TUIRenderer.bodyHeight(forHeight: height))
            print("=== \(label) ===")
            print(strip(TUIRenderer.frame(model: model, width: width, height: height, ansi: ansi)))
        }
        func feed(_ bytes: [UInt8]) {
            for ev in InputDecoder.decode(bytes) {
                _ = BrowserReducer.apply(ev, to: &model, pageStep: 10)
            }
        }

        show("initial — Alpha selected (analyzing)")
        feed([0x1b, 0x5b, 0x42])                 // ↓ → Bravo
        show("after Down — Bravo (noteworthy, findings)")
        feed(Array("har".utf8))                  // filter → Charlie
        show("after typing 'har' — filtered to Charlie")
        feed([0x7f, 0x7f, 0x7f])                 // Backspace ×3 → clear filter
        show("after Backspace ×3 — filter cleared")
        feed([0x09])                             // Tab → sort by risk
        show("after Tab — sort: risk")
        exit(0)
    }

    private static func sample(name: String, tier: RiskTier, noteworthy: Bool,
                               findings: [(Finding.Severity, String)]) -> AuditSnapshot {
        AuditSnapshot(
            name: name,
            bundleID: "com.example.\(name.lowercased())",
            version: "1.2.3",
            architectures: ["arm64", "x86_64"],
            signing: "Example Inc (ABCDE12345) · notarized · hardened runtime",
            sandboxed: true,
            tier: tier,
            riskScore: tier == .low ? 8 : 55,
            isNoteworthy: noteworthy,
            headline: "\(tier.label) risk",
            capabilities: ["network", "camera*"],
            privacyKeys: ["NSCameraUsageDescription"],
            components: .init(frameworks: 12, xpc: 2, helpers: 1, loginItems: 1),
            signals: noteworthy ? ["Tracking SDKs: ExampleAnalytics"] : [],
            findings: findings.map { .init(severity: $0.0, message: $0.1) })
    }

    /// Strip ANSI/CSI escapes and carriage returns so a frame reads cleanly when
    /// printed to an ordinary (cooked) terminal.
    private static func strip(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c == "\u{1B}" {
                if let n = it.next(), n == "[" || n == "]" || n == "(" {
                    while let d = it.next() { if (0x40...0x7E).contains(d.value) { break } }
                }
                continue
            }
            if c == "\r" { continue }
            out.append(c)
        }
        return String(out)
    }
}
