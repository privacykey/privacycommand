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

    // MARK: - parseOutdatedFormulae

    func testParseOutdatedFormulaeSkipsPinned() {
        let json = """
        {
          "formulae": [
            {"name":"awscli","installed_versions":["2.1"],"current_version":"2.2","pinned":false},
            {"name":"held","installed_versions":["1.0"],"current_version":"2.0","pinned":true}
          ],
          "casks": []
        }
        """.data(using: .utf8)!
        XCTAssertEqual(HomebrewCaskInventory.parseOutdatedFormulae(json), ["awscli"])
        XCTAssertEqual(HomebrewCaskInventory.parseOutdatedFormulae(Data()), [])
    }

    // MARK: - parseInstallKinds

    func testParseInstallKindsClassifiesEachCask() {
        // Shapes captured from real `brew info --cask --json=v2` output.
        let json = """
        {
          "casks": [
            {"token":"firefox","name":["Mozilla Firefox"],
             "artifacts":[{"uninstall":[{"quit":"org.mozilla.firefox"}]},{"app":["Firefox.app"],"target":"/Applications/Firefox.app"},{"zap":[{"trash":["~/x"]}]}]},
            {"token":"codex","name":["Codex"],
             "artifacts":[{"binary":["bin/codex"],"target":"/opt/homebrew/bin/codex"},{"generate_completions_from_executable":["bin/codex"]},{"zap":[{"rmdir":"~/.codex"}]}]},
            {"token":"gpg-suite","name":["GPG Suite"],
             "artifacts":[{"uninstall":[{"launchctl":["org.gpgtools.updater"],"pkgutil":"org.gpgtools.*"}]},{"pkg":["Install.pkg"]},{"uninstall_postflight_steps":[]}]},
            {"token":"multi-receipt","name":["Multi"],
             "artifacts":[{"pkg":["Multi.pkg",{"choices":[]}]},{"uninstall":[{"pkgutil":["com.a.pkg","com.b.pkg"]}]}]},
            {"token":"acrobat","name":["Adobe Acrobat"],
             "artifacts":[{"suite":["Adobe Acrobat DC"]}]},
            {"token":"a-font","name":["A Font"],
             "artifacts":[{"font":["A.ttf"]}]}
          ]
        }
        """.data(using: .utf8)!

        let appDir = URL(fileURLWithPath: "/Custom/Apps")
        let kinds = HomebrewCaskInventory.parseInstallKinds(json, appDir: appDir)

        XCTAssertEqual(kinds["firefox"], .app(URL(fileURLWithPath: "/Applications/Firefox.app")))
        XCTAssertEqual(kinds["codex"], .other(kinds: ["binary"]))
        XCTAssertEqual(kinds["gpg-suite"],
                       .pkg(receipts: ["org.gpgtools.*"], pkgPath: "Install.pkg", names: ["GPG Suite"]))
        XCTAssertEqual(kinds["multi-receipt"],
                       .pkg(receipts: ["com.a.pkg", "com.b.pkg"], pkgPath: "Multi.pkg", names: ["Multi"]))
        XCTAssertEqual(kinds["acrobat"], .suite(appDir.appendingPathComponent("Adobe Acrobat DC")))
        XCTAssertEqual(kinds["a-font"], .other(kinds: ["font"]))
    }

    func testSkipReasonIsPlainLanguage() {
        XCTAssertEqual(HomebrewCaskInventory.skipReason(forKinds: ["binary"]),
                       "installs a command-line tool, not an app")
        XCTAssertEqual(HomebrewCaskInventory.skipReason(forKinds: ["font", "binary"]),
                       "installs fonts and a command-line tool, not an app")
        XCTAssertEqual(HomebrewCaskInventory.skipReason(forKinds: ["audio_unit_plugin"]),
                       "installs audio unit plugin, not an app")
        XCTAssertEqual(HomebrewCaskInventory.skipReason(forKinds: []), "installs no app")
        XCTAssertEqual(HomebrewCaskInventory.skipReason(forKinds: ["installer"]),
                       "runs its own installer, so the app it installs can't be located")
    }

    // MARK: - .pkg receipts

    func testTopLevelAppPathsFromPkgutilFiles() {
        // `pkgutil --files` lists every path; only the outermost .app counts.
        let files = """
        GPG Keychain.app
        GPG Keychain.app/Contents
        GPG Keychain.app/Contents/Frameworks/Helper.app
        GPG Keychain.app/Contents/Frameworks/Helper.app/Contents/Info.plist
        private/tmp/org.gpgtools/updater_install/GPGSuite_Updater.app/Contents/Info.plist
        usr/local/bin/gpg
        """
        XCTAssertEqual(HomebrewCaskInventory.topLevelAppPaths(pkgutilFiles: files), [
            "GPG Keychain.app",
            "private/tmp/org.gpgtools/updater_install/GPGSuite_Updater.app",
        ])
        XCTAssertEqual(HomebrewCaskInventory.topLevelAppPaths(pkgutilFiles: ""), [])
    }

    func testChoosePrimaryAppPrefersCaskNameThenApplicationsFolder() {
        let keychain = URL(fileURLWithPath: "/Applications/GPG Keychain.app")
        let pinentry = URL(fileURLWithPath: "/usr/local/MacGPG2/libexec/pinentry-mac.app")
        let uninstaller = URL(fileURLWithPath: "/Applications/Uninstall Zoom.app")
        let zoom = URL(fileURLWithPath: "/Applications/zoom.us.app")

        // No name match → the app at the top of an Applications folder.
        XCTAssertEqual(HomebrewCaskInventory.choosePrimaryApp(
            [pinentry, keychain], names: ["GPG Suite"], token: "gpg-suite"), keychain)
        // A cask-name match wins; an uninstaller never does.
        XCTAssertEqual(HomebrewCaskInventory.choosePrimaryApp(
            [uninstaller, zoom], names: ["Zoom"], token: "zoom"), zoom)
        // …unless it's the only candidate.
        XCTAssertEqual(HomebrewCaskInventory.choosePrimaryApp(
            [uninstaller], names: ["Zoom"], token: "zoom"), uninstaller)
        XCTAssertNil(HomebrewCaskInventory.choosePrimaryApp([], names: ["X"], token: "x"))
    }

    /// Live check against this Mac's package receipts — runs only where GPG
    /// Suite (a `.pkg` cask that stages its apps in /private/tmp) is installed.
    func testInstalledAppsFromRealReceipts() throws {
        let keychain = URL(fileURLWithPath: "/Applications/GPG Keychain.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: keychain.path), "GPG Suite not installed")
        let apps = HomebrewCaskInventory.installedApps(forReceipts: ["org.gpgtools.*"])
        XCTAssertTrue(apps.contains(keychain), "found: \(apps.map(\.path))")
        XCTAssertEqual(HomebrewCaskInventory.choosePrimaryApp(apps, names: ["GPG Suite"], token: "gpg-suite"),
                       keychain)
    }
}
