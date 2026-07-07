import Foundation
import privacycommandCore
import auditctlKit

// `auditctl` — a static-only command line front-end for the analyzer, with a
// witr-style query interface and an interactive browser.
//
//   auditctl                       interactive browser on a TTY (like `witr`)
//   auditctl <target>              static audit of one app (name or path)
//   auditctl audit <target>        same, explicit
//   auditctl -i | interactive      force the interactive browser
//   auditctl preview [options]     preview the apps you're about to update
//
// `<target>` is a path to a .app or an app-name substring matched against
// installed apps. See `AuditCommand` / `auditctl audit --help`.
//
// CI relies on `auditctl /System/Applications/Calculator.app` exiting non-zero
// when the analyzer can't parse a bundle, so a bare path is still audited and a
// successful analysis still exits 0. A bare `auditctl` only launches the TUI
// when stdin/stdout are a terminal; otherwise it prints usage (keeps CI safe).

let arguments = Array(CommandLine.arguments.dropFirst())

func die(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let topLevelUsage = """
usage:
  auditctl                       interactive browser (on a terminal)
  auditctl <target>              static audit of one app (name or path)
  auditctl audit <target>        same, explicit
  auditctl -i, interactive       force the interactive browser
  auditctl preview [options]     preview apps before you update them

<target> is a path to a .app or an app-name substring (like `witr`).
Run `auditctl audit --help` or `auditctl preview --help` for options.
"""

private func stdioIsTTY() -> Bool {
    isatty(FileHandle.standardInput.fileDescriptor) != 0
        && isatty(FileHandle.standardOutput.fileDescriptor) != 0
}

guard let command = arguments.first else {
    // Bare `auditctl`: launch the browser on a terminal (witr-style), else usage.
    if stdioIsTTY() { InteractiveCommand.run() }
    die(topLevelUsage)
}

switch command {
case "preview":
    PreviewCommand.run(Array(arguments.dropFirst()))
case "audit":
    AuditCommand.run(Array(arguments.dropFirst()))
case "-i", "--interactive", "interactive":
    InteractiveCommand.run()
case "--tui-selftest":
    TUISelfTest.run()
case "-h", "--help":
    print(topLevelUsage)
    exit(0)
case "-v", "--version":
    // Uses the analyzer's version (Info.plist `CFBundleShortVersionString`).
    // A CLI built with `swift build` has no bundle to read, so that resolves
    // to the dev sentinel — show it as a plain "dev build" rather than a
    // fake-looking 0.0.0. A release that stamps the version prints it.
    let v = RunReport.currentAuditorVersion
    print(v == "0.0.0-dev" ? "auditctl (dev build)" : "auditctl \(v)")
    exit(0)
default:
    // Back-compat + witr-style: a bare first argument (path or name), together
    // with any audit options, goes straight to the audit command.
    AuditCommand.run(arguments)
}
