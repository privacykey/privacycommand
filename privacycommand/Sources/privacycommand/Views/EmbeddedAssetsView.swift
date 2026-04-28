import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct EmbeddedAssetsView: View {
    let assets: EmbeddedAssets

    /// Currently-previewed asset. Drives the modal sheet — when nil, no
    /// preview is open. Identifiable so .sheet(item:) can use it directly.
    @State private var previewing: PreviewTarget?

    private struct PreviewTarget: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
    }

    var body: some View {
        if !assets.scripts.isEmpty || !assets.launchPlists.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Text("Embedded scripts & launch agents")
                InfoButton(articleID: "embedded-launch-plist")
            }) {
                VStack(alignment: .leading, spacing: 10) {
                    if !assets.launchPlists.isEmpty {
                        Text("Launch agents / daemons (\(assets.launchPlists.count))")
                            .font(.subheadline.bold())
                        ForEach(assets.launchPlists) { lp in
                            launchPlistRow(lp)
                        }
                    }
                    if !assets.launchPlists.isEmpty && !assets.scripts.isEmpty {
                        Divider()
                    }
                    if !assets.scripts.isEmpty {
                        Text("Scripts (\(assets.scripts.count))")
                            .font(.subheadline.bold())
                        ForEach(assets.scripts) { s in
                            scriptRow(s)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(item: $previewing) { target in
                EmbeddedAssetPreviewSheet(
                    url: target.url, title: target.title,
                    onClose: { previewing = nil })
            }
        }
    }

    private func launchPlistRow(_ lp: EmbeddedAssets.LaunchPlist) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: lp.kind == .daemon ? "shield.lefthalf.filled" : "person.crop.circle")
                .foregroundStyle(lp.kind == .daemon ? .red : .orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(lp.label).font(.callout.bold())
                    Text("·").foregroundStyle(.tertiary)
                    Text(lp.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                    if lp.runAtLoad { tag("RunAtLoad", .blue) }
                    if lp.keepAlive  { tag("KeepAlive", .blue) }
                    Spacer()
                }
                Text(lp.commandSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Text(lp.url.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            rowActions(url: lp.url, title: "Launch plist · \(lp.label)")
        }
    }

    private func scriptRow(_ s: EmbeddedAssets.Script) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "scroll").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.url.lastPathComponent).font(.caption.monospaced())
                Text(s.url.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(s.kind.label)
                .font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 3))
            Text("\(s.sizeBytes) B")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if s.isExecutable { tag("+x", .green) }
            rowActions(url: s.url, title: "Script · \(s.url.lastPathComponent)")
        }
    }

    /// Per-row trio: in-app Preview, Reveal in Finder, Open in default app.
    /// Borderless icon-only buttons keep the row visually clean — tooltips
    /// carry the meaning.
    private func rowActions(url: URL, title: String) -> some View {
        HStack(spacing: 4) {
            Button {
                previewing = .init(url: url, title: title)
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("Preview file contents inline (truncated past 256 KB)")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open with the system default app")
        }
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(c)
    }
}
