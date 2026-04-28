import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Per-Mach-O code-signing audit. Shows a verdict header plus a table of
/// every Mach-O in the bundle with its team ID, hardened-runtime, and
/// ad-hoc state.
struct BundleSigningAuditView: View {
    let audit: BundleSigningAudit

    var body: some View {
        if !audit.entries.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Text("Whole-bundle code-signing audit")
                InfoButton(articleID: "bundle-signing-audit")
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    verdictsSection
                    Divider()
                    tableHeader
                    ForEach(audit.entries) { row in
                        rowView(row)
                    }
                }
                .padding(8)
            }
        }
    }

    private var verdictsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                stat("\(audit.entries.count)", "Mach-Os audited")
                stat("\(audit.uniqueTeamIDs.count)", "distinct Team ID\(audit.uniqueTeamIDs.count == 1 ? "" : "s")")
                if let main = audit.mainTeamID {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(main).font(.caption.monospaced())
                        Text("main app Team ID").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            ForEach(audit.verdicts) { v in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon(v.severity))
                        .foregroundStyle(colour(v.severity))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.summary).font(.callout)
                        if let detail = v.detail {
                            Text(detail).font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.monospacedDigit().bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tableHeader: some View {
        HStack {
            Text("Component").font(.caption.bold()).frame(maxWidth: .infinity, alignment: .leading)
            Text("Role").font(.caption.bold()).frame(width: 100, alignment: .leading)
            Text("Team ID").font(.caption.bold()).frame(width: 90, alignment: .leading)
            Text("Flags").font(.caption.bold()).frame(width: 200, alignment: .leading)
        }
        .foregroundStyle(.secondary)
    }

    private func rowView(_ row: BundleSigningAudit.Entry) -> some View {
        let isMismatched = row.teamID != nil
            && row.teamID != audit.mainTeamID
            && !row.isPlatformBinary && !row.isAdhocSigned
        return HStack(alignment: .firstTextBaseline) {
            Text(row.url.lastPathComponent)
                .font(.caption.monospaced())
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isMismatched ? .red : .primary)
            Text(row.role.rawValue).font(.caption).frame(width: 100, alignment: .leading)
            Text(row.teamID ?? "—").font(.caption.monospaced())
                .foregroundStyle(isMismatched ? .red : .primary)
                .frame(width: 90, alignment: .leading)
            HStack(spacing: 4) {
                if row.hardenedRuntime { tag("Hardened", .green) }
                if row.isAdhocSigned    { tag("Ad-hoc", .orange) }
                if row.isPlatformBinary { tag("Apple", .blue) }
                if !row.validates       { tag("invalid", .red) }
            }
            .frame(width: 200, alignment: .leading)
        }
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(c)
    }

    private func icon(_ s: BundleSigningAudit.Verdict.Severity) -> String {
        switch s { case .info: return "checkmark.circle"
                   case .warn: return "exclamationmark.triangle"
                   case .error: return "exclamationmark.octagon.fill" }
    }
    private func colour(_ s: BundleSigningAudit.Verdict.Severity) -> Color {
        switch s { case .info: return .secondary
                   case .warn: return .orange
                   case .error: return .red }
    }
}
