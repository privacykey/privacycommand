import Foundation
import privacycommandCore
import auditctlKit

/// `auditctl audit <target>` — static audit of a single app, with a witr-style
/// query interface: resolve a name substring or a path to an app, analyze it,
/// then render its privacy/security posture. Supports `--short` / `--tree` /
/// `--json` / `--warnings` / `--verbose`, coloured TTY output, and structured
/// exit codes.
///
/// This is a presentation layer over `StaticAnalyzer` + `NoteworthySummary` —
/// it adds no new detection, only a nicer front door than the original
/// one-shot printer.
enum AuditCommand {

    static let help = """
    usage: auditctl audit <target> [options]
           auditctl <target> [options]

    Statically audit one app. <target> is either a path to a .app bundle or an
    app-name substring matched against installed apps in /Applications,
    ~/Applications and /System/Applications (like `witr`). Use -x for an exact
    name; on multiple matches auditctl lists them and exits 4.

    output modes (default is a sectioned, coloured summary):
      -s, --short       one-line verdict only
      -t, --tree        the app's component tree (frameworks / XPC / helpers /
                        login items)
      --warnings        only the findings section
      --json            machine-readable JSON
      --verbose         include info-level findings, their evidence, and the
                        full component lists

    options:
      -x, --exact       exact app-name match (no substring search)
      --warn-exit       exit 1 when the app has any warn/error finding (handy in
                        CI); the default is to exit 0 on any successful analysis
      --no-color        disable coloured output (the NO_COLOR env var also works)
      -h, --help        show this help

    exit codes:
      0  analyzed OK                2  target not found
      1  analysis failed, or        4  ambiguous target (multiple apps matched)
         --warn-exit and findings
    """

    // MARK: - Options

    struct Options {
        var target: String?
        var exact = false
        var short = false
        var tree = false
        var json = false
        var verbose = false
        var warningsOnly = false
        var warnExit = false
        var noColor = false
    }

    static func run(_ argv: [String]) -> Never {
        var opts = Options()
        for arg in argv {
            switch arg {
            case "-x", "--exact":  opts.exact = true
            case "-s", "--short":  opts.short = true
            case "-t", "--tree":   opts.tree = true
            case "--json":         opts.json = true
            case "--verbose":      opts.verbose = true
            case "--warnings":     opts.warningsOnly = true
            case "--warn-exit":    opts.warnExit = true
            case "--no-color":     opts.noColor = true
            case "-h", "--help":   print(help); exit(0)
            default:
                if arg.hasPrefix("-") {
                    die("unknown option: \(arg)  (see `auditctl audit --help`)", code: 2)
                }
                if opts.target != nil {
                    die("audit takes one target at a time (extra argument: \(arg))", code: 2)
                }
                opts.target = arg
            }
        }

        guard let target = opts.target else { die("no target given.\n\n" + help, code: 2) }
        let ansi = Ansi(noColor: opts.noColor)

        // 1. Resolve the target to a bundle on disk.
        let url: URL
        switch resolve(target, exact: opts.exact) {
        case .path(let u):
            url = u
        case .resolved(let match):
            url = match.bundleURL
        case .notFound:
            die("no installed app matches ‘\(target)’. Pass a path, or check the name.", code: 2)
        case .ambiguous(let matches):
            renderAmbiguous(target, matches)
            exit(4)
        }

        // 2. Analyze — with a progress spinner on stderr so a slow app (Chrome
        //    can take 30s+) doesn't look like a hang. The spinner only draws
        //    when stderr is a TTY and never touches stdout, so `--json` and
        //    piped output stay clean.
        let report: StaticReport
        do {
            let spinner = Spinner(message: "Analyzing \(url.deletingPathExtension().lastPathComponent)…")
            spinner.start()
            defer { spinner.stop() }
            report = try StaticAnalyzer().analyze(bundleAt: url, progress: { spinner.update($0) })
        } catch {
            die("failed to analyze \(url.path): \(error.localizedDescription)", code: 1)
        }
        let summary = NoteworthySummary.summarize(report)

        // 3. Render in the requested mode (json > short > tree > warnings > full).
        if opts.json {
            emitJSON(report, url: url, summary: summary)
        } else if opts.short {
            print(shortLine(report, url: url, summary: summary, ansi: ansi))
        } else if opts.tree {
            renderTree(report, url: url, ansi: ansi)
        } else if opts.warningsOnly {
            renderFindings(report, ansi: ansi, includeInfo: opts.verbose, standalone: true)
        } else {
            renderFull(report, url: url, summary: summary, ansi: ansi, verbose: opts.verbose)
        }

        // 4. Exit. Default: 0 on any successful analysis (a bare `auditctl <app>`
        //    is a CI smoke test and must stay 0). `--warn-exit` opts into
        //    witr-style "1 when there's something to worry about".
        if opts.warnExit && !summary.findings.isEmpty { exit(1) }
        exit(0)
    }

