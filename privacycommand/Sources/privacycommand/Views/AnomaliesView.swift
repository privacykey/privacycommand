import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Surfaces dynamic-run anomalies (periodic beacons, bursts, undeclared
/// destinations) as a dashboard card. Renders nothing if the run had no
/// anomalies — keeps the dashboard quiet when there's nothing to say.
struct AnomaliesView: View {
    let report: BehaviorReport

    var body: some View {
        if !report.anomalies.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Text("Behavioural anomalies")
                InfoButton(articleID: "behavior-overview")
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.anomalies) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: icon(a.kind))
                                    .foregroundStyle(colour(a.severity))
                                Text(a.title).font(.callout.bold())
                                Spacer()
                                Text(a.kind.rawValue)
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(colour(a.severity).opacity(0.15),
                                                in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(colour(a.severity))
                                if a.kbArticleID != nil {
                                    InfoButton(articleID: a.kbArticleID)
                                }
                            }
                            Text(a.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !a.evidence.isEmpty {
                                HStack(spacing: 4) {
                                    ForEach(a.evidence.prefix(6), id: \.self) { ev in
                                        Text(ev).font(.caption2.monospaced())
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color.secondary.opacity(0.1),
                                                        in: RoundedRectangle(cornerRadius: 3))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func icon(_ k: BehaviorReport.Anomaly.Kind) -> String {
        switch k {
        case .periodicBeacon: return "waveform.path"
        case .burst:          return "bolt.fill"
        case .undeclaredHost: return "globe.badge.chevron.backward"
        }
    }
    private func colour(_ s: BehaviorReport.Anomaly.Severity) -> Color {
        switch s {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .secondary
        }
    }
}
