import Foundation
import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Drives a batch scan: enumerates apps, streams them through
/// `BatchAnalyzer`, and exposes the live, filtered, sorted result set the
/// `BatchScanView` table renders. One instance per batch window.
///
/// "Always fresh" by design — nothing is persisted between scans (the user
/// chose this). Re-scanning re-analyses every app; results live only in
/// memory and via explicit CSV/JSON export.
@MainActor
final class BatchScanModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        case done
        case cancelled
    }

    // Scan state
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [BatchAppResult] = []
    @Published private(set) var total = 0
    @Published private(set) var completed = 0
    @Published private(set) var currentName = ""
    @Published private(set) var scopeLabel = ""

    // Options
    @Published var includeSystemApps = false

    // Filter / sort (bound to the UI)
    @Published var searchText = ""
    @Published var requiredFlags: Set<BatchFlag> = []
    @Published var minTier: RiskTier? = nil
    @Published var archClass: ArchClass? = nil
    @Published var updateFilter: UpdateFilter? = nil
    @Published var sandboxed: Bool? = nil
    @Published var hasDownloadMetadata: Bool? = nil
    @Published var minOSBucket: MinOSBucket? = nil
    @Published var sortOrder: [KeyPathComparator<BatchAppResult>] =
        [KeyPathComparator(\BatchAppResult.risk.score, order: .reverse)]

    private var scanTask: Task<Void, Never>?

    // MARK: - Derived

    var filter: BatchFilter {
        BatchFilter(searchText: searchText, requiredFlags: requiredFlags, minTier: minTier,
                    archClass: archClass, updateFilter: updateFilter,
                    sandboxed: sandboxed, hasDownloadMetadata: hasDownloadMetadata,
                    minOSBucket: minOSBucket)
    }

    func clearFilters() {
        searchText = ""
        requiredFlags = []
        minTier = nil
        archClass = nil
        updateFilter = nil
        sandboxed = nil
        hasDownloadMetadata = nil
        minOSBucket = nil
    }

    /// The rows actually shown: filter applied, then sorted by the table's
    /// current sort order.
    var filteredSorted: [BatchAppResult] {
        results.filter(filter.matches).sorted(using: sortOrder)
    }

    var isScanning: Bool { phase == .scanning }

    var progressFraction: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }

    /// Tier tallies over the *unfiltered* results — the at-a-glance health
    /// summary shown in the toolbar.
    struct Tally { var critical = 0, high = 0, medium = 0, low = 0, failed = 0 }
    var tally: Tally {
        var t = Tally()
        for r in results {
            if r.flags.contains(.analysisFailed) { t.failed += 1; continue }
            switch r.risk.tier {
            case .critical: t.critical += 1
            case .high:     t.high += 1
            case .medium:   t.medium += 1
            case .low:      t.low += 1
            }
        }
        return t
    }

    /// How many apps trip a given concern flag — powers the count badges on
    /// the filter chips.
    func count(of flag: BatchFlag) -> Int {
        results.reduce(0) { $0 + ($1.flags.contains(flag) ? 1 : 0) }
    }

    // MARK: - Scanning

    /// Scan the default user-app locations.
    func scanDefault() {
        let roots = InstalledAppEnumerator.defaultRoots(includeSystem: includeSystemApps)
        let urls = InstalledAppEnumerator.appBundles(in: roots)
        let label = roots.map { $0.path }.joined(separator: ", ")
        start(urls: urls, scopeLabel: label)
    }

    /// Present an open panel for a folder, then scan it recursively.
    func pickFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan for apps"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let urls = InstalledAppEnumerator.appBundles(inFolder: folder)
        start(urls: urls, scopeLabel: folder.path)
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        if phase == .scanning { phase = .cancelled }
    }

    private func start(urls: [URL], scopeLabel: String) {
        scanTask?.cancel()
        results = []
        completed = 0
        total = urls.count
        currentName = ""
        self.scopeLabel = scopeLabel
        phase = .scanning

        guard !urls.isEmpty else { phase = .done; return }

        let stream = BatchAnalyzer().stream(urls: urls)
        scanTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .started(let t):
                    self.total = t
                case .result(let r):
                    self.results.append(r)
                    self.currentName = r.displayName
                case .progress(let done, _):
                    self.completed = done
                case .finished:
                    self.phase = .done
                }
            }
        }
    }

    // MARK: - Export

    func exportCSV() {
        save(suggested: "app-scan.csv", contentType: "csv") {
            BatchReport.csv(self.filteredSorted).data(using: .utf8) ?? Data()
        }
    }

    func exportJSON() {
        save(suggested: "app-scan.json", contentType: "json") {
            let report = BatchReport(scope: self.scopeLabel, results: self.filteredSorted)
            return (try? report.jsonData()) ?? Data()
        }
    }

    private func save(suggested: String, contentType ext: String, makeData: @escaping () -> Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try makeData().write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
