import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct DropTargetView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @State private var isTargeted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                dropArea
                if !coordinator.recentRuns.isEmpty {
                    recentsSection
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .task { coordinator.refreshRecents() }
    }

    private var dropArea: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a .app bundle or .dmg disk image here")
                .font(.title2)
            Text("ZIP archives aren't supported — extract them first.")
                .font(.caption).foregroundStyle(.secondary)
            Text("or")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Choose…") { coordinator.presentOpenPanel() }
                .keyboardShortcut("o")
            if let err = coordinator.lastError {
                Text(err).foregroundStyle(.red).font(.callout)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(40)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: .init(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
        )
        .onDrop(of: [.fileURL, .application], isTargeted: $isTargeted) { providers in
            Task { await handleDrop(providers) }
            return true
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(.headline)
                Spacer()
                if coordinator.recentRuns.count > 5 {
                    Text("\(coordinator.recentRuns.count) saved · open the History tab to see all")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            RecentRunsList(maxRows: 5)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if let url = await provider.loadFileURL() {
                let resolved = url.resolvingSymlinksInPath()
                let ext = resolved.pathExtension.lowercased()
                if ext == "app" || ext == "dmg" || ext == "sparseimage" || ext == "sparsebundle" {
                    await MainActor.run { coordinator.select(url: resolved) }
                    return
                }
                if ext == "zip" {
                    // Coordinator's `select` would also reject this, but
                    // catching it at the drop site means we don't kick
                    // off any state transition for an unsupported file.
                    await MainActor.run {
                        coordinator.lastError = "ZIP archives aren't supported. Extract the .zip first, then drop the resulting .app bundle here."
                    }
                    return
                }
            }
        }
    }
}

private extension NSItemProvider {
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { cont in
            _ = self.loadObject(ofClass: URL.self) { url, _ in
                cont.resume(returning: url)
            }
        }
    }
}
