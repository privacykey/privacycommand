import XCTest
@testable import privacycommandCore

/// Covers the pure JSON parsing in `HomebrewCaskInventory` — the part that
/// turns `brew outdated`/`brew info` output into preview targets. No Homebrew
/// installation is required; the fixtures are captured from real `--json=v2`
/// output.
final class HomebrewCaskInventoryTests: XCTestCase {

    // MARK: - parseOutdated

    func testParseOutdatedExtractsVersionsAndSkipsPinned() throws {
        let json = """
        {
          "formulae": [],
          "casks": [
            {"name":"firefox","installed_versions":["151.0.4"],"current_version":"152.0.1","pinned":false,"pinned_version":null},
            {"name":"google-chrome","installed_versions":["147.0.7727.102"],"current_version":"149.0.7827.156","pinned":false,"pinned_version":null},
            {"name":"locked","installed_versions":["1.0"],"current_version":"2.0","pinned":true,"pinned_version":"1.0"}
          ]
        }
        """.data(using: .utf8)!

        let casks = try HomebrewCaskInventory.parseOutdated(json)

        // The pinned cask is dropped — `brew upgrade` won't touch it.
        XCTAssertEqual(casks.map(\.token), ["firefox", "google-chrome"])

        let firefox = try XCTUnwrap(casks.first { $0.token == "firefox" })
        XCTAssertEqual(firefox.installedVersion, "151.0.4")
        XCTAssertEqual(firefox.availableVersion, "152.0.1")
    }

    func testParseOutdatedEmptyList() throws {
        let json = #"{"formulae":[],"casks":[]}"#.data(using: .utf8)!
        XCTAssertTrue(try HomebrewCaskInventory.parseOutdated(json).isEmpty)
    }

    // MARK: - parseAppTargets

    func testParseAppTargetsResolvesPathsWithFallback() {
        let json = """
        {
          "casks": [
            {"token":"firefox","artifacts":[{"app":["Firefox.app"],"target":"/Applications/Firefox.app"}]},
            {"token":"no-target","artifacts":[{"app":["NoTarget.app"]}]},
            {"token":"not-an-app","artifacts":[{"uninstall":[{"quit":["com.x"]}]}]}
          ]
        }
        """.data(using: .utf8)!

        let appDir = URL(fileURLWithPath: "/Custom/Apps")
        let map = HomebrewCaskInventory.parseAppTargets(json, appDir: appDir)

        // Explicit `target` wins.
        XCTAssertEqual(map["firefox"], URL(fileURLWithPath: "/Applications/Firefox.app"))
        // No `target` → fall back to <appDir>/<app name>.
        XCTAssertEqual(map["no-target"], appDir.appendingPathComponent("NoTarget.app"))
        // A cask that installs no app has no entry.
        XCTAssertNil(map["not-an-app"])
    }
}
