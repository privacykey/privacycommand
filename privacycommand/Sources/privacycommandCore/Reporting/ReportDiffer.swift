import Foundation

// MARK: - Public types

public struct ReportDiff: Hashable, Sendable {
    public let left: ReportSide
    public let right: ReportSide
    public let riskScoreDelta: Int
    public let sections: [DiffSection]

    /// Sections that actually changed (non-empty added or removed).
    public var changedSections: [DiffSection] { sections.filter { !$0.isEmpty } }
    public var hasAnyChange: Bool { !changedSections.isEmpty }

    public struct ReportSide: Hashable, Sendable {
        public let id: UUID
        public let displayName: String
        public let version: String?
        public let analyzedAt: Date
        public let riskScore: RiskScore
    }

    public struct DiffSection: Hashable, Sendable, Identifiable {
        public var id: String { title }
        public let title: String
        public let added: [String]
        public let removed: [String]
        /// Items present on both sides that differ only by a volatile build
        /// token (e.g. a Rust `/rustc/<hash>/…` path). Surfaced as a single
        /// "modified" entry instead of a separate added + removed pair, so the
        /// diff of a hash-stamped binary isn't drowned in per-build churn.
        public let modified: [Change]

        public init(title: String, added: [String], removed: [String], modified: [Change] = []) {
            self.title = title
            self.added = added
            self.removed = removed
            self.modified = modified
        }

        public var isEmpty: Bool { added.isEmpty && removed.isEmpty && modified.isEmpty }
        public var totalChanges: Int { added.count + removed.count + modified.count }

        /// One item that changed in place: the same logical entry with a
        /// different volatile token. `display` is the normalised form (volatile
        /// part replaced by a placeholder) for compact rendering; `before`/
        /// `after` keep the full strings for detail/tooltips.
        public struct Change: Hashable, Sendable, Identifiable {
            public var id: String { "\(before)\u{1}\(after)" }
            public let before: String
            public let after: String
            public let display: String
            /// The actual volatile token(s) that changed (e.g. the old vs new
            /// rustc commit hash), kept so the real values stay comparable
            /// instead of being hidden behind the `<hash>` placeholder.
            public let tokens: [TokenChange]

            public init(before: String, after: String, display: String, tokens: [TokenChange] = []) {
                self.before = before
                self.after = after
                self.display = display
                self.tokens = tokens
            }

            /// One volatile token's before → after values.
            public struct TokenChange: Hashable, Sendable {
                public let before: String
                public let after: String
                public init(before: String, after: String) {
                    self.before = before
                    self.after = after
                }
            }
        }
    }
}

// MARK: - Differ

public struct ReportDiffer: Sendable {

    public init() {}

    public func diff(left: RunReport, right: RunReport) -> ReportDiff {
        let leftSide  = makeSide(left)
        let rightSide = makeSide(right)

        let scoreDelta = right.summary.riskScore.score - left.summary.riskScore.score

        let sections: [ReportDiff.DiffSection] = [
            diffPrivacyKeys(left, right),
            diffEntitlements(left, right),
            diffFrameworks(left, right),
            diffURLSchemes(left, right),
            diffEmbeddedBundles(left.staticReport.xpcServices, right.staticReport.xpcServices, title: "XPC services"),
            diffEmbeddedBundles(left.staticReport.helpers,     right.staticReport.helpers,     title: "Helpers"),
            diffEmbeddedBundles(left.staticReport.loginItems,  right.staticReport.loginItems,  title: "Login items"),
            diffStringSet(Set(left.staticReport.hardcodedDomains), Set(right.staticReport.hardcodedDomains), title: "Hard-coded domains"),
            diffStringSet(Set(left.staticReport.hardcodedPaths),   Set(right.staticReport.hardcodedPaths),   title: "Hard-coded paths"),
            diffFindings(left, right),
            diffNetworkHosts(left, right),
            diffNetworkCallSites(left, right),
            diffPathCategories(left, right)
        ]

        return ReportDiff(
            left: leftSide,
            right: rightSide,
            riskScoreDelta: scoreDelta,
            sections: sections
        )
    }

    // MARK: - Builders

    private func makeSide(_ report: RunReport) -> ReportDiff.ReportSide {
        ReportDiff.ReportSide(
            id: report.id,
            displayName: report.bundle.bundleName ?? report.bundle.bundleID ?? "?",
            version: report.bundle.bundleVersion,
            analyzedAt: report.endedAt,
            riskScore: report.summary.riskScore
        )
    }