    // MARK: - Target resolution

    enum Resolution {
        case path(URL)
        case resolved(HomebrewCaskInventory.PreviewTarget)
        case notFound
        case ambiguous([HomebrewCaskInventory.PreviewTarget])
    }

    /// A path (anything with a `/`, or an existing file) is audited directly —
    /// this preserves the original `auditctl /path/to/App.app` behaviour.
    /// Otherwise the argument is a name query against installed apps.
    static func resolve(_ target: String, exact: Bool) -> Resolution {
        let expanded = (target as NSString).expandingTildeInPath
        if target.contains("/") || FileManager.default.fileExists(atPath: expanded) {
            return .path(URL(fileURLWithPath: expanded))
        }

        let installed = HomebrewCaskInventory.installedApps(in: searchDirectories())
        var needle = target.lowercased()
        if needle.hasSuffix(".app") { needle = String(needle.dropLast(4)) }

        let matches = installed.filter {
            let name = $0.displayName.lowercased()
            return exact ? name == needle : name.contains(needle)
        }

        switch matches.count {
        case 0:  return .notFound
        case 1:  return .resolved(matches[0])
        default:
            // Prefer a lone exact name hit over substring noise, e.g.
            // `auditctl safari` → Safari, not "Safari Technology Preview".
            let exacts = matches.filter { $0.displayName.lowercased() == needle }
            return exacts.count == 1 ? .resolved(exacts[0]) : .ambiguous(matches)
        }
    }

    static func searchDirectories() -> [URL] {
        HomebrewCaskInventory.defaultAppDirectories()
            + [URL(fileURLWithPath: "/System/Applications")]
    }

    // MARK: - Rendering: short

    static func shortLine(_ r: StaticReport, url: URL,
                          summary s: NoteworthySummary, ansi: Ansi) -> String {
        let marker = s.isNoteworthy ? ansi.paint("⚠", .yellow) : ansi.paint("✓", .green)
        let name = displayName(r, url: url)
        let id = r.bundle.bundleID.map { " (\($0))" } ?? ""
        return "\(marker) \(name)\(id) — \(ansi.paint(s.headline, tierCode(s.tier)))"
    }

    // MARK: - Rendering: full

    static func renderFull(_ r: StaticReport, url: URL,
                           summary s: NoteworthySummary, ansi: Ansi, verbose: Bool) {
        let marker = s.isNoteworthy ? ansi.paint("⚠", .yellow) : ansi.paint("✓", .green)
        print("\(marker) \(ansi.paint(displayName(r, url: url), .bold))  "
              + "\(r.bundle.bundleID ?? "no-id")  v\(r.bundle.bundleVersion ?? "?")")
        print("")

        func field(_ key: String, _ value: String) {
            let padded = key.padding(toLength: 13, withPad: " ", startingAt: 0)
            print(ansi.paint(padded, .bold, .cyan) + ansi.paint(":", .dim) + " " + value)
        }

        field("Path", url.path)
        field("Architecture", r.bundle.architectures.joined(separator: ", "))
        field("Signing", signingLine(r, ansi: ansi))
        field("Sandbox", r.entitlements.isSandboxed ? "yes" : ansi.paint("no", .yellow))
        field("Risk", ansi.paint("\(s.tier.label) (\(s.riskScore)/100)", tierCode(s.tier), .bold))
        if !r.declaredPrivacyKeys.isEmpty {
            field("Privacy keys", r.declaredPrivacyKeys.map(\.rawKey).joined(separator: ", "))
        }
        if !r.inferredCapabilities.isEmpty {
            let caps = r.inferredCapabilities.map {
                $0.category.rawValue + ($0.inferredButNotDeclared ? ansi.paint("*", .yellow) : "")
            }
            field("Capabilities", caps.joined(separator: ", "))
        }
        field("Components", "\(r.frameworks.count) frameworks · \(r.xpcServices.count) XPC · "
              + "\(r.helpers.count) helpers · \(r.loginItems.count) login items")

        if !s.signals.isEmpty {
            print("")
            print(ansi.paint("Signals", .bold, .cyan))
            for sig in s.signals { print("  \(ansi.paint("•", .yellow)) \(sig)") }
        }

        renderFindings(r, ansi: ansi, includeInfo: verbose, standalone: false)

        if r.inferredCapabilities.contains(where: { $0.inferredButNotDeclared }) {
            print("")
            print(ansi.paint("* capability used by the binary but not declared in Info.plist", .dim))
        }
    }

