import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// "Hard-coded credentials" section — only renders if findings exist.
/// Always shows the masked form by default; an inline "show" toggle would
/// be tempting but is left out on purpose so the user has to deliberately
/// reveal a secret rather than leak it on a screenshot.
struct SecretsView: View {
    let findings: [SecretFinding]

    var body: some View {
        if !findings.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Image(systemName: "key.fill").foregroundStyle(.red)
                Text("Hard-coded credentials")
                InfoButton(articleID: "secret-findings")
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(findings.count) secret\(findings.count == 1 ? "" : "s") detected. Each match is masked below for safe display.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)

                    ForEach(findings) { f in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundStyle(severity(f.confidence))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.kind.rawValue).font(.callout.bold())
                                Text("\(f.vendor) · \(f.rawLength) chars")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(f.masked)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: 4))
                                .textSelection(.enabled)
                            if f.kbArticleID != nil {
                                InfoButton(articleID: f.kbArticleID)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func severity(_ c: SecretFinding.Confidence) -> Color {
        switch c {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .yellow
        }
    }
}
