import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Side-by-side comparison of two saved runs. Presented as a sheet from the
/// History tab. Two pickers select the runs; the body shows a per-section
/// added/removed list with color cues.
struct CompareView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator

    @State private var leftID: UUID?
    @State private var rightID: UUID?
    @State private var diff: ReportDiff?
    @State private var showOnlyChanges = true
    @State private var loadError: String?

    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pickers
            Divider()
            content
        }
        .frame(minWidth: 880, minHeight: 600)
        .onAppear { primeDefaults() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Compare runs").font(.title2.bold())
            Spacer()
            Toggle("Show only changes", isOn: $showOnlyChanges)
                .toggleStyle(.switch)
                .labelsHidden()
            Text("Show only changes").font(.callout).foregroundStyle(.secondary)
            Button("Done", action: onClose).keyboardShortcut(.return)
        }
        .padding()
    }

    // MARK: - Pickers

    private var pickers: some View {
        HStack(alignment: .top, spacing: 12) {
            picker(title: "Left", selection: $leftID, exclude: rightID)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)
                .padding(.top, 32)
            picker(title: "Right", selection: $rightID, exclude: leftID)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .onChange(of: leftID) { _ in recomputeDiff() }
        .onChange(of: rightID) { _ in recomputeDiff() }
    }

    private func picker(title: String, selection: Binding<UUID?>, exclude: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold()).foregroundStyle(.secondary)
            Picker("", selection: selection) {
                Text("— Pick a run —").tag(nil as UUID?)
                ForEach(coordinator.recentRuns.filter { $0.id != exclude }) { meta in
                    Text(label(for: meta)).tag(meta.id as UUID?)
                }
            }
            .labelsHidden()
            if let id = selection.wrappedValue,
               let meta = coordinator.recentRuns.first(where: { $0.id == id }) {
                runSummaryCard(meta: meta)
            }
        }
    }

    private func label(for meta: RunReportMeta) -> String {
        let v = meta.bundle.bundleVersion.map { " v\($0)" } ?? ""
        let when = meta.endedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(meta.displayName)\(v) — \(when)"
    }

    private func runSummaryCard(meta: RunReportMeta) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RiskTierBadge(score: meta.summary.riskScore)
            Text("\(meta.summary.networkEventCount) net · \(meta.summary.fileEventCount) file")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.title)
                Text("Couldn't load runs").font(.headline)
                Text(err).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if let diff {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headlineCard(diff)
                    let sections = showOnlyChanges ? diff.changedSections : diff.sections
                    if sections.isEmpty {
                        emptyState
                    } else {
                        ForEach(sections) { section in
                            sectionView(section, rightName: diff.right.displayName)
                        }
                    }
                }
                .padding(20)
            }
        } else {
            VStack {
                Spacer()
                Text("Pick two runs above to compare them.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func headlineCard(_ diff: ReportDiff) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    sideSummary(diff.left, role: "Baseline (left)")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    sideSummary(diff.right, role: "Compared (right)")
                    Spacer()
                    deltaCard(diff)
                }
                Divider()
                changeSummary(diff)
            }
            .padding(8)
        }
    }

    /// One-line plain-language summary framed from the right app's point of
    /// view: "<right> adds N, removes M vs <left>". Makes it obvious that the
    /// right column is the one whose changes are listed below.
    private func changeSummary(_ diff: ReportDiff) -> some View {
        let added = diff.sections.reduce(0) { $0 + $1.added.count }
        let removed = diff.sections.reduce(0) { $0 + $1.removed.count }
        let modified = diff.sections.reduce(0) { $0 + $1.modified.count }
        return HStack(spacing: 8) {
            Text(diff.right.displayName).font(.callout.bold())
            if added == 0 && removed == 0 && modified == 0 {
                Text("has no tracked changes vs \(diff.left.displayName)")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if added > 0 {
                    Label("\(added) added", systemImage: "plus.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                }
                if removed > 0 {
                    Label("\(removed) removed", systemImage: "minus.circle.fill")
                        .font(.callout).foregroundStyle(.red)
                }
                if modified > 0 {
                    Label("\(modified) modified", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                Text("vs \(diff.left.displayName)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func sideSummary(_ side: ReportDiff.ReportSide, role: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(role.uppercased())
                .font(.caption2.bold()).foregroundStyle(.secondary)
            Text(side.displayName).font(.headline)
            HStack(spacing: 6) {
                if let v = side.version {
                    Text("v\(v)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text(side.analyzedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            RiskTierBadge(score: side.riskScore)
        }
    }

    private func deltaCard(_ diff: ReportDiff) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Risk Δ")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: deltaIcon(diff.riskScoreDelta))
                Text(deltaText(diff.riskScoreDelta))
                    .font(.title3.bold().monospacedDigit())
            }
            .foregroundStyle(deltaColor(diff.riskScoreDelta))
        }
    }

    private func sectionView(_ s: ReportDiff.DiffSection, rightName: String) -> some View {
        GroupBox(label: HStack(spacing: 8) {
            Text(s.title)
            Spacer()
            if !s.added.isEmpty {
                Text("+\(s.added.count)")
                    .font(.caption.monospacedDigit().bold()).foregroundStyle(.green)
            }
            if !s.removed.isEmpty {
                Text("−\(s.removed.count)")
                    .font(.caption.monospacedDigit().bold()).foregroundStyle(.red)
            }
            if !s.modified.isEmpty {
                Text("~\(s.modified.count)")
                    .font(.caption.monospacedDigit().bold()).foregroundStyle(.orange)
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                if s.isEmpty {
                    Text("No changes").font(.callout).foregroundStyle(.secondary)
                } else {
                    diffList("Added in \(rightName)", items: s.added, color: .green, symbol: "plus")
                    diffList("Removed in \(rightName)", items: s.removed, color: .red, symbol: "minus")
                    modifiedList("Modified — build token only", changes: s.modified)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func diffList(_ label: String, items: [String], color: Color, symbol: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.caption.bold()).foregroundStyle(color)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: symbol).font(.caption2).foregroundStyle(color)
                        Text(item).font(.callout)
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
            }
        }
    }

    /// Items that changed only by a volatile build token (e.g. a Rust
    /// `/rustc/<hash>/…` path). Shows the normalised form with the token elided
    /// to a placeholder; the full before → after is on hover.
    @ViewBuilder
    private func modifiedList(_ label: String, changes: [ReportDiff.DiffSection.Change]) -> some View {
        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.caption.bold()).foregroundStyle(.orange)
                tokenSummary(changes)
                ForEach(changes) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2).foregroundStyle(.orange)
                        Text(change.display).font(.callout)
                            .lineLimit(2).truncationMode(.middle)
                    }
                    .help("\(change.before)\n→ \(change.after)")
                }
            }
        }
    }

    /// The actual volatile token(s) that changed across this section — usually
    /// one (the rebuilt binary's commit hash). Shown selectable so the real
    /// before/after values stay comparable, not just the elided `<hash>` form.
    @ViewBuilder
    private func tokenSummary(_ changes: [ReportDiff.DiffSection.Change]) -> some View {
        let tokens = Self.distinctTokens(changes)
        ForEach(Array(tokens.enumerated()), id: \.offset) { _, t in
            HStack(spacing: 4) {
                Image(systemName: "number").font(.caption2).foregroundStyle(.secondary)
                Text("\(t.before)  →  \(t.after)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    static func distinctTokens(_ changes: [ReportDiff.DiffSection.Change])
        -> [ReportDiff.DiffSection.Change.TokenChange] {
        var seen = Set<ReportDiff.DiffSection.Change.TokenChange>()
        var out: [ReportDiff.DiffSection.Change.TokenChange] = []
        for c in changes { for t in c.tokens where seen.insert(t).inserted { out.append(t) } }
        return out.sorted { $0.before < $1.before }
    }

    private var emptyState: some View {
        HStack {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            Text("No differences in any tracked section.")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func primeDefaults() {
        // Default to comparing the two newest runs if at least two exist.
        let metas = coordinator.recentRuns
        if leftID == nil, metas.count >= 2 {
            leftID  = metas[1].id   // older
            rightID = metas[0].id   // newer
            recomputeDiff()
        }
    }

    private func recomputeDiff() {
        loadError = nil
        guard let leftID, let rightID else { diff = nil; return }
        do {
            let l = try RunStore.shared.load(id: leftID)
            let r = try RunStore.shared.load(id: rightID)
            diff = ReportDiffer().diff(left: l, right: r)
        } catch {
            diff = nil
            loadError = error.localizedDescription
        }
    }

    private func deltaIcon(_ d: Int) -> String {
        if d > 0 { return "arrow.up" }
        if d < 0 { return "arrow.down" }
        return "equal"
    }
    private func deltaText(_ d: Int) -> String {
        if d > 0 { return "+\(d)" }
        if d < 0 { return "\(d)" }
        return "0"
    }
    private func deltaColor(_ d: Int) -> Color {
        if d > 5  { return .red }
        if d > 0  { return .orange }
        if d < -5 { return .green }
        if d < 0  { return .green.opacity(0.6) }
        return .secondary
    }
}
