import Foundation
import privacycommandCore
import privacycommandCLIKit

// `privacycommand` — the app's static-only command line front-end for the
// analyzer, with a witr-style query interface and an interactive browser.
//
//   privacycommand                       interactive browser on a TTY (like `witr`)
//   privacycommand <target>              static audit of one app (name or path)
//   privacycommand audit <target>        same, explicit
//   privacycommand -i | interactive      force the interactive browser
//   privacycommand preview [options]     preview the apps you're about to update
//   privacycommand upgrade [options]     what `brew upgrade` would change; with
//                                        --max-risk, apply the safe ones
//   privacycommand completion <shell>    print a zsh, bash or fish completion script
//
// `<target>` is a path to a .app or an app-name substring matched against
// installed apps. See `AuditCommand` / `privacycommand audit --help`.
//
// CI relies on `privacycommand /System/Applications/Calculator.app` exiting
// non-zero when the analyzer can't parse a bundle, so a bare path is still
// audited and a successful analysis still exits 0. A bare `privacycommand` only
// launches the TUI when stdin/stdout are a terminal; otherwise it prints usage
// (keeps CI safe).

let arguments = Array(CommandLine.arguments.dropFirst())

func die(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let topLevelUsage = """
usage:
  privacycommand                       interactive browser (on a terminal)
  privacycommand <target>              static audit of one app (name or path)
  privacycommand audit <target>        same, explicit
  privacycommand -i, interactive       force the interactive browser
  privacycommand preview [options]     preview apps before you update them
  privacycommand upgrade [options]     show what `brew upgrade` would change, or gate it by risk
  privacycommand completion <shell>    print a tab-completion script (zsh, bash, fish)

<target> is a path to a .app or an app-name substring (like `witr`).
Run `privacycommand audit --help`, `privacycommand preview --help`,
`privacycommand upgrade --help` or `privacycommand completion --help` for details.
"""

private func stdioIsTTY() -> Bool {
    isatty(FileHandle.standardInput.fileDescriptor) != 0
        && isatty(FileHandle.standardOutput.fileDescriptor) != 0
}

guard let command = arguments.first else {
    // Bare `privacycommand`: launch the browser on a terminal (witr-style), else usage.
    if stdioIsTTY() { InteractiveCommand.run() }
    die(topLevelUsage)
}

switch command {
case "preview":
    PreviewCommand.run(Array(arguments.dropFirst()))
case "upgrade":
    PreviewCommand.run(Array(arguments.dropFirst()), upgrade: true)
case "audit":
    AuditCommand.run(Array(arguments.dropFirst()))
case "completion":
    CompletionCommand.run(Array(arguments.dropFirst()))
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
    print(v == "0.0.0-dev" ? "privacycommand (dev build)" : "privacycommand \(v)")
    exit(0)
default:
    // Back-compat + witr-style: a bare first argument (path or name), together
    // with any audit options, goes straight to the audit command.
    AuditCommand.run(arguments)
}