    private func diffPrivacyKeys(_ left: RunReport, _ right: RunReport) -> ReportDiff.DiffSection {
        // Privacy keys can be added / removed AND have their purpose strings
        // edited. We surface key changes here; purpose-string edits come
        // through as "modified" entries with the new purpose appended.
        // Use uniquingKeysWith: rather than uniqueKeysWithValues: —
        // a malformed source Info.plist with duplicate privacy keys
        // would otherwise trap. Keep the last-seen purpose string to
        // match Info.plist's "last write wins" reading semantics.
        let leftMap = Dictionary(
            left.staticReport.declaredPrivacyKeys.map { ($0.rawKey, $0.purposeString) },
            uniquingKeysWith: { _, last in last })
        let rightMap = Dictionary(
            right.staticReport.declaredPrivacyKeys.map { ($0.rawKey, $0.purposeString) },
            uniquingKeysWith: { _, last in last })

        let leftKeys = Set(leftMap.keys), rightKeys = Set(rightMap.keys)

        let addedKeys = rightKeys.subtracting(leftKeys).sorted()
        let removedKeys = leftKeys.subtracting(rightKeys).sorted()

        // Purpose-string edits — show inline, but tag with "(purpose changed)"
        var purposeEdits: [String] = []
        for key in leftKeys.intersection(rightKeys).sorted() where leftMap[key] != rightMap[key] {
            purposeEdits.append("\(key) — purpose: ‘\(leftMap[key] ?? "")’ → ‘\(rightMap[key] ?? "")’")
        }

        return ReportDiff.DiffSection(
            title: "Privacy keys",
            added: addedKeys + purposeEdits,
            removed: removedKeys
        )
    }

    private func diffNetworkCallSites(_ left: RunReport, _ right: RunReport) -> ReportDiff.DiffSection {
        func keys(_ r: RunReport) -> Set<String> {
            Set(r.staticReport.networkCallSites.map { site in
                let syms = site.calls.map(\.symbol).sorted().joined(separator: ", ")
                return "\(site.function) [\(syms)]"
            })
        }
        return diffStringSet(keys(left), keys(right), title: "Network call sites")
    }

    private func diffEntitlements(_ left: RunReport, _ right: RunReport) -> ReportDiff.DiffSection {
        let leftEnt  = Set(left.staticReport.entitlements.raw.keys)
        let rightEnt = Set(right.staticReport.entitlements.raw.keys)
        return diffStringSet(leftEnt, rightEnt, title: "Entitlements")
    }

    private func diffFrameworks(_ left: RunReport, _ right: RunReport) -> ReportDiff.DiffSection {
        let leftFW  = Set(left.staticReport.frameworks.compactMap  { $0.bundleID ?? $0.url.lastPathComponent })
        let rightFW = Set(right.staticReport.frameworks.compactMap { $0.bundleID ?? $0.url.lastPathComponent })
        return diffStringSet(leftFW, rightFW, title: "Frameworks")
    }

    private func diffURLSchemes(_ left: RunReport, _ right: RunReport) -> ReportDiff.DiffSection {
        let leftSch  = Set(left.staticReport.urlSchemes.flatMap(\.schemes))
        let rightSch = Set(right.staticReport.urlSchemes.flatMap(\.schemes))
        return diffStringSet(leftSch, rightSch, title: "URL schemes")
    }

    private func diffEmbeddedBundles(_ leftBundles: [BundleRef],
                                     _ rightBundles: [BundleRef],
                                     title: String) -> ReportDiff.DiffSection {
        let leftSet  = Set(leftBundles.compactMap  { $0.bundleID ?? $0.url.lastPathComponent })
        let rightSet = Set(rightBundles.compactMap { $0.bundleID ?? $0.url.lastPathComponent })
        return diffStringSet(leftSet, rightSet, title: title)
    }

    private func diffFindings(_ left: RunReport, _ right: RunReport) -> ReportDiff.DiffSection {
        // Compare by message string — same warning twice across versions
        // shouldn't show as a diff.
        let leftSet  = Set(left.staticReport.warnings.map  { "[\($0.severity.rawValue)] \($0.message)" })
        let rightSet = Set(right.staticReport.warnings.map { "[\($0.severity.rawValue)] \($0.message)" })
        return diffStringSet(leftSet, rightSet, title: "Findings")
    }

