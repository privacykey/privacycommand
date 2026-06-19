import Foundation
import privacycommandCore

// `auditctl` — a small static-only command line front-end for the analyzer.
//
//   auditctl <path-to-app>          static audit of one app (back-compat / CI smoke test)
//   auditctl audit <path-to-app>    same, explicit
//   auditctl preview [options]      preview the apps you're about to update
//
// CI relies on `auditctl /System/Applications/Calculator.app` exiting non-zero
// when the analyzer can't parse a bundle, so that bare-path form is preserved.

let arguments = Array(CommandLine.arguments.dropFirst())

func die(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let topLevelUsage = """
usage:
  auditctl <path-to-app>          static audit of one app
  auditctl audit <path-to-app>    same, explicit
  auditctl preview [options]      preview apps before you update them

Run `auditctl preview --help` for preview options.
"""

guard let command = arguments.first else { die(topLevelUsage) }

switch command {
case "preview":
    PreviewCommand.run(Array(arguments.dropFirst()))
case "audit":
    guard arguments.count == 2 else { die("usage: auditctl audit <path-to-app>") }
    runAudit(path: arguments[1])
case "-h", "--help":
    print(topLevelUsage)
    exit(0)
default:
    // Back-compat: a bare first argument is treated as the app to audit.
    guard arguments.count == 1 else { die(topLevelUsage) }
    runAudit(path: command)
}

// MARK: - Single-app audit (the original behaviour)

func runAudit(path: String) -> Never {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    do {
        let report = try StaticAnalyzer().analyze(bundleAt: url)
        let summary = """
        \(report.bundle.bundleName ?? "?") (\(report.bundle.bundleID ?? "no-id")) v\(report.bundle.bundleVersion ?? "?")
        Architectures:    \(report.bundle.architectures.joined(separator: ", "))
        Team identifier:  \(report.codeSigning.teamIdentifier ?? "—")
        Hardened runtime: \(report.codeSigning.hardenedRuntime ? "yes" : "no")
        Notarization:     \(report.notarization)
        Sandbox:          \(report.entitlements.isSandboxed ? "yes" : "no")
        Privacy keys:     \(report.declaredPrivacyKeys.map(\.rawKey).joined(separator: ", "))
        Inferred caps:    \(report.inferredCapabilities.map { "\($0.category.rawValue)\($0.inferredButNotDeclared ? "*" : "")" }.joined(separator: ", "))
        Frameworks:       \(report.frameworks.count)  XPC:\(report.xpcServices.count)  Helpers:\(report.helpers.count)  LoginItems:\(report.loginItems.count)
        Findings:         \(report.warnings.count)
        """
        print(summary)
        for w in report.warnings {
            print("  [\(w.severity.rawValue)] \(w.message)")
        }
        exit(0)
    } catch {
        die("Failed to analyze: \(error.localizedDescription)", code: 1)
    }
}
