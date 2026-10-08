import XCTest
@testable import privacycommandCore

/// Covers `CommandLineTool` against throwaway directories standing in for
/// the app bundle, /usr/local/bin and Homebrew's bin directory.
final class CommandLineToolTests: XCTestCase {

    private var root: URL!
    private var app: URL!
    private var bin: URL!
    private var brewBin: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("CommandLineToolTests-\(UUID().uuidString)")
        app = try makeApp(named: "privacycommand.app")
        bin = root.appendingPathComponent("usr-local-bin")
        brewBin = root.appendingPathComponent("homebrew-bin")
        try fm.createDirectory(at: brewBin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore write access so a permission test can't leave debris.
        for dir in [bin, brewBin] {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir!.path)
        }
        try? fm.removeItem(at: root)
    }

    private func makeApp(named name: String) throws -> URL {
        let bundle = root.appendingPathComponent(name)
        let helpers = bundle.appendingPathComponent("Contents/Helpers")
        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)
        let tool = helpers.appendingPathComponent("privacycommand")
        XCTAssertTrue(fm.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8),
                                    attributes: [.posixPermissions: 0o755]))
        return bundle
    }

    private func subject(for app: URL? = nil) -> CommandLineTool {
        CommandLineTool(appBundle: app ?? self.app, installDirectory: bin, searchDirectories: [brewBin])
    }

    // MARK: - Install / uninstall round trip

    func testInstallCreatesDirectoryAndLinkThenUninstallRemovesIt() throws {
        let tool = subject()
        XCTAssertEqual(tool.status(), .notInstalled)

        try tool.install()
        XCTAssertEqual(tool.status(), .installed(link: tool.link))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: tool.link.path), tool.tool.path)

        try tool.install() // already there: no-op, no throw
        try tool.uninstall()
        XCTAssertEqual(tool.status(), .notInstalled)
        XCTAssertFalse(fm.fileExists(atPath: tool.link.path))
    }

    func testUnavailableWithoutEmbeddedBinary() throws {
        let bare = root.appendingPathComponent("Bare.app")
        try fm.createDirectory(at: bare, withIntermediateDirectories: true)
        let tool = subject(for: bare)
        XCTAssertEqual(tool.status(), .unavailable)
        XCTAssertThrowsError(try tool.install()) {
            XCTAssertEqual($0 as? CommandLineTool.Failure, .unavailable)
        }
    }

    func testUninstallWhenNothingIsInstalled() {
        XCTAssertThrowsError(try subject().uninstall()) {
            XCTAssertEqual($0 as? CommandLineTool.Failure, .notInstalled)
        }
    }

    // MARK: - Someone else's file

    func testRegularFileIsReportedAndNeverTouched() throws {
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = subject()
        XCTAssertTrue(fm.createFile(atPath: tool.link.path, contents: Data("mine".utf8)))

        XCTAssertEqual(tool.status(), .occupied(link: tool.link, destination: nil))
        XCTAssertThrowsError(try tool.install())
        XCTAssertThrowsError(try tool.uninstall()) {
            XCTAssertEqual($0 as? CommandLineTool.Failure, .occupied(link: tool.link, destination: nil))
        }
        XCTAssertEqual(fm.contents(atPath: tool.link.path), Data("mine".utf8))
    }

    func testForeignSymlinkIsReportedAndNeverTouched() throws {
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = subject()
        let elsewhere = "/Users/someone/src/privacycommand/.build/release/privacycommand"
        try fm.createSymbolicLink(atPath: tool.link.path, withDestinationPath: elsewhere)

        XCTAssertEqual(tool.status(), .occupied(link: tool.link, destination: elsewhere))
        XCTAssertThrowsError(try tool.install())
        XCTAssertThrowsError(try tool.uninstall())
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: tool.link.path), elsewhere)
    }

    // MARK: - Another copy of the app

    func testLinkToAnotherCopyIsStaleAndReplaced() throws {
        let old = try makeApp(named: "Old/privacycommand.app")
        try subject(for: old).install()

        let tool = subject()
        let oldTarget = old.appendingPathComponent(CommandLineTool.bundlePath).path
        XCTAssertEqual(tool.status(), .stale(link: tool.link, destination: oldTarget))
        try tool.install()
        XCTAssertEqual(tool.status(), .installed(link: tool.link))
    }

    func testDanglingLinkFromAMovedAppIsStaleAndRemovable() throws {
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = subject()
        let gone = "/Volumes/privacycommand/privacycommand.app/Contents/Helpers/privacycommand"
        try fm.createSymbolicLink(atPath: tool.link.path, withDestinationPath: gone)

        XCTAssertEqual(tool.status(), .stale(link: tool.link, destination: gone))
        try tool.uninstall()
        XCTAssertEqual(tool.status(), .notInstalled)
    }

    // MARK: - Homebrew's link

    func testHomebrewLinkCountsAsInstalledButIsNotOursToRemove() throws {
        let tool = subject()
        let brewLink = brewBin.appendingPathComponent("privacycommand")
        try fm.createSymbolicLink(at: brewLink, withDestinationURL: tool.tool)

        XCTAssertEqual(tool.status(), .installed(link: brewLink))
        try tool.install() // already on PATH: nothing to do
        XCTAssertFalse(fm.fileExists(atPath: tool.link.path))
        XCTAssertThrowsError(try tool.uninstall()) {
            XCTAssertEqual($0 as? CommandLineTool.Failure, .managedElsewhere(link: brewLink))
        }
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: brewLink.path))
    }

    // MARK: - No write access

    func testUnwritableDirectoryReportsTheSudoCommand() throws {
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
        let tool = subject()

        XCTAssertThrowsError(try tool.install()) {
            XCTAssertEqual($0 as? CommandLineTool.Failure, .permissionDenied(command: tool.installCommand))
        }

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        try tool.install()
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
        XCTAssertThrowsError(try tool.uninstall()) {
            XCTAssertEqual($0 as? CommandLineTool.Failure, .permissionDenied(command: tool.uninstallCommand))
        }
    }

    // MARK: - Commands and locations

    func testCommandsForTheDefaultLocation() {
        let tool = CommandLineTool(appBundle: URL(fileURLWithPath: "/Applications/privacycommand.app"))
        XCTAssertEqual(tool.installCommand,
                       "sudo mkdir -p /usr/local/bin && sudo ln -sf "
                       + "/Applications/privacycommand.app/Contents/Helpers/privacycommand /usr/local/bin/privacycommand")
        XCTAssertEqual(tool.uninstallCommand, "sudo rm /usr/local/bin/privacycommand")
    }

    func testShellQuoting() {
        XCTAssertEqual(CommandLineTool.shellQuoted("/usr/local/bin"), "/usr/local/bin")
        XCTAssertEqual(CommandLineTool.shellQuoted("/Users/a b/x.app"), "'/Users/a b/x.app'")
        XCTAssertEqual(CommandLineTool.shellQuoted("/tmp/it's"), "'/tmp/it'\\''s'")
        XCTAssertEqual(CommandLineTool.shellQuoted("/tmp/$(rm)"), "'/tmp/$(rm)'")
    }

    func testTemporaryLocations() {
        XCTAssertTrue(CommandLineTool.isTemporaryLocation(URL(fileURLWithPath:
            "/private/var/folders/xy/T/AppTranslocation/1234/d/privacycommand.app")))
        XCTAssertFalse(CommandLineTool.isTemporaryLocation(app))
    }
}