    static func signingLine(_ r: StaticReport, ansi: Ansi) -> String {
        var parts: [String] = []
        if let team = r.codeSigning.teamIdentifier {
            parts.append(r.codeSigning.teamName.map { "\($0) (\(team))" } ?? "Team \(team)")
        } else if r.codeSigning.isPlatformBinary {
            parts.append("Apple platform binary")
        } else if r.codeSigning.isAdhocSigned {
            parts.append(ansi.paint("ad-hoc signed", .yellow))
        } else {
            parts.append(ansi.paint("unsigned", .red))
        }
        parts.append(notarizationLabel(r.notarization, ansi: ansi))
        parts.append(r.codeSigning.hardenedRuntime
                     ? "hardened runtime"
                     : ansi.paint("no hardened runtime", .yellow))
        return parts.joined(separator: " · ")
    }

    static func notarizationLabel(_ n: NotarizationStatus, ansi: Ansi) -> String {
        switch n {
        case .notarized:       return ansi.paint("notarized", .green)
        case .developerIDOnly: return ansi.paint("not notarized", .yellow)
        case .unsigned:        return ansi.paint("unsigned", .red)
        case .rejected:        return ansi.paint("Gatekeeper-rejected", .red)
        case .unknown:         return "notarization unknown"
        }
    }

    // MARK: - Rendering: findings

    static func renderFindings(_ r: StaticReport, ansi: Ansi,
                               includeInfo: Bool, standalone: Bool) {
        let findings = includeInfo ? r.warnings : r.warnings.filter { $0.severity != .info }
        guard !findings.isEmpty else {
            if standalone { print("No findings.") }
            return
        }
        if !standalone { print("") }
        print(ansi.paint("Findings (\(findings.count))", .bold, .cyan))
        // Most severe first.
        for sev in [Finding.Severity.error, .warn, .info] {
            for f in findings where f.severity == sev {
                print("  \(severityTag(sev, ansi: ansi)) \(f.message)")
                if includeInfo {
                    for e in f.evidence.prefix(4) { print("        \(ansi.paint(e, .dim))") }
                }
            }
        }
    }

    static func severityTag(_ s: Finding.Severity, ansi: Ansi) -> String {
        switch s {
        case .error: return ansi.paint("[error]", .red, .bold)
        case .warn:  return ansi.paint("[warn] ", .yellow)
        case .info:  return ansi.paint("[info] ", .dim)
        }
    }

    // MARK: - Rendering: tree

    static func renderTree(_ r: StaticReport, url: URL, ansi: Ansi) {
        print("\(ansi.paint(displayName(r, url: url), .bold))  "
              + "\(r.bundle.bundleID ?? "no-id") v\(r.bundle.bundleVersion ?? "?")")

        struct Group { let title: String; let items: [String] }
        let groups: [Group] = [
            Group(title: "Frameworks", items: r.frameworks.map {
                let n = $0.url.lastPathComponent
                return $0.isAppleSigned ? n : n + ansi.paint(" (3rd-party)", .dim)
            }),
            Group(title: "XPC services", items: r.xpcServices.map { $0.url.lastPathComponent }),
            Group(title: "Helpers", items: r.helpers.map { $0.url.lastPathComponent }),
            Group(title: "Login items", items: r.loginItems.map { $0.url.lastPathComponent }),
        ].filter { !$0.items.isEmpty }

        guard !groups.isEmpty else {
            print(ansi.paint("  (no embedded frameworks, XPC services, helpers, or login items)", .dim))
            return
        }

        for (gi, g) in groups.enumerated() {
            let lastGroup = gi == groups.count - 1
            print("\(ansi.paint(lastGroup ? "└─" : "├─", .dim)) "
                  + "\(ansi.paint(g.title, .cyan)) (\(g.items.count))")
            let cont = lastGroup ? "   " : ansi.paint("│  ", .dim)
            for (ii, item) in g.items.enumerated() {
                let branch = ii == g.items.count - 1 ? "└─" : "├─"
                print("\(cont)\(ansi.paint(branch, .dim)) \(item)")
            }
        }
    }