    private func diffNetworkHosts(_ left: RunReport, _ right: RunReport) -> ReportDiff.DiffSection {
        let leftSet  = Set(left.summary.topRemoteHosts.map(\.host))
        let rightSet = Set(right.summary.topRemoteHosts.map(\.host))
        return diffStringSet(leftSet, rightSet, title: "Top remote hosts")
    }

    private func diffPathCategories(_ left: RunReport, _ right: RunReport) -> ReportDiff.DiffSection {
        // Categories that appear on one side but not the other; ignores
        // count differences (those would create noise).
        let leftSet  = Set(left.summary.topPathCategories.map  { $0.category.rawValue })
        let rightSet = Set(right.summary.topPathCategories.map { $0.category.rawValue })
        return diffStringSet(leftSet, rightSet, title: "Path categories touched")
    }

    private func diffStringSet(_ left: Set<String>, _ right: Set<String>, title: String) -> ReportDiff.DiffSection {
        let added   = Array(right.subtracting(left)).sorted()
        let removed = Array(left.subtracting(right)).sorted()
        let c = coalesceVolatile(added: added, removed: removed)
        return ReportDiff.DiffSection(title: title, added: c.added, removed: c.removed, modified: c.modified)
    }

    // MARK: - Volatile-token coalescing

    /// Pair an added item with a removed item when the two are identical after
    /// normalising volatile build tokens. Such a pair is the *same* item
    /// rebuilt (e.g. a Rust binary's `/rustc/<commit>/library/std/…` path where
    /// only the commit hash rotates), not a genuine add + remove — collapsing
    /// it into a single "modified" entry keeps the diff readable.
    func coalesceVolatile(added: [String], removed: [String])
        -> (added: [String], removed: [String], modified: [ReportDiff.DiffSection.Change]) {

        // Bucket only the removed items that actually carry a volatile token
        // (their normalised form differs from the original); nothing else can
        // ever pair. Sort buckets so pairing is deterministic.
        var removedByKey: [String: [String]] = [:]
        for r in removed {
            let key = Self.normalizeVolatile(r)
            if key != r { removedByKey[key, default: []].append(r) }
        }
        for key in removedByKey.keys { removedByKey[key]?.sort() }

        var remainingAdded: [String] = []
        var modified: [ReportDiff.DiffSection.Change] = []
        var consumedRemoved = Set<String>()

        for a in added {
            let key = Self.normalizeVolatile(a)
            if key != a, var bucket = removedByKey[key], !bucket.isEmpty {
                let before = bucket.removeFirst()
                removedByKey[key] = bucket
                consumedRemoved.insert(before)
                modified.append(.init(before: before, after: a, display: key,
                                      tokens: Self.tokenChanges(before: before, after: a)))
            } else {
                remainingAdded.append(a)
            }
        }

        let remainingRemoved = removed.filter { !consumedRemoved.contains($0) }
        return (remainingAdded,
                remainingRemoved,
                modified.sorted { $0.display < $1.display })
    }

    /// Replace per-build volatile identifiers with stable placeholders so that
    /// strings differing only by a build token compare equal. Conservative —
    /// only UUIDs and hex runs of 16+ chars (git/rustc commit hashes, cargo
    /// registry hashes) are touched, so unrelated items aren't merged.
    static func normalizeVolatile(_ s: String) -> String {
        s.replacing(uuidPattern, with: "<id>")
         .replacing(hashPattern, with: "<hash>")
    }
    private static let uuidPattern =
        try! Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    private static let hashPattern = try! Regex("[0-9a-fA-F]{16,}")

    /// The actual volatile tokens that differ between two otherwise-identical
    /// strings, paired by position. Because both sides normalise to the same
    /// form, their token lists line up 1:1; we keep only the ones that changed.
    static func tokenChanges(before: String, after: String) -> [ReportDiff.DiffSection.Change.TokenChange] {
        let b = volatileTokens(before), a = volatileTokens(after)
        guard b.count == a.count else { return [] }
        return zip(b, a).filter { $0 != $1 }.map { .init(before: $0, after: $1) }
    }

    /// Volatile tokens (UUIDs and 16+ hex runs) in left-to-right order — the
    /// same spans `normalizeVolatile` would replace.
    static func volatileTokens(_ s: String) -> [String] {
        s.matches(of: volatilePattern).map { String(s[$0.range]) }
    }
    private static let volatilePattern = try! Regex(
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{16,}")
}
