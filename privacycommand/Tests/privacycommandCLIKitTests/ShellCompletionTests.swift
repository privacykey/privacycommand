import XCTest
@testable import privacycommandCLIKit

/// Covers the generated completion scripts: everything in the command tables
/// reaches every shell, the scripts parse, and bash completes the fixed parts
/// of the command line (subcommands, options, tiers, shells). App names and
/// casks depend on the machine, so they're exercised by hand, not here.
final class ShellCompletionTests: XCTestCase {

    private let allOptions = ShellCompletion.topLevelOptions
        + ShellCompletion.auditOptions + ShellCompletion.previewOptions
        + ShellCompletion.upgradeOptions

    func testEveryCommandAndOptionReachesEveryShell() {
        for shell in ShellCompletion.Shell.allCases {
            let script = ShellCompletion.script(for: shell)
            for sub in ShellCompletion.subcommands {
                XCTAssertTrue(script.contains(sub.name), "\(shell) is missing \(sub.name)")
            }
            for option in allOptions {
                // fish names long options without their dashes (`-l json`).
                let long = shell == .fish ? "-l \(option.long.dropFirst(2))" : option.long
                XCTAssertTrue(script.contains(long), "\(shell) is missing \(option.long)")
            }
            for tier in ShellCompletion.riskTiers {
                XCTAssertTrue(script.contains(tier), "\(shell) is missing tier \(tier)")
            }
        }
    }

    func testEachScriptRegistersForTheCommand() {
        XCTAssertTrue(ShellCompletion.script(for: .zsh).hasPrefix("#compdef privacycommand\n"))
        XCTAssertTrue(ShellCompletion.script(for: .zsh).contains("compdef _privacycommand privacycommand"))
        XCTAssertTrue(ShellCompletion.script(for: .bash)
            .contains("complete -o filenames -F _privacycommand privacycommand"))
        XCTAssertTrue(ShellCompletion.script(for: .fish).contains("complete -c privacycommand -f"))
    }

    func testFileNamesMatchWhatHomebrewAndEachShellExpect() {
        XCTAssertEqual(ShellCompletion.Shell.zsh.fileName, "_privacycommand")
        XCTAssertEqual(ShellCompletion.Shell.bash.fileName, "privacycommand.bash")
        XCTAssertEqual(ShellCompletion.Shell.fish.fileName, "privacycommand.fish")
    }

    func testScriptsParse() throws {
        try assertParses(.zsh, with: "/bin/zsh")
        try assertParses(.bash, with: "/bin/bash")
        guard let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .first(where: FileManager.default.isExecutableFile) else { return }
        try assertParses(.fish, with: fish)
    }

    func testBashCompletesTheFixedParts() throws {
        let driver = """
        source "$1"
        t() {
          COMP_WORDS=("$@"); COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
          _privacycommand
          printf '%s\\n' "${COMPREPLY[*]}"
        }
        t privacycommand pre
        t privacycommand preview --
        t privacycommand preview --min-tier ""
        t privacycommand upgrade --
        t privacycommand upgrade --max-risk ""
        t privacycommand completion ""
        t privacycommand audit --w
        t privacycommand SomeApp --s
        t privacycommand --version ""
        """
        let lines = try run("/bin/bash", ["--norc", "--noprofile", "-s"], scriptFor: .bash, driver: driver)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 10, "\(lines)")
        XCTAssertTrue(lines[0].split(separator: " ").contains("preview"))
        XCTAssertEqual(lines[1], "--all-apps --apps-dir --fetch --greedy --max-risk --min-tier --only-noteworthy --json --help")
        XCTAssertEqual(lines[2], "low medium high critical")
        XCTAssertEqual(lines[3], "--max-risk --dry-run --no-input --greedy --min-tier --only-noteworthy --json --help")
        XCTAssertEqual(lines[4], "low medium high critical")
        XCTAssertEqual(lines[5], "zsh bash fish")
        XCTAssertEqual(lines[6], "--warnings --warn-exit")
        XCTAssertEqual(lines[7], "--short")
        XCTAssertEqual(lines[8], "")
    }

    // MARK: - Helpers

    private func assertParses(_ shell: ShellCompletion.Shell, with interpreter: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try temporaryScript(for: shell)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = ["-n", url.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "\(shell): \(message)", file: file, line: line)
    }

    /// Runs `driver` on stdin with the shell's script path as `$1`.
    private func run(_ interpreter: String, _ arguments: [String],
                     scriptFor shell: ShellCompletion.Shell, driver: String) throws -> String {
        let url = try temporaryScript(for: shell)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = arguments + [url.path]
        process.currentDirectoryURL = url.deletingLastPathComponent()
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(driver.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    private func temporaryScript(for shell: ShellCompletion.Shell) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellCompletionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(shell.fileName)
        try ShellCompletion.script(for: shell).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