    // MARK: - Rendering: ambiguous match (to stderr, so stdout stays pipe-clean)

    static func renderAmbiguous(_ target: String, _ matches: [HomebrewCaskInventory.PreviewTarget]) {
        var msg = "‘\(target)’ matches \(matches.count) apps — narrow it down or use -x:\n"
        for m in matches.sorted(by: { $0.displayName.lowercased() < $1.displayName.lowercased() }) {
            msg += "  \(m.displayName)  (\(m.bundleURL.path))\n"
        }
        FileHandle.standardError.write(Data(msg.utf8))
    }

    // MARK: - JSON

    struct AuditJSON: Codable {
        let name: String
        let bundleID: String?
        let version: String?
        let path: String
        let architectures: [String]
        let teamIdentifier: String?
        let teamName: String?
        let notarization: String
        let hardenedRuntime: Bool
        let sandboxed: Bool
        let riskScore: Int
        let tier: String
        let isNoteworthy: Bool
        let headline: String
        let privacyKeys: [String]
        let capabilities: [Capability]
        let components: Components
        let signals: [String]
        let findings: [FindingJSON]

        struct Capability: Codable {
            let category: String
            let inferredButNotDeclared: Bool
        }
        struct Components: Codable {
            let frameworks: Int
            let xpcServices: Int
            let helpers: Int
            let loginItems: Int
        }
        struct FindingJSON: Codable {
            let severity: String
            let message: String
            let evidence: [String]
        }
    }

    static func emitJSON(_ r: StaticReport, url: URL, summary s: NoteworthySummary) {
        let obj = AuditJSON(
            name: displayName(r, url: url),
            bundleID: r.bundle.bundleID,
            version: r.bundle.bundleVersion,
            path: url.path,
            architectures: r.bundle.architectures,
            teamIdentifier: r.codeSigning.teamIdentifier,
            teamName: r.codeSigning.teamName,
            notarization: notarizationRaw(r.notarization),
            hardenedRuntime: r.codeSigning.hardenedRuntime,
            sandboxed: r.entitlements.isSandboxed,
            riskScore: s.riskScore,
            tier: s.tier.rawValue,
            isNoteworthy: s.isNoteworthy,
            headline: s.headline,
            privacyKeys: r.declaredPrivacyKeys.map(\.rawKey),
            capabilities: r.inferredCapabilities.map {
                .init(category: $0.category.rawValue, inferredButNotDeclared: $0.inferredButNotDeclared)
            },
            components: .init(frameworks: r.frameworks.count, xpcServices: r.xpcServices.count,
                              helpers: r.helpers.count, loginItems: r.loginItems.count),
            signals: s.signals,
            findings: r.warnings.map {
                .init(severity: $0.severity.rawValue, message: $0.message, evidence: $0.evidence)
            })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(obj), let str = String(data: data, encoding: .utf8) {
            print(str)
        } else {
            die("failed to encode JSON output.", code: 1)
        }
    }

    static func notarizationRaw(_ n: NotarizationStatus) -> String {
        switch n {
        case .notarized:       return "notarized"
        case .developerIDOnly: return "developer-id-only"
        case .unsigned:        return "unsigned"
        case .rejected:        return "rejected"
        case .unknown:         return "unknown"
        }
    }

    // MARK: - Shared helpers

    static func displayName(_ r: StaticReport, url: URL) -> String {
        r.bundle.bundleName ?? url.deletingPathExtension().lastPathComponent
    }

    static func tierCode(_ t: RiskTier) -> Ansi.Code {
        switch t {
        case .low:      return .green
        case .medium:   return .yellow
        case .high:     return .red
        case .critical: return .brightRed
        }
    }
}
