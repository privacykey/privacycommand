import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct AntiAnalysisView: View {
    let findings: [AntiAnalysisDetector.Result.Finding]

    var body: some View {
        if !findings.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Text("Anti-analysis signals")
                InfoButton(articleID: "antianalysis-overview")
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(findings) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: icon(f.confidence))
                                    .foregroundStyle(colour(f.confidence))
                                Text(f.kind.rawValue).font(.callout.bold())
                                Text("(\(f.confidence.rawValue) confidence)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if f.kbArticleID != nil {
                                    InfoButton(articleID: f.kbArticleID)
                                }
                                Spacer()
                            }
                            Text(f.summary).font(.callout)
                            if let detail = f.detail {
                                Text(detail).font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func icon(_ c: AntiAnalysisDetector.Result.Finding.Confidence) -> String {
        switch c { case .high: return "exclamationmark.shield.fill"
                   case .medium: return "questionmark.diamond"
                   case .low: return "info.circle" }
    }
    private func colour(_ c: AntiAnalysisDetector.Result.Finding.Confidence) -> Color {
        switch c { case .high: return .orange
                   case .medium: return .yellow
                   case .low: return .secondary }
    }
}
