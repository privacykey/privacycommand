import Foundation
import privacycommandCore
import privacycommandCLIKit

/// `privacycommand preview` — analyze the apps you're about to update and surface
/// anything noteworthy, *before* you run `brew upgrade`.
///
/// Default source is the set of outdated Homebrew casks (what `brew upgrade`
/// would replace); `--all-apps` previews everything installed instead. The
/// command is inform-only: it never runs `brew upgrade` and always exits 0 on
/// success. `privacycommand upgrade` is this command with `--fetch` on.
///
/// `--max-risk <limit>` turns either into a gate (`UpgradeGate`): each cask is
/// *cleared* when the judged build's risk is at or below the limit and *held
/// for review* otherwise, and the exit status says whether anything is held.
/// `upgrade --max-risk` goes one step further and runs `brew upgrade --cask`
/// for the cleared casks (asking about the held ones on a terminal).
enum PreviewCommand {

    static let help = """
    usage: privacycommand preview [options] [cask ...]

    Analyze the apps you're about to update and flag anything noteworthy.
    By default it checks the apps an outdated `brew upgrade` would touch.
    Pass one or more cask tokens to restrict to just those casks.

    options:
      --all-apps            preview every installed .app instead of brew casks
                            (scans /Applications and ~/Applications)
      --apps-dir <dir>      preview every .app in <dir> (implies --all-apps)
      --fetch               download each incoming cask, analyze it, and show
                            what the upgrade would change (brew-cask mode only)
      --greedy              also include casks only `brew upgrade --greedy`
                            updates (apps that normally update themselves)
      --max-risk <limit>    gate: mark a cask "cleared" when its risk is at or
                            below <limit> (low|medium|high|critical, or a score
                            0-100) and "held for review" otherwise; exit 3 if
                            anything is held. Judged on the incoming build with
                            --fetch, else on the installed one. Never runs brew.
      --min-tier <tier>     only show apps at risk tier >= low|medium|high|critical
      --only-noteworthy     hide apps with nothing noteworthy
      --no-color            disable coloured output (the NO_COLOR env var also works)
      --json                emit machine-readable JSON
      -h, --help            show this help

    Without --fetch, brew hasn't downloaded the new versions yet, so this
    analyzes the *installed* build — what each app already does. With --fetch it
    downloads each incoming cask, analyzes it, and diffs it against the installed
    build to show what the upgrade would change. Either way it never runs
    `brew upgrade`.

    Casks that install no app (command-line tools, fonts, …) are listed at the
    end with the reason, along with outdated formulae, so you can see everything
    `brew upgrade` will touch. `privacycommand upgrade` is `preview --fetch`,
    and with --max-risk it also applies the cleared upgrades.

    exit codes: 0 success (with --max-risk: nothing held) · 2 bad arguments
                · 3 (--max-risk) one or more casks are held for review, so
                `privacycommand preview --fetch --max-risk medium && brew upgrade`
                only upgrades when every app cleared
    """

    static let upgradeHelp = """
    usage: privacycommand upgrade [options] [cask ...]

    Show what `brew upgrade` would change in each app and, with --max-risk,
    apply the upgrades that clear a risk limit while holding the rest for you
    to review. Downloads each outdated cask's incoming build, analyzes it, and
    diffs it against the installed app. Pass one or more cask tokens to
    restrict to just those casks.

    options:
      --max-risk <limit>    upgrade a cask when its incoming build's risk is at
                            or below <limit> (low|medium|high|critical, or a
                            score 0-100); hold it for review otherwise. On a
                            terminal each held cask then asks "upgrade anyway?"
      --dry-run             with --max-risk: show what would be upgraded and
                            what would be held, but don't run brew
      --no-input            with --max-risk: never ask about held casks (they
                            stay held); implied when stdin isn't a terminal and
                            with --json
      --greedy              also include casks only `brew upgrade --greedy`
                            updates (apps that normally update themselves)
      --min-tier <tier>     only show apps at risk tier >= low|medium|high|critical
                            (not with --max-risk, which judges every cask)
      --only-noteworthy     hide apps with nothing noteworthy (not with --max-risk)
      --no-color            disable coloured output (the NO_COLOR env var also works)
      --json                emit machine-readable JSON (brew's output goes to stderr)
      -h, --help            show this help

    Without --max-risk this is `privacycommand preview --fetch`: inform-only,
    never runs `brew upgrade`, exits 0. With --max-risk it runs
    `brew upgrade --cask <token>` for each cleared cask — with brew's auto-update
    off for that step, so it installs the build it just analyzed — and leaves
    the held ones alone. A cask whose incoming build couldn't be fetched or
    analyzed is always held. Casks that install no app (command-line tools,
    fonts) and outdated formulae aren't analyzed and aren't upgraded; the
    footer lists them with the brew command to run yourself.

    exit codes: 0 everything cleared and upgraded · 1 a brew upgrade failed
                · 2 bad arguments · 3 one or more casks are held for review

    A daily `update` that only stops to ask about risky apps:
      alias update='privacycommand upgrade --max-risk medium'
    """

