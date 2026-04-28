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
        public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
        public var totalChanges: Int { added.count + removed.count }
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
        let leftMap = Dictionary(uniqueKeysWithValues:
            left.staticReport.declaredPrivacyKeys.map { ($0.rawKey, $0.purposeString) })
        let rightMap = Dictionary(uniqueKeysWithValues:
            right.staticReport.declaredPrivacyKeys.map { ($0.rawKey, $0.purposeString) })

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
        return ReportDiff.DiffSection(title: title, added: added, removed: removed)
    }
}
