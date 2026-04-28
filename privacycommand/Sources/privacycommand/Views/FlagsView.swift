import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Static-tab section that surfaces feature flags, trial / licensing
/// state, A/B experiments, and debug toggles found in the binary's
/// strings. Quiet when there's nothing to show; grouped by category
/// when there is.
struct FlagsView: View {
    let findings: [FlagFinding]

    var body: some View {
        if !findings.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Text("Feature flags & trials")
                InfoButton(articleID: "flags-overview")
            }) {
                VStack(alignment: .leading, spacing: 10) {
                    summary
                    ForEach(grouped, id: \.category) { group in
                        sectionView(group)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Summary line

    private var summary: some View {
        let trial   = findings.filter { $0.category == .trialAndLicensing }.count
        let flags   = findings.filter { $0.category == .featureFlags }.count
        let exps    = findings.filter { $0.category == .experiments }.count
        let debugs  = findings.filter { $0.category == .debugging }.count

        return HStack(spacing: 16) {
            counter(value: trial, label: "trial / licensing", colour: trial > 0 ? .orange : .secondary)
            counter(value: flags, label: "feature flag\(flags == 1 ? "" : "s")", colour: flags > 0 ? .blue : .secondary)
            counter(value: exps, label: "experiment\(exps == 1 ? "" : "s")", colour: exps > 0 ? .blue : .secondary)
            counter(value: debugs, label: "debug toggle\(debugs == 1 ? "" : "s")", colour: debugs > 0 ? .yellow : .secondary)
            Spacer()
        }
    }

    private func counter(value: Int, label: String, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.title3.monospacedDigit().bold()).foregroundStyle(colour)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Grouping

    private struct Group: Identifiable {
        let category: FlagFinding.Category
        let findings: [FlagFinding]
        var id: FlagFinding.Category { category }
    }

    private var grouped: [Group] {
        let buckets = Dictionary(grouping: findings, by: \.category)
        return FlagFinding.Category.allCases.compactMap { cat in
            guard let f = buckets[cat], !f.isEmpty else { return nil }
            return Group(category: cat, findings: f)
        }
    }

    private func sectionView(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: group.category))
                    .foregroundStyle(.secondary)
                Text(group.category.rawValue).font(.subheadline.bold())
                Text("(\(group.findings.count))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(group.findings) { f in
                row(f)
            }
        }
        .padding(.vertical, 2)
    }

    private func row(_ f: FlagFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: f.kind.icon).foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.kind.rawValue).font(.callout)
                Text(f.rawMatch)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if f.kbArticleID != nil {
                InfoButton(articleID: f.kbArticleID)
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 1)
    }

    private func icon(for cat: FlagFinding.Category) -> String {
        switch cat {
        case .trialAndLicensing: return "ticket.fill"
        case .featureFlags:      return "switch.2"
        case .experiments:       return "flask.fill"
        case .debugging:         return "ant.fill"
        }
    }
}
