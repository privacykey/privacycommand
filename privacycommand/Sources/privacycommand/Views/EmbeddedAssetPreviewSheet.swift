import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Modal sheet that previews the contents of an embedded script or
/// launchd plist. We read the file in-process up to a hard cap (256 KB)
/// so very large files don't blow up memory; the cap is shown to the user
/// when it's hit so they know to open the file externally.
struct EmbeddedAssetPreviewSheet: View {
    let url: URL
    let title: String
    let onClose: () -> Void

    @State private var contents: String = ""
    @State private var truncated: Bool = false
    @State private var loadError: String?
    @State private var loaded: Bool = false

    /// Cap for the in-process read. 256 KB easily covers any real shell
    /// script / launchd plist; anything bigger is almost always a binary
    /// the user wants to inspect outside the auditor.
    private static let maxBytes: Int = 256 * 1024

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
        .frame(idealWidth: 880, idealHeight: 600)
        .task {
            guard !loaded else { return }
            load()
            loaded = true
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.title3.bold())
                Text(url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Close") { onClose() }
                .keyboardShortcut(.escape)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            VStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                Text("Couldn't read file").font(.headline)
                Text(err).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(contents.isEmpty ? "(empty file)" : contents)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if truncated {
                Label("File truncated to \(Self.maxBytes / 1024) KB",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open in default app", systemImage: "arrow.up.forward.app")
            }
        }
        .padding(12)
    }

    // MARK: - Loading

    private func load() {
        do {
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            let raw = try fh.read(upToCount: Self.maxBytes) ?? Data()
            // Detect truncation: if we got exactly maxBytes, ask the FS
            // for the actual size to confirm there's more.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let actualSize = (attrs?[.size] as? Int) ?? raw.count
            truncated = actualSize > raw.count

            // Try UTF-8 first; fall back to ASCII; if it's a binary plist,
            // serialize back to XML for readability.
            if let s = String(data: raw, encoding: .utf8) {
                contents = s
            } else if url.pathExtension.lowercased() == "plist",
                      let plist = try? PropertyListSerialization
                        .propertyList(from: raw, options: [], format: nil),
                      let xml = try? PropertyListSerialization
                        .data(fromPropertyList: plist, format: .xml, options: 0),
                      let s = String(data: xml, encoding: .utf8) {
                contents = s
            } else if let s = String(data: raw, encoding: .ascii) {
                contents = s
            } else {
                loadError = "File isn't text and isn't a recognised plist binary."
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}
