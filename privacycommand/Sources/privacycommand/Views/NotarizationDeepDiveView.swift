import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Renders the stapler / spctl deep-dive details and exposes the
/// executable's SHA-256 plus reputation links.
struct NotarizationDeepDiveView: View {
    let report: NotarizationDeepDiveReport

    var body: some View {
        GroupBox(label: HStack(spacing: 6) {
            Text("Notarization deep dive")
            InfoButton(articleID: "notarization-deep-dive")
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    verdictPill(label: "Stapled ticket",
                                verdict: report.staplerOutput.verdict)
                    verdictPill(label: "Gatekeeper assessment",
                                verdict: report.spctlOutput.verdict)
                }

                if let sha = report.executableSHA256 {
                    Divider()
                    hashRow(sha)
                }

                Divider()
                DisclosureGroup("xcrun stapler validate output") {
                    rawText(report.staplerOutput.rawText)
                }
                DisclosureGroup("spctl --assess -vvv output") {
                    rawText(report.spctlOutput.rawText)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func verdictPill(label: String,
                             verdict: NotarizationDeepDiveReport.Verdict) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: icon(verdict)).foregroundStyle(colour(verdict))
                Text(verdict.rawValue).font(.callout.bold())
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func hashRow(_ sha: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Executable SHA-256").font(.caption.bold())
                Spacer()
            }
            HStack(spacing: 6) {
                Text(sha)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sha, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy SHA-256 to clipboard")
            }
            HStack(spacing: 12) {
                if let vt = report.virusTotalURL {
                    Link(destination: vt) {
                        Label("Look up on VirusTotal", systemImage: "shield.checkered")
                            .font(.caption)
                    }
                }
                Link(destination: URL(string: "https://valid.apple.com/")!) {
                    Label("Apple Notary Service",
                          systemImage: "arrow.up.forward.square")
                        .font(.caption)
                }
            }
        }
    }

    private func rawText(_ s: String) -> some View {
        ScrollView {
            Text(s).font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(maxHeight: 200)
        .background(Color.secondary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private func icon(_ v: NotarizationDeepDiveReport.Verdict) -> String {
        switch v {
        case .ok:       return "checkmark.seal.fill"
        case .noTicket: return "questionmark.circle"
        case .failed:   return "xmark.octagon.fill"
        case .unknown:  return "circle.dotted"
        }
    }
    private func colour(_ v: NotarizationDeepDiveReport.Verdict) -> Color {
        switch v {
        case .ok:       return .green
        case .noTicket: return .orange
        case .failed:   return .red
        case .unknown:  return .secondary
        }
    }
}
