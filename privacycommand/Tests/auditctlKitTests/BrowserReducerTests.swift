import XCTest
import Foundation
@testable import auditctlKit

final class BrowserReducerTests: XCTestCase {

    private func model(_ names: [String]) -> AppBrowserModel {
        AppBrowserModel(apps: names.map {
            AppEntry(name: $0, url: URL(fileURLWithPath: "/Applications/\($0).app"))
        })
    }

    func testDownMovesAndRequestsAnalysis() {
        var m = model(["A", "B", "C"])
        let eff = BrowserReducer.apply(.down, to: &m, pageStep: 5)
        XCTAssertEqual(m.selection, 1)
        XCTAssertEqual(eff, .analyzeSelected)
    }

    func testCharAppendsToFilter() {
        var m = model(["Safari", "Slack"])
        _ = BrowserReducer.apply(.char("s"), to: &m, pageStep: 5)
        _ = BrowserReducer.apply(.char("a"), to: &m, pageStep: 5)   // "sa" → Safari
        XCTAssertEqual(m.visible.map(\.name), ["Safari"])
    }

    func testBackspaceEditsFilter() {
        var m = model(["Safari", "Slack"])
        _ = BrowserReducer.apply(.char("s"), to: &m, pageStep: 5)
        _ = BrowserReducer.apply(.char("l"), to: &m, pageStep: 5)   // "sl" → Slack
        XCTAssertEqual(m.visible.map(\.name), ["Slack"])
        _ = BrowserReducer.apply(.backspace, to: &m, pageStep: 5)   // "s"
        XCTAssertEqual(m.visible.count, 2)
    }

    func testEscapeClearsFilterThenQuits() {
        var m = model(["A", "B"])
        _ = BrowserReducer.apply(.char("a"), to: &m, pageStep: 5)
        XCTAssertEqual(BrowserReducer.apply(.escape, to: &m, pageStep: 5), .analyzeSelected)
        XCTAssertTrue(m.filterIsEmpty)
        XCTAssertEqual(BrowserReducer.apply(.escape, to: &m, pageStep: 5), .quit)
    }

    func testCtrlCQuits() {
        var m = model(["A"])
        XCTAssertEqual(BrowserReducer.apply(.ctrlC, to: &m, pageStep: 5), .quit)
    }

    func testTabCyclesSort() {
        var m = model(["A"])
        _ = BrowserReducer.apply(.tab, to: &m, pageStep: 5)
        XCTAssertEqual(m.sort, .risk)
    }

    func testEnterResetsSelectedState() {
        var m = model(["A"])
        m.setState(.analyzing, forPath: "/Applications/A.app")
        let eff = BrowserReducer.apply(.enter, to: &m, pageStep: 5)
        XCTAssertEqual(m.state(of: m.selectedApp!), .notStarted)
        XCTAssertEqual(eff, .analyzeSelected)
    }

    func testSidewaysArrowsAreNoops() {
        var m = model(["A", "B"])
        XCTAssertEqual(BrowserReducer.apply(.left, to: &m, pageStep: 5), .none)
        XCTAssertEqual(BrowserReducer.apply(.right, to: &m, pageStep: 5), .none)
        XCTAssertEqual(m.selection, 0)
    }

    func testPageDownUsesPageStep() {
        var m = model((1...20).map { "App\($0)" })
        _ = BrowserReducer.apply(.pageDown, to: &m, pageStep: 5)
        XCTAssertEqual(m.selection, 5)
    }
}
