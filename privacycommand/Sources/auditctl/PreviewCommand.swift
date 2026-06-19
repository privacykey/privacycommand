import Foundation
import privacycommandCore

/// `auditctl preview` — analyze the apps you're about to update and surface
/// anything noteworthy, *before* you run `brew upgrade`.
///
/// Default source is the set of outdated Homebrew casks (what `brew upgrade`
/// would replace); `--all-apps` previews everything installed instead. The
/// command is inform-only: it never runs `brew` and always exits 0 on success.
enum PreviewCommand {

    static let help = """
    usage: auditctl preview [options] [cask ...]

    Analyze the apps you're about to update and flag anything noteworthy.
    By default it checks the apps an outdated `brew upgrade` would touch.
    Pass one or more cask tokens to restrict to just those casks.

    options:
      --all-apps            preview every installed .app instead of brew casks
                            (scans /Applications and ~/Applications)
      --apps-dir <dir>      preview every .app in <dir> (implies --all-apps)
      --fetch               download each incoming cask, analyze it, and show
                            what the upgrade would change (brew-cask mode only)
      --min-tier <tier>     only show apps at risk tier >= low|medium|high|critical
      --only-noteworthy     hide apps with nothing noteworthy
      --json                emit machine-readable JSON
      -h, --help            show this help

    Without --fetch, brew hasn't downloaded the new versions yet, so this
    analyzes the *installed* build — what each app already does. With --fetch it
    downloads each incoming cask, analyzes it, and diffs it against the installed
    build to show what the upgrade would change. Either way it never runs
    `brew upgrade` and exits 0 on success.
    """

    // MARK: - Entry point