    // MARK: - Entry point

    /// `upgrade` is true for `privacycommand upgrade` — `preview --fetch` under the
    /// name people reach for, with its own help and errors, and the only form
    /// that ever runs `brew upgrade` (with --max-risk).
    static func run(_ argv: [String], upgrade: Bool = false) -> Never {
        let command = upgrade ? "upgrade" : "preview"
        var allApps = false
        var appsDir: String?
        var json = false
        var onlyNoteworthy = false
        var fetch = upgrade
        var greedy = false
        var minTier: RiskTier?
        var threshold: UpgradeGate.Threshold?
        var dryRun = false
        var noInput = false
        var noColor = false
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
            case "--greedy":
                greedy = true
            case "--only-noteworthy":
                onlyNoteworthy = true
            case "--dry-run":
                dryRun = true
            case "--no-input":
                noInput = true
            case "--no-color":
                noColor = true
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
            case "--max-risk":
                i += 1
                guard i < argv.count, let t = UpgradeGate.Threshold.parse(argv[i]) else {
                    die("--max-risk needs one of: low, medium, high, critical, or a score 0-100")
                }
                threshold = t
            case "-h", "--help":
                print(upgrade ? upgradeHelp : help)
                exit(0)
            default:
                if argv[i].hasPrefix("-") {
                    die("unknown option: \(argv[i])  (see `privacycommand \(command) --help`)")
                }
                caskFilter.append(argv[i])   // positional = cask token to restrict to
            }
            i += 1
        }

        if allApps && upgrade {
            die("`privacycommand upgrade` covers outdated Homebrew casks; use `privacycommand preview --all-apps` to scan installed apps.")
        }
        if fetch && allApps {
            die("--fetch only applies to outdated Homebrew casks; drop --all-apps/--apps-dir.")
        }
        if greedy && allApps {
            die("--greedy only applies to outdated Homebrew casks; drop --all-apps/--apps-dir.")
        }
        if !caskFilter.isEmpty && allApps {
            die("cask names only apply to brew-cask mode; drop --all-apps/--apps-dir.")
        }
        if threshold != nil && allApps {
            die("--max-risk gates Homebrew cask upgrades; drop --all-apps/--apps-dir.")
        }
        if threshold != nil && (minTier != nil || onlyNoteworthy) {
            die("--max-risk judges every outdated cask; drop --min-tier/--only-noteworthy.")
        }
        if (dryRun || noInput) && !upgrade {
            die("--dry-run/--no-input only apply to `privacycommand upgrade --max-risk`.")
        }
        if (dryRun || noInput) && threshold == nil {
            die("--dry-run/--no-input need --max-risk (without it, `upgrade` never runs brew).")
        }

        let ansi = Ansi(noColor: noColor)

        // Live progress on stderr (a terminal only) from here until the
        // report: one row per app once they're known, so the wait for brew,
        // the analysis and any downloads isn't silent.
        let board = StatusBoard()
        board.setFooter("Starting")
        board.start()

        // 1. Discover the apps to preview.
        let targets: [HomebrewCaskInventory.PreviewTarget]
        var scan: HomebrewCaskInventory.OutdatedScan?
        let header: String
        do {
            if allApps {
                let dirs = appsDir.map { [URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)] }
                    ?? HomebrewCaskInventory.defaultAppDirectories()
                board.setFooter("Listing installed apps")
                targets = HomebrewCaskInventory.installedApps(in: dirs)
                header = "Scanning \(targets.count) installed app\(plural(targets.count))…"
            } else {
                var found = try HomebrewCaskInventory().outdatedScan(greedy: greedy) { board.setFooter($0) }
                if !caskFilter.isEmpty {
                    let (restricted, notes) = restrict(found, to: caskFilter)
                    found = restricted
                    notes.forEach { board.log($0) }
                }
                scan = found
                targets = found.targets
                let total = targets.count + found.skipped.count
                header = found.skipped.isEmpty
                    ? "Checking \(total) outdated Homebrew cask\(plural(total))…"
                    : "Checking \(targets.count) of \(total) outdated Homebrew casks " +
                      "(\(found.skipped.count) can't be previewed — listed at the end)…"
            }
        } catch {
            board.stop()
            die((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }

        if targets.isEmpty && (scan?.skipped.isEmpty ?? true) {
            board.stop()
            if json {
                print("[]")
            } else if allApps {
                print("No apps found.")
            } else if !caskFilter.isEmpty {
                print("No matching outdated casks.")
            } else {
                print("Nothing to upgrade — all casks are up to date. ✓")
                if let scan { printBrewNotes(scan) }
            }
            exit(0)
        }

        // The header goes out now rather than with the report, so the run says
        // what it's checking straight away.
        if !json { board.log(header, toStdout: true) }
        board.setRows(targets.map { t in
            ProgressBoard.Row(id: rowID(t), state: .queued, name: t.displayName,
                              version: versionColumn(t), status: "queued")
        })

        // 2. Analyze the installed builds (parallel — I/O-bound on codesign/spctl).
        var results = analyze(targets, board: board)

        // Display filter, reused for both the fetch set and rendering.
        let shouldShow: (Result) -> Bool = { r in
            guard let summary = r.summary else { return true } // always surface errors
            if onlyNoteworthy && !summary.isNoteworthy { return false }
            if let min = minTier, rank(summary.tier) < rank(min) { return false }
            return true
        }

        // 3. Optionally download + analyze + diff each incoming cask. Only the
        //    casks that would be shown are fetched, so --only-noteworthy /
        //    --min-tier bound how much gets downloaded. (With --max-risk those
        //    filters are rejected above, so every cask is fetched and judged.)
        if fetch {
            runFetchPass(&results, shouldShow: shouldShow, board: board)
        }
        board.stop()

        // 4. Gate: decide cleared / held per cask.
        if let threshold {
            for idx in results.indices {
                results[idx].decision = UpgradeGate.decide(
                    evidence(for: results[idx], fetched: fetch), threshold: threshold)
            }
        }

        // 5. Output, and — `upgrade --max-risk` only — apply the cleared upgrades.
        //    Human mode shows the analysis first so the "upgrade anyway?" prompts
        //    come after the findings; JSON mode runs brew first (to stderr) so
        //    the document can carry each cask's final status. (`Result` is a
        //    value type, so the shown subset is taken after that pass.)
        var brewFailed = false
        if json {
            if upgrade, threshold != nil {
                brewFailed = applyUpgrades(&results, greedy: greedy, dryRun: dryRun,
                                           askAboutHeld: false, json: true)
            }
            emitJSON(results.filter(shouldShow), skipped: scan?.skipped ?? [],
                     fetched: fetch, threshold: threshold)
        } else {
            render(all: results, shown: results.filter(shouldShow), scan: scan,
                   fetched: fetch, threshold: threshold, willUpgrade: upgrade, greedy: greedy, ansi: ansi)
            if upgrade, threshold != nil {
                let interactive = !noInput && isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
                brewFailed = applyUpgrades(&results, greedy: greedy, dryRun: dryRun,
                                           askAboutHeld: interactive, json: false, ansi: ansi)
                renderUpgradeOutcome(results, greedy: greedy, dryRun: dryRun)
            }
        }

        exit(exitStatus(results, gated: threshold != nil, brewFailed: brewFailed))
    }

    /// 0 when nothing is left held (and brew succeeded); 1 when a brew upgrade
    /// failed; 3 when a cask is still held for review after everything ran.
    /// Without --max-risk the command is inform-only and always exits 0.
    static func exitStatus(_ results: [Result], gated: Bool, brewFailed: Bool) -> Int32 {
        guard gated else { return 0 }
        if brewFailed { return 1 }
        let stillHeld = results.contains { r in
            guard let d = r.decision, !d.cleared else { return false }
            return r.upgradeStatus != .upgraded
        }
        return stillHeld ? 3 : 0
    }

    /// Restrict a scan to the named casks, with a note for each that isn't
    /// outdated. Formula / greedy notes are dropped — they're about the whole upgrade.
    static func restrict(_ scan: HomebrewCaskInventory.OutdatedScan,
                         to tokens: [String]) -> (HomebrewCaskInventory.OutdatedScan, notes: [String]) {
        let wanted = Set(tokens.map { $0.lowercased() })
        let targets = scan.targets.filter { token(of: $0).map { wanted.contains($0.lowercased()) } ?? false }
        let skipped = scan.skipped.filter { wanted.contains($0.token.lowercased()) }
        let found = Set(targets.compactMap { token(of: $0)?.lowercased() } + skipped.map { $0.token.lowercased() })
        let notes = wanted.subtracting(found).sorted().map { missing in
            let greedyOnly = scan.greedyOnlyCasks.contains { $0.lowercased() == missing }
            let hint = greedyOnly ? " (it only updates with --greedy)" : ""
            return "note: ‘\(missing)’ is not an outdated cask\(hint) — skipping."
        }
        return (HomebrewCaskInventory.OutdatedScan(targets: targets, skipped: skipped,
                                                   outdatedFormulae: [], greedyOnlyCasks: []), notes)
    }

    private static func token(of target: HomebrewCaskInventory.PreviewTarget) -> String? {
        if case .brewCask(let token, _, _) = target.source { return token }
        return nil
    }

    // MARK: - Analysis

    /// Outcome of the optional `--fetch` pass for one cask.
    enum FetchOutcome {
        case analyzed(IncomingCaskComparison.IncomingDiff)
        case skipped(String)   // expected "can't preview this one" (format/no-app)
        case failed(String)    // unexpected error (download/extract)
    }

    /// What `upgrade --max-risk` did with a cask.
    enum UpgradeStatus: String {
        case upgraded
        case failed            // its `brew upgrade` exited non-zero (brew's output says why)
        case held              // held for review and not upgraded
        case dryRun = "dry-run" // would have been upgraded (--dry-run)
    }

    struct Result {
        let target: HomebrewCaskInventory.PreviewTarget
        let installedVersion: String?
        let summary: NoteworthySummary?
        let installedReport: StaticReport?
        let error: String?
        var fetched: FetchOutcome?
        /// Set only with --max-risk.
        var decision: UpgradeGate.Decision?
        /// Set only by `upgrade --max-risk`.
        var upgradeStatus: UpgradeStatus?
    }

    static func analyze(_ targets: [HomebrewCaskInventory.PreviewTarget], board: StatusBoard) -> [Result] {
        let total = targets.count
        board.setFooter("Analyzing installed apps — 0 of \(total) done")
        var slots = [Result?](repeating: nil, count: total)
        var done = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: total) { idx in
            let target = targets[idx]
            let id = rowID(target)
            board.update(id) { $0.state = .working; $0.status = "reading the app" }
            let result: Result
            do {
                let report = try StaticAnalyzer().analyze(bundleAt: target.bundleURL) { phase in
                    board.update(id) { $0.status = StatusBoard.phaseText(phase) }
                }
                let summary = NoteworthySummary.summarize(report)
                result = Result(target: target,
                                installedVersion: report.bundle.bundleVersion,
                                summary: summary,
                                installedReport: report,
                                error: nil)
                board.update(id) {
                    $0.state = summary.isNoteworthy ? .noteworthy : .clean
                    $0.status = boardStatus(summary)
                }
            } catch {
                result = Result(target: target, installedVersion: nil,
                                summary: nil, installedReport: nil,
                                error: error.localizedDescription)
                board.update(id) { $0.state = .failed; $0.status = "couldn't analyze — " + error.localizedDescription }
            }
            lock.lock(); slots[idx] = result; done += 1; let n = done; lock.unlock()
            board.setFooter("Analyzing installed apps — \(n) of \(total) done")
        }
        return slots.compactMap { $0 }
    }

    /// The board row's key: the cask token, or the bundle path for --all-apps.
    static func rowID(_ target: HomebrewCaskInventory.PreviewTarget) -> String {
        token(of: target) ?? target.bundleURL.path
    }

    /// `3.7.0 → 3.7.4` for a cask row; nothing for a plain installed app.
    static func versionColumn(_ target: HomebrewCaskInventory.PreviewTarget) -> String? {
        guard case let .brewCask(_, installed, available) = target.source,
              let installed, let available else { return nil }
        return "\(displayVersion(installed)) → \(displayVersion(available))"
    }

    /// A row's one-line outcome: `low risk 14 · 4 findings · 2 signals`.
    static func boardStatus(_ s: NoteworthySummary) -> String {
        var bits = ["\(s.tier.label.lowercased()) risk \(s.riskScore)"]
        if !s.findings.isEmpty { bits.append("\(s.findings.count) finding\(plural(s.findings.count))") }
        if !s.signals.isEmpty { bits.append("\(s.signals.count) signal\(plural(s.signals.count))") }
        return s.isNoteworthy ? bits.joined(separator: " · ") : "nothing noteworthy · " + bits[0]
    }

    // MARK: - Fetch pass (download incoming cask → analyze → diff)

    /// For each shown brew-cask target, download the incoming artifact, analyze
    /// it, and diff against the installed build. Sequential (downloads are large
    /// and network-bound). Bridges the synchronous CLI to the async fetch API
    /// with a Task + semaphore so the process never exits before teardown.
    static func runFetchPass(_ results: inout [Result], shouldShow: (Result) -> Bool, board: StatusBoard) {
        struct Job: Sendable {
            let index: Int
            let id: String
            let token: String
            let installed: StaticReport?
            let appName: String
            let pkgPath: String?
        }

        var jobs: [Job] = []
        for i in results.indices where shouldShow(results[i]) {
            let target = results[i].target
            guard let token = token(of: target) else { continue }
            jobs.append(Job(index: i, id: rowID(target), token: token, installed: results[i].installedReport,
                            appName: target.bundleURL.lastPathComponent, pkgPath: target.incomingPkgPath))
        }
        guard !jobs.isEmpty else { return }

        // On a terminal the board shows each step; elsewhere (logs, CI) one
        // plain line per cask is enough.
        if !board.enabled {
            board.log("Fetching \(jobs.count) incoming build\(plural(jobs.count))… (downloads may be large)")
        }
        for job in jobs { board.update(job.id) { $0.state = .queued; $0.status = "waiting to download" } }

        final class Box: @unchecked Sendable { var map: [Int: FetchOutcome] = [:] }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let jobsCopy = jobs
        Task {
            for (n, job) in jobsCopy.enumerated() {
                board.setFooter("Fetching incoming builds — \(n + 1) of \(jobsCopy.count)")
                if !board.enabled { board.log("  fetching \(job.token)…") }
                board.update(job.id) { $0.state = .working; $0.status = "looking up the download" }
                let outcome = await fetchOne(
                    token: job.token, installed: job.installed, appName: job.appName, pkgPath: job.pkgPath,
                    progress: { phase in
                        switch phase {
                        case .downloading(let cacheFile):
                            board.update(job.id, live: { downloadStatus(cacheFile) }) {
                                $0.state = .downloading; $0.status = "downloading"
                            }
                        case .unpacking:
                            board.update(job.id) { $0.state = .working; $0.status = "opening the download" }
                        }
                    },
                    analyzing: { step in
                        board.update(job.id) {
                            $0.state = .working; $0.status = "analyzing the new build — " + StatusBoard.phaseText(step)
                        }
                    })
                box.map[job.index] = outcome
                let (state, status) = boardOutcome(outcome)
                board.update(job.id) { $0.state = state; $0.status = status }
            }
            semaphore.signal()
        }
        semaphore.wait()   // teardown is complete before we proceed to render/exit.

        for (i, outcome) in box.map { results[i].fetched = outcome }
    }

    /// How a cask's row ends after the fetch pass.
    static func boardOutcome(_ outcome: FetchOutcome) -> (ProgressBoard.Row.State, String) {
        switch outcome {
        case .analyzed(let d):
            let n = d.diff.changedSections.reduce(0) { $0 + $1.added.count + $1.removed.count + $1.modified.count }
            guard n > 0 else { return (.clean, "no privacy-relevant changes") }
            return (.noteworthy, "\(n) change\(plural(n)) · risk \(d.installedRiskScore) → \(d.incomingRiskScore)")
        case .skipped(let why): return (.skipped, "skipped — " + why)
        case .failed(let why):  return (.failed, "couldn't fetch — " + why)
        }
    }

    static func fetchOne(token: String, installed: StaticReport?,
                         appName: String, pkgPath: String?,
                         progress: ((CaskArtifactFetcher.Phase) -> Void)? = nil,
                         analyzing: ((String) -> Void)? = nil) async -> FetchOutcome {
        guard let installed else { return .skipped("installed build couldn't be analyzed") }
        do {
            let incoming = try await CaskArtifactFetcher.withDownloadedApp(
                token: token, preferredAppName: appName, pkgPath: pkgPath, progress: progress
            ) { app in
                analyzing?("Reading the app")
                return try StaticAnalyzer().analyze(bundleAt: app) { analyzing?($0) }
            }
            return .analyzed(IncomingCaskComparison.compare(installed: installed, incoming: incoming))
        } catch let e as CaskArtifactFetcher.FetchError {
            return e.isSkip ? .skipped(e.errorDescription ?? "skipped")
                            : .failed(e.errorDescription ?? "fetch failed")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A downloading row's live status: how much `brew fetch` has written so
    /// far (brew keeps it in `<cache file>.incomplete`), or that the download
    /// is complete and brew is verifying it.
    static func downloadStatus(_ cacheFile: URL) -> String {
        let fm = FileManager.default
        let partial = CaskArtifactFetcher.partialFile(for: cacheFile)
        if let size = (try? fm.attributesOfItem(atPath: partial.path))?[.size] as? Int64 {
            return "downloading — " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) + " so far"
        }
        // Finished (or already cached from an earlier run): brew checks it now.
        if fm.fileExists(atPath: cacheFile.path) { return "downloaded — checking its checksum" }
        return "starting the download"
    }

    /// A cask version without brew's build suffix: `3.23.23,2dac24…` → `3.23.23`.
    static func displayVersion(_ version: String) -> String {
        String(version.split(separator: ",", maxSplits: 1).first ?? Substring(version))
    }

    // MARK: - Gate (--max-risk)

    /// What the gate gets to judge for one cask. With --fetch that's the
    /// incoming build when it was analyzed; anything short of that (installed
    /// app unreadable, download skipped or failed) is "unavailable", which the
    /// gate always holds. Without --fetch it's the installed build.
    static func evidence(for r: Result, fetched: Bool) -> UpgradeGate.Evidence {
        guard let summary = r.summary else {
            return .unavailable("couldn't analyze the installed app — \(r.error ?? "unknown error")")
        }
        guard fetched else { return .installedOnly(summary) }
        switch r.fetched {
        case .analyzed(let d)?: return .incoming(d.incomingSummary)
        case .skipped(let why)?: return .unavailable("incoming build not analyzed — \(why)")
        case .failed(let why)?:  return .unavailable("couldn't fetch the incoming build — \(why)")
        case nil:                return .unavailable("incoming build wasn't fetched")
        }
    }

    /// `upgrade --max-risk`: on a terminal, ask about each held cask; then run
    /// `brew upgrade --cask <token>` for every cleared or accepted cask, one at
    /// a time so each cask gets an honest status. Records the status on each
    /// result; returns true if any brew run failed.
    static func applyUpgrades(_ results: inout [Result], greedy: Bool, dryRun: Bool,
                              askAboutHeld: Bool, json: Bool, ansi: Ansi = Ansi(enabled: false)) -> Bool {
        var toUpgrade: [Int] = []
        for i in results.indices {
            guard let d = results[i].decision, token(of: results[i].target) != nil else { continue }
            if d.cleared { toUpgrade.append(i) } else { results[i].upgradeStatus = .held }
        }

        // Review the held ones: the findings were just printed above; repeat
        // the one-line verdict and the reason so the question stands on its own.
        if askAboutHeld && !dryRun {
            let held = results.indices.filter { results[$0].upgradeStatus == .held }
            if !held.isEmpty {
                print("Held for review — answer y to upgrade anyway, anything else to leave it as is.")
            }
            for i in held {
                guard let token = token(of: results[i].target) else { continue }
                print("")
                print(line(for: results[i], ansi: ansi))
                if let reason = results[i].decision?.reason { print("    " + ansi.paint("held: \(reason)", .red)) }
                print("Upgrade \(token) anyway? [y/N] ", terminator: "")
                fflush(stdout)
                guard let answer = readLine(strippingNewline: true) else { print(""); break }   // EOF: stop asking
                if ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased()) {
                    toUpgrade.append(i)
                    results[i].upgradeStatus = nil
                }
            }
        }

        if dryRun {
            for i in toUpgrade { results[i].upgradeStatus = .dryRun }
            return false
        }

        var anyFailed = false
        for i in toUpgrade {
            guard let token = token(of: results[i].target) else { continue }
            let command = HomebrewUpgrader.commandLine(casks: [token], greedy: greedy)
            if json {
                FileHandle.standardError.write(Data("Running \(command)\n".utf8))
            } else {
                print("")
                print("▶ \(command)")
            }
            do {
                // In JSON mode brew's stdout is rerouted to stderr so the
                // document on stdout stays parseable.
                let status = try HomebrewUpgrader.run(casks: [token], greedy: greedy,
                                                      stdout: json ? .standardError : .standardOutput)
                results[i].upgradeStatus = status == 0 ? .upgraded : .failed
                if status != 0 { anyFailed = true }
            } catch {
                let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                FileHandle.standardError.write(Data("\(why)\n".utf8))
                results[i].upgradeStatus = .failed
                anyFailed = true
            }
        }
        return anyFailed
    }

    // MARK: - Human rendering

    /// The report under the header, which `run` prints before the analysis.
    static func render(all: [Result], shown: [Result],
                       scan: HomebrewCaskInventory.OutdatedScan?, fetched: Bool,
                       threshold: UpgradeGate.Threshold? = nil, willUpgrade: Bool = false,
                       greedy: Bool = false, ansi: Ansi = Ansi(enabled: false)) {
        print("")

        // With a gate: held first. Then noteworthy first, then by risk tier
        // (desc), then by name.
        let ordered = shown.sorted { a, b in
            if let da = a.decision, let db = b.decision, da.cleared != db.cleared { return !da.cleared }
            let an = a.summary?.isNoteworthy ?? true, bn = b.summary?.isNoteworthy ?? true
            if an != bn { return an && !bn }
            let ar = a.summary.map { rank($0.tier) } ?? 99, br = b.summary.map { rank($0.tier) } ?? 99
            if ar != br { return ar > br }
            return a.target.displayName.lowercased() < b.target.displayName.lowercased()
        }

        for r in ordered {
            print(line(for: r, ansi: ansi))
            if let d = r.decision, !d.cleared, let reason = d.reason {
                print("    " + ansi.paint("held: \(reason)", .red))
            }
            if let summary = r.summary {
                if !summary.findings.isEmpty {
                    print("    findings:")
                    for f in summary.findings {
                        print("      \(AuditCommand.severityTag(f.severity, ansi: ansi)) \(f.message)")
                    }
                }
                if !summary.signals.isEmpty {
                    print("    signals:")
                    for s in summary.signals { print("      • \(s)") }
                }
            } else if let err = r.error {
                print("      " + ansi.paint("couldn't analyze: \(err)", .red))
            }
            if let outcome = r.fetched { renderIncoming(outcome, ansi: ansi) }
            print("")
        }

        if let skipped = scan?.skipped, !skipped.isEmpty {
            let these = skipped.count == 1 ? "this" : "these"
            print(threshold == nil
                  ? "Not previewed — `brew upgrade` will still update \(these):"
                  : "Not analyzed, so not upgraded here — update \(these) yourself:")
            for s in skipped {
                var head = "  – \(s.token)"
                if let i = s.installedVersion, let a = s.availableVersion {
                    head += "  \(displayVersion(i)) → \(displayVersion(a))"
                }
                print(ansi.paint(head + "  —  " + s.reason, .dim))
            }
            if threshold != nil {
                print("  " + HomebrewUpgrader.commandLine(casks: skipped.map(\.token), greedy: greedy))
            }
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
            print(ansi.paint("Incoming builds are analyzed before Gatekeeper clearance, so a 'notarization' " +
                             "difference can be an artifact of the fresh download rather than a real change.", .dim))
        } else if scan != nil {
            print(ansi.paint("Analysis is of the installed version — it previews what each app already " +
                             "does, not the incoming build. Re-run with --fetch to analyze the incoming build.", .dim))
        }
        if let scan { printBrewNotes(scan) }

        if let threshold {
            let decided = all.filter { $0.decision != nil }
            let cleared = decided.filter { $0.decision?.cleared == true }
            let held = decided.count - cleared.count
            let basis = fetched ? "the incoming build" : "the installed build"
            print("")
            print("Gate: cleared when risk ≤ \(threshold.description), judged on \(basis).")
            print("\(cleared.count) cleared, \(held) held for review.")
            if !willUpgrade {
                let tokens = cleared.compactMap { token(of: $0.target) }
                if !tokens.isEmpty {
                    print("To upgrade the cleared casks: " + HomebrewUpgrader.commandLine(casks: tokens, greedy: greedy))
                }
            }
        }
    }

    /// After `applyUpgrades`: what happened, and the command for whatever is
    /// still held so it's one paste away once the person is satisfied.
    private static func renderUpgradeOutcome(_ results: [Result], greedy: Bool, dryRun: Bool) {
        func tokens(_ status: UpgradeStatus) -> [String] {
            results.filter { $0.upgradeStatus == status }.compactMap { token(of: $0.target) }
        }
        let upgraded = tokens(.upgraded), failed = tokens(.failed)
        let held = tokens(.held), wouldUpgrade = tokens(.dryRun)
        print("")
        if dryRun {
            print(wouldUpgrade.isEmpty
                  ? "Dry run: nothing would be upgraded."
                  : "Dry run: would run " + HomebrewUpgrader.commandLine(casks: wouldUpgrade, greedy: greedy))
        } else {
            if !upgraded.isEmpty {
                print("Upgraded \(upgraded.count) cask\(plural(upgraded.count)): \(upgraded.joined(separator: ", ")).")
            }
            if !failed.isEmpty {
                print("Failed to upgrade \(failed.count) cask\(plural(failed.count)) (see brew's output above): " +
                      failed.joined(separator: ", ") + ".")
            }
            if upgraded.isEmpty && failed.isEmpty && held.isEmpty {
                print("Nothing to upgrade.")
            }
        }
        if !held.isEmpty {
            print("Held for review, not upgraded: \(held.joined(separator: ", ")).")
            print("  to upgrade anyway: " + HomebrewUpgrader.commandLine(casks: held, greedy: greedy))
        }
    }

    /// Footer lines about what `brew upgrade` touches beyond the apps above.
    private static func printBrewNotes(_ scan: HomebrewCaskInventory.OutdatedScan) {
        let formulae = scan.outdatedFormulae
        if !formulae.isEmpty {
            print("`brew upgrade` will also update \(formulae.count) formula\(formulae.count == 1 ? "" : "e") " +
                  "(command-line packages, not analyzed): \(list(formulae)).")
        }
        let greedy = scan.greedyOnlyCasks
        if !greedy.isEmpty {
            print("\(greedy.count) more cask\(plural(greedy.count)) only update with `brew upgrade --greedy` " +
                  "(\(list(greedy))); add --greedy to include \(greedy.count == 1 ? "it" : "them").")
        }
    }

    private static func list(_ names: [String], limit: Int = 6) -> String {
        guard names.count > limit else { return names.joined(separator: ", ") }
        return names.prefix(limit).joined(separator: ", ") + ", +\(names.count - limit) more"
    }

    /// The per-cask "incoming build" block shown under each result when --fetch
    /// is on.
    private static func renderIncoming(_ outcome: FetchOutcome, ansi: Ansi) {
        switch outcome {
        case .analyzed(let d):
            let version = d.incomingVersion.map { " \($0)" } ?? ""
            let delta = d.riskScoreDelta
            let deltaText = ansi.paint("(\(deltaLabel(delta)))", delta > 0 ? .yellow : delta < 0 ? .green : .dim)
            print("    incoming\(version): risk \(d.installedRiskScore) → \(d.incomingRiskScore) \(deltaText)")
            let changed = d.diff.changedSections
            if changed.isEmpty {
                print("      " + ansi.paint("no privacy-relevant changes", .green))
            } else {
                for sec in changed {
                    for a in sec.added    { print("      " + ansi.paint("+ \(sec.title): \(a)", .yellow)) }
                    for rm in sec.removed { print("      " + ansi.paint("− \(sec.title): \(rm)", .dim)) }
                    for m in sec.modified { print("      ~ \(sec.title): \(m.before) → \(m.after)") }
                }
            }
        case .skipped(let why):
            print("    " + ansi.paint("incoming: skipped — \(why)", .dim))
        case .failed(let why):
            print("    " + ansi.paint("incoming: could not fetch — \(why)", .red))
        }
    }

    private static func deltaLabel(_ delta: Int) -> String {
        delta > 0 ? "Δ+\(delta)" : "Δ\(delta)"   // negative already carries its sign
    }

    private static func line(for r: Result, ansi: Ansi = Ansi(enabled: false)) -> String {
        // With a gate the marker is the verdict; otherwise it's "noteworthy?".
        let marker: String
        if let d = r.decision {
            marker = d.cleared ? ansi.paint("✓ cleared", .green) + "  " : ansi.paint("⚠ review", .yellow) + "   "
        } else {
            marker = (r.summary?.isNoteworthy ?? true) ? ansi.paint("⚠", .yellow) + " " : ansi.paint("✓", .green) + " "
        }
        var head = marker + ansi.paint(r.target.displayName, .bold)
        if case let .brewCask(token, installed, available) = r.target.source {
            head += "  " + ansi.paint("(\(token))", .dim)
            if let installed, let available {
                head += "  \(displayVersion(installed)) → \(displayVersion(available))"
            }
        } else if let v = r.installedVersion {
            head += "  v\(v)"
        }
        if let summary = r.summary {
            head += "  —  " + ansi.paint(summary.headline, AuditCommand.tierCode(summary.tier))
        } else {
            head += "  —  " + ansi.paint("analysis failed", .red)
        }
        return head
    }

    // MARK: - JSON rendering

    struct JSONEntry: Codable {
        let name: String
        /// nil for a skipped cask (no app to point at).
        let path: String?
        let source: String
        let token: String?
        let installedVersion: String?
        let availableVersion: String?
        let summary: NoteworthySummary?
        let error: String?
        /// Why a cask `brew upgrade` will update wasn't previewed (no app, …).
        let skippedReason: String?
        /// Present only with --fetch (nil omits the key — back-compatible superset).
        let fetched: FetchJSON?
        /// Present only with --max-risk.
        let gate: GateJSON?
        /// Present only for `upgrade --max-risk`: "upgraded" | "failed" |
        /// "held" | "dry-run".
        let upgrade: String?
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

    struct GateJSON: Codable {
        let decision: String               // "cleared" | "held"
        let reason: String?                // why it's held
        let score: Int?                    // the score judged (nil: nothing analyzable)
        let tier: String?
        let basis: String?                 // "incoming" | "installed"
        let maxRisk: Int                   // the --max-risk limit as a score
    }

    static func emitJSON(_ results: [Result], skipped: [HomebrewCaskInventory.SkippedCask],
                         fetched: Bool, threshold: UpgradeGate.Threshold? = nil) {
        var entries: [JSONEntry] = results.map { r in
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
                skippedReason: nil,
                fetched: fetched ? fetchJSON(r.fetched) : nil,
                gate: gateJSON(r.decision, threshold: threshold),
                upgrade: r.upgradeStatus?.rawValue)
        }
        entries += skipped.map { s in
            JSONEntry(name: s.token, path: nil, source: "brew-cask", token: s.token,
                      installedVersion: s.installedVersion, availableVersion: s.availableVersion,
                      summary: nil, error: nil, skippedReason: s.reason, fetched: nil,
                      gate: nil, upgrade: nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(entries), let str = String(data: data, encoding: .utf8) {
            print(str)
        } else {
            die("Failed to encode JSON output.")
        }
    }

    private static func gateJSON(_ d: UpgradeGate.Decision?, threshold: UpgradeGate.Threshold?) -> GateJSON? {
        guard let d, let threshold else { return nil }
        return GateJSON(decision: d.cleared ? "cleared" : "held", reason: d.reason,
                        score: d.score, tier: d.tier?.rawValue, basis: d.basis?.rawValue,
                        maxRisk: threshold.maxScore)
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
