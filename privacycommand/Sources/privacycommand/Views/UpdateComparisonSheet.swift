import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Multi-step sheet that walks Check → Available → Download → Compare.
/// Discards everything when dismissed.
struct UpdateComparisonSheet: View {
    @StateObject var fetcher: UpdateFetcher

    let currentReport: StaticReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 600)
        .task {
            // Auto-check the appcast when the sheet appears.
            await fetcher.checkForUpdate()
        }
        .onDisappear {
            // Belt-and-suspenders cleanup; deinit also handles this.
            fetcher.discard()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Preview next version").font(.title2.bold())
                Text(fetcher.feedURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Discard & close") {
                fetcher.discard()
                onClose()
            }
            .keyboardShortcut(.escape)
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch fetcher.phase {
        case .idle, .checking:
            statusCard(systemImage: "arrow.down.app",
                       title: "Checking for updates…",
                       subtitle: "Fetching the appcast from the developer's feed.",
                       showProgress: true)

        case .awaitingDownload(let item):
            availableView(item)

        case .downloading(let progress, let received, let total):
            downloadingView(progress: progress, received: received, total: total)

        case .extracting:
            statusCard(systemImage: "shippingbox",
                       title: "Extracting…",
                       subtitle: "Mounting the DMG / unzipping into a temp folder.",
                       showProgress: true)

        case .analyzing:
            statusCard(systemImage: "doc.text.magnifyingglass",
                       title: "Running static analysis…",
                       subtitle: "Same code path the auditor uses for the current bundle.",
                       showProgress: true)

        case .ready(let newReport):
            comparisonView(newReport: newReport)

        case .error(let message):
            errorView(message)
        }
    }

    // MARK: - Sub-views

    private func availableView(_ item: AppcastItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "tag").foregroundStyle(.blue).font(.title3)
                    Text("v\(item.shortVersionString ?? item.buildVersion ?? "?")")
                        .font(.title.bold())
                    if let pub = item.pubDate {
                        Text("· released \(pub.formatted(date: .abbreviated, time: .omitted))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let length = item.length {
                        Text("\(length / 1024 / 1024) MB")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if let title = item.title {
                    Text(title).font(.callout)
                }
                if let url = item.downloadURL {
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
            .padding(14)
            .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8))

            if let notes = item.releaseNotesHTML {
                disclosureBlock("Release notes (sanitized)") {
                    ScrollView {
                        Text(strippingHTML(notes))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 160)
                }
            }

            disclosureBlock("What this does") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Downloads the .dmg or .zip via HTTPS into a temp folder.")
                    bullet("Mounts the DMG with `hdiutil -nobrowse -readonly -noautoopen` (no Finder mount, no auto-run) or unzips with `ditto`.")
                    bullet("Runs the same static analyzer on the new .app and shows the diff.")
                    bullet("Discards the download — the app is **never installed or launched**.")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                Button("Download & analyze") {
                    Task { await fetcher.downloadAndAnalyze(item) }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(item.downloadURL == nil)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func downloadingView(progress: Double,
                                 received: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle").foregroundStyle(.blue).font(.title2)
                Text("Downloading…").font(.title3.bold())
                Spacer()
                Text(byteString(received: received, total: total))
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            ProgressView(value: progress.isFinite ? progress : 0)
                .progressViewStyle(.linear)
            Text("Progress: \(Int(max(0, min(1, progress)) * 100))%")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func comparisonView(newReport: StaticReport) -> some View {
        // Wrap both static reports in minimal RunReports so we can reuse
        // ReportDiffer (which already handles missing dynamic data).
        let leftRun = wrap(currentReport, label: "Current bundle")
        let rightRun = wrap(newReport, label: "Downloaded preview")
        let diff = ReportDiffer().diff(left: leftRun, right: rightRun)

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headlineCard(diff)
                Text("Static-only comparison — the new version was downloaded but never launched.")
                    .font(.caption).foregroundStyle(.secondary)

                if diff.changedSections.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("No tracked differences between the current and new versions.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 30)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(diff.changedSections) { section in
                        sectionView(section)
                    }
                }
            }
            .padding(20)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 40))
            Text("Couldn't preview the next version").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
            HStack {
                Button("Retry") { Task { await fetcher.checkForUpdate() } }
                Button("Close") { onClose() }
                    .keyboardShortcut(.escape)
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bits

    private func statusCard(systemImage: String, title: String,
                            subtitle: String, showProgress: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.secondary).font(.system(size: 40))
            Text(title).font(.title3.bold())
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            if showProgress { ProgressView().progressViewStyle(.circular) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func disclosureBlock<Content: View>(_ title: String,
                                                @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(title) { content() }
            .padding(.horizontal, 4)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary).font(.caption)
            Text(text).font(.callout)
        }
    }

    private func byteString(received: Int64, total: Int64) -> String {
        let mb: (Int64) -> String = { String(format: "%.1f MB", Double($0) / 1024 / 1024) }
        return total > 0 ? "\(mb(received)) / \(mb(total))" : mb(received)
    }

    private func headlineCard(_ diff: ReportDiff) -> some View {
        GroupBox {
            HStack(spacing: 16) {
                sideSummary("Current", side: diff.left)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                sideSummary("Preview", side: diff.right)
                Spacer()
                deltaCard(diff)
            }
            .padding(8)
        }
    }

    private func sideSummary(_ label: String,
                             side: ReportDiff.ReportSide) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let v = side.version {
                    Text("v\(v)").font(.headline)
                } else {
                    Text("(no version)").font(.headline).foregroundStyle(.secondary)
                }
                RiskTierBadge(score: side.riskScore)
            }
        }
    }

    private func deltaCard(_ diff: ReportDiff) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Risk Δ").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: deltaIcon(diff.riskScoreDelta))
                Text(deltaText(diff.riskScoreDelta))
                    .font(.title3.bold().monospacedDigit())
            }
            .foregroundStyle(deltaColor(diff.riskScoreDelta))
        }
    }

    private func sectionView(_ s: ReportDiff.DiffSection) -> some View {
        GroupBox(label: HStack {
            Text(s.title)
            Text("\(s.totalChanges) change\(s.totalChanges == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                if !s.added.isEmpty {
                    diffList("Added", items: s.added, color: .green, symbol: "plus")
                }
                if !s.removed.isEmpty {
                    diffList("Removed", items: s.removed, color: .red, symbol: "minus")
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func diffList(_ label: String, items: [String],
                          color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.bold()).foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: symbol).font(.caption2).foregroundStyle(color)
                    Text(item).font(.callout)
                        .lineLimit(2).truncationMode(.middle)
                }
            }
        }
    }

    private func wrap(_ report: StaticReport, label: String) -> RunReport {
        RunReport(
            auditorVersion: "0.1.0",
            startedAt: Date(),
            endedAt: Date(),
            bundle: report.bundle,
            staticReport: report,
            events: [],
            summary: RunSummary(
                processCount: 0, fileEventCount: 0, networkEventCount: 0,
                topRemoteHosts: [], topPathCategories: [],
                surprisingEventCount: 0,
                riskScore: RiskScorer().score(staticReport: report)
            ),
            fidelityNotes: ["Static-only — \(label)"]
        )
    }

    // Tiny HTML stripper for release notes shown in the popover. We don't
    // render HTML to avoid running anyone's JS in a webview.
    private func strippingHTML(_ html: String) -> String {
        var s = html
        // Swap common entities first.
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
                       ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        // Strip tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deltaIcon(_ d: Int) -> String {
        if d > 0 { return "arrow.up" }
        if d < 0 { return "arrow.down" }
        return "equal"
    }
    private func deltaText(_ d: Int) -> String {
        if d > 0 { return "+\(d)" }
        if d < 0 { return "\(d)" }
        return "0"
    }
    private func deltaColor(_ d: Int) -> Color {
        if d > 5  { return .red }
        if d > 0  { return .orange }
        if d < -5 { return .green }
        if d < 0  { return .green.opacity(0.6) }
        return .secondary
    }
}