    static func run(_ argv: [String]) -> Never {
        var allApps = false
        var appsDir: String?
        var json = false
        var onlyNoteworthy = false
        var fetch = false
        var minTier: RiskTier?
        var caskFilter: [String] = []   // positional cask tokens to restrict to

        var i = 0
        while i < argv.count {
            switch argv[i] {
            case "--all-apps":
                allApps = true
            case "--json":
                json = true
            case "--fetch":
                fetch = true
            case "--only-noteworthy":
                onlyNoteworthy = true
            case "--apps-dir":
                i += 1
                guard i < argv.count else { die("--apps-dir needs a directory") }
                appsDir = argv[i]
                allApps = true
            case "--min-tier":
                i += 1
                guard i < argv.count, let t = tier(from: argv[i]) else {
                    die("--min-tier needs one of: low, medium, high, critical")
                }
                minTier = t
            case "-h", "--help":
                print(help)
                exit(0)
            default:
                if argv[i].hasPrefix("-") {
                    die("unknown option: \(argv[i])  (see `auditctl preview --help`)")
                }
                caskFilter.append(argv[i])   // positional = cask token to restrict to
            }
            i += 1
        }

        if fetch && allApps {
            die("--fetch only applies to outdated Homebrew casks; drop --all-apps/--apps-dir.")
        }
        if !caskFilter.isEmpty && allApps {
            die("cask names only apply to brew-cask mode; drop --all-apps/--apps-dir.")
        }

        // 1. Discover the apps to preview.
        let targets: [HomebrewCaskInventory.PreviewTarget]
        let header: String
        do {
            if allApps {
                let dirs = appsDir.map { [URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)] }
                    ?? HomebrewCaskInventory.defaultAppDirectories()
                targets = HomebrewCaskInventory.installedApps(in: dirs)
                header = "Scanning \(targets.count) installed app\(plural(targets.count))…"
            } else {
                var casks = try HomebrewCaskInventory().outdatedCaskTargets()
                if !caskFilter.isEmpty {
                    let wanted = Set(caskFilter.map { $0.lowercased() })
                    let found = Set(casks.compactMap { t -> String? in
                        if case .brewCask(let token, _, _) = t.source { return token.lowercased() }
                        return nil
                    })
                    for missing in wanted.subtracting(found).sorted() {
                        FileHandle.standardError.write(Data(
                            "note: ‘\(missing)’ is not an outdated cask — skipping.\n".utf8))
                    }
                    casks = casks.filter {
                        if case .brewCask(let token, _, _) = $0.source { return wanted.contains(token.lowercased()) }
                        return false
                    }
                }
                targets = casks
                header = "Checking \(targets.count) outdated Homebrew cask\(plural(targets.count))…"
            }
        } catch {
            die((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }

        if targets.isEmpty {
            if json {
                print("[]")
            } else if allApps {
                print("No apps found.")
            } else if !caskFilter.isEmpty {
                print("No matching outdated casks.")
            } else {
                print("Nothing to upgrade — all casks are up to date. ✓")
            }
            exit(0)
        }

        // 2. Analyze the installed builds (parallel — I/O-bound on codesign/spctl).
        var results = analyze(targets)

        // Display filter, reused for both the fetch set and rendering.
        let shouldShow: (Result) -> Bool = { r in
            guard let summary = r.summary else { return true } // always surface errors
            if onlyNoteworthy && !summary.isNoteworthy { return false }
            if let min = minTier, rank(summary.tier) < rank(min) { return false }
            return true
        }

        // 3. Optionally download + analyze + diff each incoming cask. Only the
        //    casks that would be shown are fetched, so --only-noteworthy /
        //    --min-tier bound how much gets downloaded.
        if fetch {
            runFetchPass(&results, shouldShow: shouldShow)
        }

        let shown = results.filter(shouldShow)

        if json {
            emitJSON(shown, fetched: fetch)
        } else {
            render(header: header, all: results, shown: shown, brewMode: !allApps, fetched: fetch)
        }
        exit(0)
    }

    // MARK: - Analysis

    /// Outcome of the optional `--fetch` pass for one cask.
    enum FetchOutcome {
        case analyzed(IncomingCaskComparison.IncomingDiff)
        case skipped(String)   // expected "can't preview this one" (format/no-app)
        case failed(String)    // unexpected error (download/extract)
    }

    struct Result {
        let target: HomebrewCaskInventory.PreviewTarget
        let installedVersion: String?
        let summary: NoteworthySummary?
        let installedReport: StaticReport?
        let error: String?
        var fetched: FetchOutcome?
    }

    static func analyze(_ targets: [HomebrewCaskInventory.PreviewTarget]) -> [Result] {
        var slots = [Result?](repeating: nil, count: targets.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: targets.count) { idx in
            let target = targets[idx]
            let result: Result
            do {
                let report = try StaticAnalyzer().analyze(bundleAt: target.bundleURL)
                result = Result(target: target,
                                installedVersion: report.bundle.bundleVersion,
                                summary: NoteworthySummary.summarize(report),
                                installedReport: report,
                                error: nil)
            } catch {
                result = Result(target: target, installedVersion: nil,
                                summary: nil, installedReport: nil,
                                error: error.localizedDescription)
            }
            lock.lock(); slots[idx] = result; lock.unlock()
        }
        return slots.compactMap { $0 }
    }

    // MARK: - Fetch pass (download incoming cask → analyze → diff)

    /// For each shown brew-cask target, download the incoming artifact, analyze
    /// it, and diff against the installed build. Sequential (downloads are large
    /// and network-bound). Bridges the synchronous CLI to the async fetch API
    /// with a Task + semaphore so the process never exits before teardown.
    static func runFetchPass(_ results: inout [Result], shouldShow: (Result) -> Bool) {
        struct Job: Sendable { let index: Int; let token: String; let installed: StaticReport? }

        var jobs: [Job] = []
        for i in results.indices where shouldShow(results[i]) {
            guard case .brewCask(let token, _, _) = results[i].target.source else { continue }
            jobs.append(Job(index: i, token: token, installed: results[i].installedReport))
        }
        guard !jobs.isEmpty else { return }

        FileHandle.standardError.write(Data(
            "Fetching \(jobs.count) incoming build\(plural(jobs.count))… (downloads may be large)\n".utf8))

        final class Box: @unchecked Sendable { var map: [Int: FetchOutcome] = [:] }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let jobsCopy = jobs
        Task {
            for job in jobsCopy {
                FileHandle.standardError.write(Data("  fetching \(job.token)…\n".utf8))
                box.map[job.index] = await fetchOne(token: job.token, installed: job.installed)
            }
            semaphore.signal()
        }
        semaphore.wait()   // teardown is complete before we proceed to render/exit.

        for (i, outcome) in box.map { results[i].fetched = outcome }
    }

    static func fetchOne(token: String, installed: StaticReport?) async -> FetchOutcome {
        guard let installed else { return .skipped("installed build couldn't be analyzed") }
        do {
            let incoming = try await CaskArtifactFetcher.withDownloadedApp(token: token) { app in
                try StaticAnalyzer().analyze(bundleAt: app)
            }
            return .analyzed(IncomingCaskComparison.compare(installed: installed, incoming: incoming))
        } catch let e as CaskArtifactFetcher.FetchError {
            return e.isSkip ? .skipped(e.errorDescription ?? "skipped")
                            : .failed(e.errorDescription ?? "fetch failed")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Human rendering

    static func render(header: String, all: [Result], shown: [Result], brewMode: Bool, fetched: Bool) {
        print(header)
        print("")

        // Noteworthy first, then by risk tier (desc), then by name.
        let ordered = shown.sorted { a, b in
            let an = a.summary?.isNoteworthy ?? true, bn = b.summary?.isNoteworthy ?? true
            if an != bn { return an && !bn }
            let ar = a.summary.map { rank($0.tier) } ?? 99, br = b.summary.map { rank($0.tier) } ?? 99
            if ar != br { return ar > br }
            return a.target.displayName.lowercased() < b.target.displayName.lowercased()
        }

        for r in ordered {
            print(line(for: r))
            if let summary = r.summary {
                if !summary.findings.isEmpty {
                    print("    findings:")
                    for f in summary.findings { print("      [\(f.severity.rawValue)] \(f.message)") }
                }
                if !summary.signals.isEmpty {
                    print("    signals:")
                    for s in summary.signals { print("      • \(s)") }
                }
            } else if let err = r.error {
                print("      couldn't analyze: \(err)")
            }
            if let outcome = r.fetched { renderIncoming(outcome) }
            print("")
        }

        // Summary footer.
        let analyzed = all.filter { $0.summary != nil }
        let noteworthy = analyzed.filter { $0.summary?.isNoteworthy == true }.count
        let failed = all.count - analyzed.count
        print("\(noteworthy) of \(analyzed.count) app\(plural(analyzed.count)) " +
              "\(analyzed.count == 1 ? "has" : "have") something noteworthy.")
        if failed > 0 { print("\(failed) couldn't be analyzed.") }

        if fetched {
            let analyzedIncoming = all.filter { if case .analyzed = $0.fetched { return true } else { return false } }
            let changed = analyzedIncoming.filter {
                if case .analyzed(let d) = $0.fetched { return d.diff.hasAnyChange } else { return false }
            }.count
            print("\(changed) of \(analyzedIncoming.count) fetched incoming build\(plural(analyzedIncoming.count)) " +
                  "\(analyzedIncoming.count == 1 ? "has" : "have") privacy-relevant changes.")
            print("Incoming builds are analyzed before Gatekeeper clearance, so a 'notarization' " +
                  "difference can be an artifact of the fresh download rather than a real change.")
        } else if brewMode {
            print("Analysis is of the installed version — it previews what each app already " +
                  "does, not the incoming build. Re-run with --fetch to analyze the incoming build.")
        }
    }

    /// The per-cask "incoming build" block shown under each result when --fetch
    /// is on.
    private static func renderIncoming(_ outcome: FetchOutcome) {
        switch outcome {
        case .analyzed(let d):
            let version = d.incomingVersion.map { " \($0)" } ?? ""
            print("    incoming\(version): risk \(d.installedRiskScore) → \(d.incomingRiskScore) (\(deltaLabel(d.riskScoreDelta)))")
            let changed = d.diff.changedSections
            if changed.isEmpty {
                print("      no privacy-relevant changes")
            } else {
                for sec in changed {
                    for a in sec.added    { print("      + \(sec.title): \(a)") }
                    for rm in sec.removed { print("      − \(sec.title): \(rm)") }
                    for m in sec.modified { print("      ~ \(sec.title): \(m.before) → \(m.after)") }
                }
            }
        case .skipped(let why):
            print("    incoming: skipped — \(why)")
        case .failed(let why):
            print("    incoming: could not fetch — \(why)")
        }
    }

    private static func deltaLabel(_ delta: Int) -> String {
        delta > 0 ? "Δ+\(delta)" : "Δ\(delta)"   // negative already carries its sign
    }

    private static func line(for r: Result) -> String {
        let marker = (r.summary?.isNoteworthy ?? true) ? "⚠ " : "✓ "
        var head = marker + r.target.displayName
        if case let .brewCask(token, installed, available) = r.target.source {
            head += "  (\(token))"
            if let installed, let available { head += "  \(installed) → \(available)" }
        } else if let v = r.installedVersion {
            head += "  v\(v)"
        }
        if let summary = r.summary {
            head += "  —  " + summary.headline
        } else {
            head += "  —  analysis failed"
        }
        return head
    }

    // MARK: - JSON rendering

    struct JSONEntry: Codable {
        let name: String
        let path: String
        let source: String
        let token: String?
        let installedVersion: String?
        let availableVersion: String?
        let summary: NoteworthySummary?
        let error: String?
        /// Present only with --fetch (nil omits the key — back-compatible superset).
        let fetched: FetchJSON?
    }

    struct FetchJSON: Codable {
        let status: String                 // "analyzed" | "skipped" | "failed"
        let reason: String?
        let incomingVersion: String?
        let installedRiskScore: Int?
        let incomingRiskScore: Int?
        let riskScoreDelta: Int?
        let changedSections: [SectionJSON]?
    }

    struct SectionJSON: Codable {
        let title: String
        let added: [String]
        let removed: [String]
        let modified: [String]
    }

    static func emitJSON(_ results: [Result], fetched: Bool) {
        let entries: [JSONEntry] = results.map { r in
            var token: String?, installed: String?, available: String?, source = "installed-app"
            if case let .brewCask(t, i, a) = r.target.source {
                source = "brew-cask"; token = t; installed = i; available = a
            }
            return JSONEntry(
                name: r.target.displayName,
                path: r.target.bundleURL.path,
                source: source,
                token: token,
                installedVersion: installed ?? r.installedVersion,
                availableVersion: available,
                summary: r.summary,
                error: r.error,
                fetched: fetched ? fetchJSON(r.fetched) : nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(entries), let str = String(data: data, encoding: .utf8) {
            print(str)
        } else {
            die("Failed to encode JSON output.")
        }
    }

    private static func fetchJSON(_ outcome: FetchOutcome?) -> FetchJSON? {
        switch outcome {
        case .none:
            return nil
        case .skipped(let why):
            return FetchJSON(status: "skipped", reason: why, incomingVersion: nil,
                             installedRiskScore: nil, incomingRiskScore: nil,
                             riskScoreDelta: nil, changedSections: nil)
        case .failed(let why):
            return FetchJSON(status: "failed", reason: why, incomingVersion: nil,
                             installedRiskScore: nil, incomingRiskScore: nil,
                             riskScoreDelta: nil, changedSections: nil)
        case .analyzed(let d):
            let sections = d.diff.changedSections.map { sec in
                SectionJSON(title: sec.title, added: sec.added, removed: sec.removed,
                            modified: sec.modified.map { "\($0.before) → \($0.after)" })
            }
            return FetchJSON(status: "analyzed", reason: nil,
                             incomingVersion: d.incomingVersion,
                             installedRiskScore: d.installedRiskScore,
                             incomingRiskScore: d.incomingRiskScore,
                             riskScoreDelta: d.riskScoreDelta,
                             changedSections: sections)
        }
    }

    // MARK: - Helpers

    static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    private static func plural(_ n: Int) -> String { n == 1 ? "" : "s" }

    private static func tier(from s: String) -> RiskTier? {
        switch s.lowercased() {
        case "low":      return .low
        case "medium":   return .medium
        case "high":     return .high
        case "critical": return .critical
        default:         return nil
        }
    }

    private static func rank(_ t: RiskTier) -> Int {
        switch t {
        case .low:      return 0
        case .medium:   return 1
        case .high:     return 2
        case .critical: return 3
        }
    }
}
