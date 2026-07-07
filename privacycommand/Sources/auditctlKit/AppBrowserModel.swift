import Foundation

/// One row in the browser — an installed app to (lazily) audit.
public struct AppEntry: Equatable, Sendable {
    public let name: String
    public let url: URL
    public var path: String { url.path }
    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// Per-app analysis lifecycle. The driver drives the transitions; the renderer
/// reads them.
public enum AuditState: Sendable, Equatable {
    case notStarted
    case analyzing
    case done(AuditSnapshot)
    case failed(String)
}

/// The entire interactive-browser state as a value type. It is owned and
/// mutated only on the main thread (the analysis worker never touches it — it
/// posts results to an inbox the main loop drains), so no locking lives here
/// and every transition is a plain, testable `mutating` method.
public struct AppBrowserModel: Sendable {

    public enum Sort: Sendable, Equatable { case name, risk }

    public private(set) var apps: [AppEntry]
    public private(set) var filter: String = ""
    public private(set) var sort: Sort = .name
    /// Selection is an index into `visible` (the filtered+sorted list).
    public private(set) var selection: Int = 0
    public private(set) var scrollOffset: Int = 0
    private var states: [String: AuditState] = [:]

    public init(apps: [AppEntry]) {
        self.apps = apps
    }

    // MARK: - Derived views

    /// Filtered by the current query, then ordered by the current sort.
    public var visible: [AppEntry] {
        let needle = filter.lowercased()
        var list = needle.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(needle) }
        switch sort {
        case .name:
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .risk:
            // Analyzed apps first, highest risk score first; ties alphabetical.
            list.sort { a, b in
                let ra = riskRank(a), rb = riskRank(b)
                if ra != rb { return ra > rb }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        return list
    }

    private func riskRank(_ e: AppEntry) -> Int {
        if case .done(let snap) = state(of: e) { return snap.riskScore }
        return -1   // not-yet-analyzed sorts after everything scored
    }

    public func state(of e: AppEntry) -> AuditState { states[e.path] ?? .notStarted }

    public var selectedApp: AppEntry? {
        let v = visible
        return v.indices.contains(selection) ? v[selection] : nil
    }

    public var selectedState: AuditState { selectedApp.map(state(of:)) ?? .notStarted }

    public var totalCount: Int { apps.count }
    public var visibleCount: Int { visible.count }
    public var analyzedCount: Int {
        states.values.reduce(0) { if case .done = $1 { return $0 + 1 }; return $0 }
    }

    /// The slice of rows to paint for a list viewport `height` rows tall, using
    /// the current (already-updated) scroll offset.
    public func visibleWindow(height: Int) -> [AppEntry] {
        let v = visible
        let h = max(1, height)
        let start = min(max(0, scrollOffset), max(0, v.count - 1))
        let end = min(start + h, v.count)
        return start < end ? Array(v[start ..< end]) : []
    }

    // MARK: - Navigation

    public mutating func move(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { selection = 0; return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    public mutating func moveToStart() { selection = 0 }
    public mutating func moveToEnd() { selection = max(0, visible.count - 1) }

    /// Keep the selection inside a viewport `height` rows tall by nudging the
    /// scroll offset. Call once before each render.
    public mutating func updateScroll(viewportHeight height: Int) {
        let count = visible.count
        let h = max(1, height)
        if selection < scrollOffset {
            scrollOffset = selection
        } else if selection >= scrollOffset + h {
            scrollOffset = selection - h + 1
        }
        let maxOffset = max(0, count - h)
        scrollOffset = min(max(0, scrollOffset), maxOffset)
    }

    // MARK: - Filter

    public var filterIsEmpty: Bool { filter.isEmpty }

    public mutating func appendFilter(_ c: Character) {
        filter.append(c)
        clampSelection()
    }

    public mutating func deleteFilterChar() {
        guard !filter.isEmpty else { return }
        filter.removeLast()
        clampSelection()
    }

    public mutating func clearFilter() {
        filter = ""
        clampSelection()
    }

    // MARK: - Sort

    public mutating func cycleSort() {
        sort = (sort == .name) ? .risk : .name
        clampSelection()
    }

    // MARK: - Analysis state

    public mutating func setState(_ s: AuditState, forPath path: String) {
        states[path] = s
    }

    public mutating func markAnalyzing(path: String) {
        states[path] = .analyzing
    }

    /// Drop the selected app's cached result so the driver re-runs analysis.
    public mutating func reanalyzeSelected() {
        if let path = selectedApp?.path { states[path] = .notStarted }
    }

    private mutating func clampSelection() {
        let count = visible.count
        selection = count == 0 ? 0 : min(selection, count - 1)
    }
}
