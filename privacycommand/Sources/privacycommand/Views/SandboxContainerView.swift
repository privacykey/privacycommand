import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// "What does this app keep on my Mac" — browses the sandboxed
/// `~/Library/Containers/<bundle-id>/Data/...` tree and breaks the
/// totals out by category.
struct SandboxContainerView: View {
    let info: SandboxContainerInfo

    var body: some View {
        if info.state == .sandboxed && !info.directories.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Text("Sandbox container")
                InfoButton(articleID: "sandbox-container")
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    summary
                    ForEach(info.directories) { dir in
                        row(dir)
                    }
                    if let container = info.container {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([container])
                        } label: {
                            Label("Reveal container in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if info.state == .notSandboxed, info.container != nil {
            // Bundle ID known, no container — explicitly tell the user
            // "this app isn't sandboxed" rather than silently render nothing.
            GroupBox(label: HStack(spacing: 6) {
                Text("Sandbox container")
                InfoButton(articleID: "sandbox-container")
            }) {
                Text("This app is not sandboxed (no container directory exists).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        // .noBundleID — render nothing, the bundle is mis-formed enough
        // that other sections will already complain.
    }

    private var summary: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(info.formattedTotal).font(.title3.monospacedDigit().bold())
                Text("on disk").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(info.totalFileCount)").font(.title3.monospacedDigit().bold())
                Text("file\(info.totalFileCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func row(_ d: SandboxContainerInfo.Directory) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: d.kind.icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.kind.rawValue).font(.callout.bold())
                Text(d.kind.description)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteCountFormatter.string(fromByteCount: d.totalBytes,
                                               countStyle: .file))
                    .font(.caption.monospacedDigit())
                Text("\(d.fileCount) files")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([d.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
    }
}
