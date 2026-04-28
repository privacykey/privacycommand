import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Detects external bundle-inspection tools — Apparency and Suspicious
/// Package, both by Mothers Ruin Software — and offers buttons that open
/// the inspected bundle in them via `NSWorkspace.open`.
///
/// Different from `DisassemblerLauncher` (which opens the *executable*
/// in disassemblers / hex editors); these tools take the *whole bundle*
/// URL and present a high-level inspection UI.
struct BundleInspectorLauncher: View {
    let bundleURL: URL

    @State private var detected: [Inspector] = []

    struct Inspector: Identifiable, Hashable {
        let id: String
        let displayName: String
        let appURL: URL
        let blurb: String
    }

    var body: some View {
        // Render only when at least one inspector exists — no point
        // showing an empty card.
        if !detected.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Text("External bundle inspectors")
                InfoButton(articleID: "external-inspectors")
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected bundle-inspection apps installed on this Mac. Auditor never modifies the bundle when handing it off.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        ForEach(detected) { tool in
                            Button {
                                open(tool: tool)
                            } label: {
                                Label("Open in \(tool.displayName)",
                                      systemImage: icon(for: tool))
                            }
                            .help(tool.blurb)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task { detected = Self.detectInstalled() }
        } else {
            Color.clear.frame(height: 0)
                .task { detected = Self.detectInstalled() }
        }
    }

    private func icon(for tool: Inspector) -> String {
        switch tool.id {
        case "apparency":          return "doc.text.viewfinder"
        case "suspicious-package": return "shippingbox.and.arrow.backward"
        default:                   return "app"
        }
    }

    private func open(tool: Inspector) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([bundleURL],
                                withApplicationAt: tool.appURL,
                                configuration: cfg) { _, _ in }
    }

    // MARK: - Detection

    static func detectInstalled() -> [Inspector] {
        let fm = FileManager.default
        let appRoots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications/Setapp")
        ]

        struct Candidate {
            let id: String
            let displayName: String
            let appNamePrefix: String
            let blurb: String
        }
        let candidates: [Candidate] = [
            .init(id: "apparency",
                  displayName: "Apparency",
                  appNamePrefix: "Apparency",
                  blurb: "Mothers Ruin's bundle-inspection app: signing, entitlements, embedded helpers, version history, sandbox profile."),
            .init(id: "suspicious-package",
                  displayName: "Suspicious Package",
                  appNamePrefix: "Suspicious Package",
                  blurb: "Mothers Ruin's installer-package inspector. Most useful when the dropped bundle is actually a .pkg or contains one.")
        ]

        var found: [Inspector] = []
        for candidate in candidates {
            for root in appRoots {
                guard let entries = try? fm.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]) else { continue }
                if let match = entries.first(where: { url in
                    url.pathExtension == "app"
                        && url.deletingPathExtension().lastPathComponent
                            .hasPrefix(candidate.appNamePrefix)
                }) {
                    found.append(Inspector(
                        id: candidate.id,
                        displayName: candidate.displayName,
                        appURL: match,
                        blurb: candidate.blurb))
                    break
                }
            }
        }
        return found
    }
}
