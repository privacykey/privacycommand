import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Modal sheet shown while a static-analysis pass is running. Driven by
/// `AnalysisCoordinator.isAnalyzing`. Non-dismissable (no Cancel button)
/// because the underlying analyzer doesn't currently support cooperative
/// cancellation — the work usually finishes in well under 5 s. If the
/// analyzer ever gets cancellation hooks, drop a Cancel button into
/// the footer.
struct AnalyzingSheet: View {
    let bundleURL: URL?

    var body: some View {
        VStack(spacing: 16) {
            if let bundleURL, let icon = appIcon(for: bundleURL) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
            } else {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
            }

            VStack(spacing: 4) {
                Text("Analyzing \(bundleName) …")
                    .font(.headline)
                Text(bundlePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 360)
            }

            ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 280)

            Text("Reading Info.plist, entitlements, frameworks, signing posture, hard-coded URLs, embedded assets, privacy manifest, and SDK fingerprints. This usually takes a couple of seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .padding(28)
        .frame(width: 440)
    }

    // MARK: - Helpers

    private var bundleName: String {
        bundleURL?.deletingPathExtension().lastPathComponent ?? "the bundle"
    }

    private var bundlePath: String {
        bundleURL?.path ?? ""
    }

    private func appIcon(for url: URL) -> NSImage? {
        let img = NSWorkspace.shared.icon(forFile: url.path)
        return img
    }
}
