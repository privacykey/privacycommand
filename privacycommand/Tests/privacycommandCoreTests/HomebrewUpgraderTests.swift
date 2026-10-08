import XCTest
@testable import privacycommandCore

final class HomebrewUpgraderTests: XCTestCase {

    func testArgumentsUpgradeOnlyTheNamedCasks() {
        XCTAssertEqual(HomebrewUpgrader.arguments(casks: ["firefox", "tower"], greedy: false),
                       ["upgrade", "--cask", "firefox", "tower"])
    }

    func testGreedyIsPassedThroughSoSelfUpdatingCasksAreIncluded() {
        XCTAssertEqual(HomebrewUpgrader.arguments(casks: ["firefox"], greedy: true),
                       ["upgrade", "--cask", "--greedy", "firefox"])
    }

    func testCommandLineIsWhatAPersonWouldType() {
        XCTAssertEqual(HomebrewUpgrader.commandLine(casks: ["firefox", "tower"], greedy: false),
                       "brew upgrade --cask firefox tower")
        XCTAssertEqual(HomebrewUpgrader.commandLine(casks: ["zoom"], greedy: true),
                       "brew upgrade --cask --greedy zoom")
    }
}
