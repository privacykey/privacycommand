import XCTest
import Foundation
import privacycommandCore
@testable import auditctlKit

final class TUIRendererTests: XCTestCase {

    private let ansi = Ansi(enabled: false)   // deterministic, colour-free

    private func model(_ names: [String]) -> AppBrowserModel {
        AppBrowserModel(apps: names.map {
            AppEntry(name: $0, url: URL(fileURLWithPath: "/Applications/\($0).app"))
        })
    }

    private func snap(_ name: String, tier: RiskTier, score: Int, noteworthy: Bool,
                      findings: [(Finding.Severity, String)] = []) -> AuditSnapshot {
        AuditSnapshot(name: name, bundleID: "id.\(name)", version: "1.0", architectures: ["arm64"],
                      signing: "sig", sandboxed: false, tier: tier, riskScore: score,
                      isNoteworthy: noteworthy, headline: "h", capabilities: [], privacyKeys: [],
                      components: .init(frameworks: 0, xpc: 0, helpers: 0, loginItems: 0),
                      signals: [], findings: findings.map { .init(severity: $0.0, message: $0.1) })
    }

    func testFrameContainsChromeElements() {
        let m = model(["Alpha", "Bravo"])
        let f = TUIRenderer.frame(model: m, width: 80, height: 24, ansi: ansi)
        XCTAssertTrue(f.contains("auditctl — static app browser"))
        XCTAssertTrue(f.contains("Alpha"))
        XCTAssertTrue(f.contains("Bravo"))
        XCTAssertTrue(f.contains("type to filter"))
    }

    func testAnalyzingStateShownInDetail() {
        var m = model(["Alpha"])
        m.setState(.analyzing, forPath: "/Applications/Alpha.app")
        let f = TUIRenderer.frame(model: m, width: 80, height: 24, ansi: ansi)
        XCTAssertTrue(f.contains("Analyzing Alpha"))
    }

    func testDoneDetailShowsSections() {
        var m = model(["Alpha"])
        m.setState(.done(snap("Alpha", tier: .high, score: 70, noteworthy: true,
                              findings: [(.error, "boom")])),
                   forPath: "/Applications/Alpha.app")
        let f = TUIRenderer.frame(model: m, width: 100, height: 30, ansi: ansi)
        XCTAssertTrue(f.contains("Risk: High (70/100)"))
        XCTAssertTrue(f.contains("Findings (1)"))
        XCTAssertTrue(f.contains("[error] boom"))
    }

    func testFilterReflectedInFrame() {
        var m = model(["Safari", "Slack", "Notes"])
        m.appendFilter("s"); m.appendFilter("l")   // "sl" → Slack only
        let f = TUIRenderer.frame(model: m, width: 80, height: 24, ansi: ansi)
        XCTAssertTrue(f.contains("Filter: sl"))
        XCTAssertTrue(f.contains("Slack"))
        XCTAssertFalse(f.contains("Notes"))
    }

    func testTooSmallTerminal() {
        let m = model(["A"])
        let f = TUIRenderer.frame(model: m, width: 20, height: 4, ansi: ansi)
        XCTAssertTrue(f.contains("terminal too small"))
    }

    func testDetailOverflowNote() {
        var m = model(["Alpha"])
        let many = (1...30).map { (Finding.Severity.warn, "finding \($0)") }
        m.setState(.done(snap("Alpha", tier: .medium, score: 40, noteworthy: true, findings: many)),
                   forPath: "/Applications/Alpha.app")
        let f = TUIRenderer.frame(model: m, width: 100, height: 12, ansi: ansi)
        XCTAssertTrue(f.contains("more line"))
    }

    func testNoMatchesMessage() {
        var m = model(["Alpha", "Bravo"])
        for c in "zzz" { m.appendFilter(c) }
        let f = TUIRenderer.frame(model: m, width: 80, height: 24, ansi: ansi)
        XCTAssertTrue(f.contains("(no matches)"))
    }
}
