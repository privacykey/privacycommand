import Foundation
import privacycommandCore

// `auditctl <path-to-app>` — small static-only smoke test for the analyzer.
// Used by CI and by humans who want a quick sanity check without launching the GUI.

let args = CommandLine.arguments
guard args.count == 2 else {
    let stderr = FileHandle.standardError
    stderr.write(Data("usage: auditctl <path-to-app>\n".utf8))
    exit(2)
}

let path = (args[1] as NSString).expandingTildeInPath
let url = URL(fileURLWithPath: path)
let analyzer = StaticAnalyzer()

do {
    let report = try analyzer.analyze(bundleAt: url)
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
    if !report.warnings.isEmpty {
        for w in report.warnings {
            print("  [\(w.severity.rawValue)] \(w.message)")
        }
    }
    exit(0)
} catch {
    FileHandle.standardError.write(Data("Failed to analyze: \(error.localizedDescription)\n".utf8))
    exit(1)
}
