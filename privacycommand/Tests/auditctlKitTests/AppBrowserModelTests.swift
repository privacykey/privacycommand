import XCTest
import Foundation
import privacycommandCore
@testable import auditctlKit

final class AppBrowserModelTests: XCTestCase {

    private func model(_ names: [String]) -> AppBrowserModel {
        AppBrowserModel(apps: names.map {
            AppEntry(name: $0, url: URL(fileURLWithPath: "/Applications/\($0).app"))
        })
    }

    private func snap(_ name: String, tier: RiskTier, score: Int, noteworthy: Bool) -> AuditSnapshot {
        AuditSnapshot(name: name, bundleID: "id.\(name)", version: "1.0", architectures: ["arm64"],
                      signing: "sig", sandboxed: true, tier: tier, riskScore: score,
                      isNoteworthy: noteworthy, headline: "\(tier.label) risk",
                      capabilities: [], privacyKeys: [],
                      components: .init(frameworks: 0, xpc: 0, helpers: 0, loginItems: 0),
                      signals: [], findings: [])
    }

    private func names(_ m: AppBrowserModel) -> [String] { m.visible.map(\.name) }

    func testInitialSelectionZero() {
        let m = model(["Alpha", "Bravo"])
        XCTAssertEqual(m.selection, 0)
        XCTAssertEqual(m.selectedApp?.name, "Alpha")
    }

    func testDefaultSortIsAlphabetical() {
        let m = model(["Charlie", "alpha", "Bravo"])
        XCTAssertEqual(names(m), ["alpha", "Bravo", "Charlie"])
    }

    func testFilterSubstringCaseInsensitive() {
        var m = model(["Safari", "Slack", "Notes"])
        m.appendFilter("s"); m.appendFilter("l")   // "sl"
        XCTAssertEqual(names(m), ["Slack"])
    }

    func testMoveClampsAtBounds() {
        var m = model(["A", "B", "C"])
        m.move(-1); XCTAssertEqual(m.selection, 0)
        m.move(1);  XCTAssertEqual(m.selection, 1)
        m.move(100); XCTAssertEqual(m.selection, 2)
    }

    func testFilterClampsSelection() {
        var m = model(["Alpha", "Beta", "Gamma"])
        m.moveToEnd()
        XCTAssertEqual(m.selection, 2)
        m.appendFilter("a")               // matches all three (Alpha, Beta, Gamma) → still 3
        m.appendFilter("l")               // "al" → only Alpha
        XCTAssertEqual(names(m), ["Alpha"])
        XCTAssertEqual(m.selection, 0)    // clamped from 2
    }

    func testDeleteAndClearFilter() {
        var m = model(["Alpha", "Beta"])
        m.appendFilter("b"); XCTAssertEqual(names(m), ["Beta"])
        m.deleteFilterChar(); XCTAssertEqual(names(m).count, 2)
        m.appendFilter("a"); m.clearFilter()
        XCTAssertTrue(m.filterIsEmpty)
        XCTAssertEqual(names(m).count, 2)
    }

    func testCycleSortToggles() {
        var m = model(["A"])
        XCTAssertEqual(m.sort, .name)
        m.cycleSort(); XCTAssertEqual(m.sort, .risk)
        m.cycleSort(); XCTAssertEqual(m.sort, .name)
    }

    func testSetAndReadState() {
        var m = model(["Alpha"])
        let app = m.selectedApp!
        XCTAssertEqual(m.state(of: app), .notStarted)
        m.setState(.analyzing, forPath: app.path)
        XCTAssertEqual(m.state(of: app), .analyzing)
    }

    func testReanalyzeSelectedResetsState() {
        var m = model(["Alpha"])
        let app = m.selectedApp!
        m.setState(.done(snap("Alpha", tier: .low, score: 0, noteworthy: false)), forPath: app.path)
        m.reanalyzeSelected()
        XCTAssertEqual(m.state(of: app), .notStarted)
    }

    func testAnalyzedCount() {
        var m = model(["A", "B", "C"])
        XCTAssertEqual(m.analyzedCount, 0)
        m.setState(.done(snap("A", tier: .low, score: 1, noteworthy: false)),
                   forPath: "/Applications/A.app")
        m.setState(.analyzing, forPath: "/Applications/B.app")
        XCTAssertEqual(m.analyzedCount, 1)   // only .done counts
    }

    func testSortByRiskOrdersAnalyzedFirst() {
        var m = model(["Alpha", "Bravo", "Charlie"])
        m.setState(.done(snap("Bravo", tier: .medium, score: 55, noteworthy: true)),
                   forPath: "/Applications/Bravo.app")
        m.setState(.done(snap("Charlie", tier: .low, score: 8, noteworthy: false)),
                   forPath: "/Applications/Charlie.app")
        m.cycleSort()   // → risk
        XCTAssertEqual(names(m), ["Bravo", "Charlie", "Alpha"])
    }

    func testUpdateScrollKeepsSelectionVisible() {
        var m = model((1...8).map { "App\($0)" })
        m.move(5)                                  // select index 5
        m.updateScroll(viewportHeight: 3)
        XCTAssertEqual(m.scrollOffset, 3)          // 5 - 3 + 1
        let window = m.visibleWindow(height: 3)
        XCTAssertEqual(window.count, 3)
        XCTAssertEqual(window.last?.name, m.selectedApp?.name)
    }

    func testVisibleWindowClampsToCount() {
        var m = model(["A", "B"])
        m.updateScroll(viewportHeight: 10)
        XCTAssertEqual(m.visibleWindow(height: 10).count, 2)
        XCTAssertEqual(m.scrollOffset, 0)
    }
}
