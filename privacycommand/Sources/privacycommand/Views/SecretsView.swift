import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// "Hard-coded credentials" section — only renders if findings exist.
/// Always shows the masked form by default; an inline "show" toggle would
/// be tempting but is left out on purpose so the user has to deliberately
/// reveal a secret rather than leak it on a screenshot.
struct SecretsView: View {
    let findings: [SecretFinding]
    /// The main executable the secrets were scanned from, used for the
    /// "reveal in Finder" affordance. Optional so previews/old callers
    /// still compile.
    var executableURL: URL? = nil

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
                                // Where in the app it was found — answers "where
                                // did this PEM/key come from?" without a click.
                                if let loc = locationText(f) {
                                    Label(loc, systemImage: "doc.text.magnifyingglass")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Text(f.masked)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1),
                                            in: RoundedRectangle(cornerRadius: 4))
                                .textSelection(.enabled)
                            if let url = revealableURL {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                                .help("Reveal the binary (\(url.lastPathComponent)) in Finder.")
                            }
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

    /// "Contents/MacOS/AppName @ 0x1f3a0" — file + byte offset when known.
    private func locationText(_ f: SecretFinding) -> String? {
        guard let src = f.sourceFile else { return nil }
        if let off = f.byteOffset { return "\(src) @ 0x\(String(off, radix: 16))" }
        return src
    }

    /// The executable URL, but only if it still exists on disk (the analyzed
    /// app may have moved since the report was generated).
    private var revealableURL: URL? {
        guard let url = executableURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func severity(_ c: SecretFinding.Confidence) -> Color {
        switch c {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .yellow
        }
    }
}
