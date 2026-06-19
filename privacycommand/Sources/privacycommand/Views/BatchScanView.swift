import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Batch mode: scan many apps at once and triage them in a sortable,
/// filterable table. Lives in its own window. Reuses the same analyzer the
/// single-app flow uses; "Analyze in Main Window" hands a chosen app back to
/// the shared coordinator for the full deep-dive.
struct BatchScanView: View {
    @StateObject private var model = BatchScanModel()
    @EnvironmentObject private var coordinator: AnalysisCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Set<BatchAppResult.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            filterBar
            Divider()
            content
        }
        .frame(minWidth: 1080, minHeight: 560)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    // House convention from the menu: Shift = pick a folder.
                    if NSEvent.modifierFlags.contains(.shift) {
                        model.pickFolderAndScan()
                    } else {
                        model.scanDefault()
                    }
                } label: {
                    Label(model.isScanning ? "Scanning…" : "Scan", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isScanning)
                .help("Scan installed apps in /Applications and ~/Applications. Hold ⇧ to choose a folder instead.")

                Button {
                    model.pickFolderAndScan()
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
                .disabled(model.isScanning)

                if model.isScanning {
                    Button(role: .cancel) { model.cancel() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }

                Toggle("Include system apps", isOn: $model.includeSystemApps)
                    .toggleStyle(.checkbox)
                    .disabled(model.isScanning)
                    .help("Also scan /System/Applications (Apple's own apps — all notarized, usually low signal).")

                Spacer()

                exportMenu
                    .disabled(model.results.isEmpty)
            }

            if model.isScanning {
                HStack(spacing: 8) {
                    ProgressView(value: model.progressFraction)
                        .frame(maxWidth: 260)
                    Text("\(model.completed) / \(model.total)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if !model.currentName.isEmpty {
                        Text("· \(model.currentName)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            } else if !model.results.isEmpty {
                summaryPills
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var summaryPills: some View {
        let t = model.tally
        return HStack(spacing: 8) {
            Text("\(model.results.count) apps").font(.caption.weight(.semibold))
            if t.critical > 0 { tallyPill("Critical", t.critical, .red) }
            if t.high > 0 { tallyPill("High", t.high, .orange) }
            if t.medium > 0 { tallyPill("Medium", t.medium, .yellow) }
            if t.low > 0 { tallyPill("Low", t.low, .green) }
            if t.failed > 0 { tallyPill("Failed", t.failed, .secondary) }
            if model.filter.isActive {
                Text("· \(model.filteredSorted.count) shown")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tallyPill(_ label: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count) \(label)").font(.caption)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.12), in: .capsule)
    }

    private var exportMenu: some View {
        Menu {
            Button("Export CSV…") { model.exportCSV() }
            Button("Export JSON…") { model.exportJSON() }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Export the currently shown rows.")
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                    TextField("Filter by name, bundle ID, or path", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
                Picker("Min risk", selection: $model.minTier) {
                    Text("Any risk").tag(RiskTier?.none)
                    Text("Medium+").tag(RiskTier?.some(.medium))
                    Text("High+").tag(RiskTier?.some(.high))
                    Text("Critical").tag(RiskTier?.some(.critical))
                }
                .pickerStyle(.menu)
                .fixedSize()

                Spacer()

                if model.filter.isActive {
                    Button { model.clearFilters() } label: {
                        Label("Clear filters", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Categorical facets — the "advanced filters" for static signals.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Picker("Architecture", selection: $model.archClass) {
                        Text("Any arch").tag(ArchClass?.none)
                        ForEach(ArchClass.allCases) { a in
                            Text(a.label).tag(ArchClass?.some(a))
                        }
                    }
                    .fixedSize()
                    .help("Filter by CPU architecture. \"Intel only\" apps stop launching when Apple removes Rosetta 2.")

                    Picker("Update", selection: $model.updateFilter) {
                        Text("Any updater").tag(UpdateFilter?.none)
                        Text("No updater").tag(UpdateFilter?.some(.none))
                        ForEach(UpdateMechanism.Kind.allCases, id: \.self) { k in
                            Text(k.label).tag(UpdateFilter?.some(.kind(k)))
                        }
                    }
                    .fixedSize()
                    .help("Filter by in-app update mechanism (Sparkle, Squirrel, electron-updater, …).")

                    Picker("Sandbox", selection: $model.sandboxed) {
                        Text("Any").tag(Bool?.none)
                        Text("Sandboxed").tag(Bool?.some(true))
                        Text("Not sandboxed").tag(Bool?.some(false))
                    }
                    .fixedSize()

                    Picker("Download", selection: $model.hasDownloadMetadata) {
                        Text("Any source").tag(Bool?.none)
                        Text("Has metadata").tag(Bool?.some(true))
                        Text("Missing metadata").tag(Bool?.some(false))
                    }
                    .fixedSize()
                    .help("Whether macOS recorded where the app was downloaded from (quarantine / where-from xattrs).")

                    Picker("Min macOS", selection: $model.minOSBucket) {
                        Text("Any min OS").tag(MinOSBucket?.none)
                        ForEach(MinOSBucket.allCases) { b in
                            Text(b.label).tag(MinOSBucket?.some(b))
                        }
                    }
                    .fixedSize()
                    .help("Filter by the app's minimum required macOS version.")
                }
            }

            // Concern chips — only those that actually occur in this scan, so
            // the bar reflects what's worth filtering on.
            let availableFlags = BatchFlag.allCases.filter { $0.isConcern && model.count(of: $0) > 0 }
            if !availableFlags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(availableFlags) { flag in
                            FlagChip(
                                flag: flag,
                                count: model.count(of: flag),
                                isOn: model.requiredFlags.contains(flag)
                            ) {
                                if model.requiredFlags.contains(flag) {
                                    model.requiredFlags.remove(flag)
                                } else {
                                    model.requiredFlags.insert(flag)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idleState
        case .scanning where model.results.isEmpty:
            ProgressView("Enumerating and analysing apps…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if model.results.isEmpty {
                emptyResults
            } else {
                table
            }
        }
    }

    private var table: some View {
        Table(model.filteredSorted, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("App", value: \.displayName) { row in
                HStack(spacing: 8) {
                    AppIconThumbnail(url: row.url)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.displayName).lineLimit(1)
                        if let bid = row.bundleID {
                            Text(bid).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .help(row.url.path)
            }
            .width(min: 220, ideal: 280)

            TableColumn("Risk", value: \.risk.score) { row in
                if row.flags.contains(.analysisFailed) {
                    Label("Failed", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(row.analysisError ?? "Analysis failed")
                } else {
                    RiskTierBadge(score: row.risk)
                }
            }
            .width(min: 110, ideal: 130, max: 150)

            TableColumn("Signing", value: \.signing.rank) { row in
                Text(row.signing.label)
                    .font(.caption)
                    .foregroundStyle(row.signing.isConcerning ? Color.red : .primary)
            }
            .width(min: 120, ideal: 150, max: 190)

            TableColumn("Arch", value: \.archClass.label) { row in
                Text(row.archClass.label)
                    .font(.caption)
                    .foregroundStyle(row.archClass == .intel ? Color.orange : .primary)
                    .help(row.architectures.isEmpty ? "Unknown" : row.architectures.joined(separator: ", "))
            }
            .width(min: 80, ideal: 96, max: 120)

            TableColumn("Min macOS", value: \.minOSSortKey) { row in
                Text(row.minimumOS ?? "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(row.minimumOS == nil ? .secondary : .primary)
            }
            .width(min: 70, ideal: 84, max: 100)

            TableColumn("Update", value: \.updateLabel) { row in
                Text(row.updateLabel)
                    .font(.caption)
                    .foregroundStyle(row.updateKind == nil ? .secondary : .primary)
            }
            .width(min: 90, ideal: 120, max: 150)

            TableColumn("Source") { row in
                Text(row.downloadSource ?? "—")
                    .font(.caption)
                    .foregroundStyle(row.downloadSource == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(row.downloadSource ?? "No download metadata")
            }
            .width(min: 90, ideal: 120, max: 160)

            TableColumn("Trackers", value: \.trackerCount) { row in
                if row.trackerCount > 0 {
                    Text("\(row.trackerCount)")
                        .foregroundStyle(.red)
                        .help(row.trackerNames.joined(separator: ", "))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 72, max: 90)

            TableColumn("Issues", value: \.concernCount) { row in
                Text(row.concernCount == 0 ? "—" : "\(row.concernCount)")
                    .foregroundStyle(row.concernCount == 0 ? .secondary : .primary)
            }
            .width(min: 55, ideal: 65, max: 80)

            TableColumn("Flags") { row in
                FlagBadges(flags: row.concernFlags)
            }
            .width(min: 160, ideal: 320)
        }
        .contextMenu(forSelectionType: BatchAppResult.ID.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            if let row = firstRow(in: ids) { analyzeInMainWindow(row) }
        }
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<BatchAppResult.ID>) -> some View {
        if let row = firstRow(in: ids) {
            Button("Analyze in Main Window") { analyzeInMainWindow(row) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([row.url])
            }
            if let bid = row.bundleID {
                Button("Copy Bundle ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bid, forType: .string)
                }
            }
        }
    }

    private func firstRow(in ids: Set<BatchAppResult.ID>) -> BatchAppResult? {
        guard let id = ids.first else { return nil }
        return model.filteredSorted.first { $0.id == id }
    }

    private func analyzeInMainWindow(_ row: BatchAppResult) {
        coordinator.select(url: row.url)
        NSApp.activate(ignoringOtherApps: true)
        // Reuse the existing main window if it's open (a WindowGroup opens a
        // *new* window on every openWindow(id:) call, so guard against
        // spawning duplicates); only request a fresh one if none exists.
        if let main = NSApp.windows.first(where: {
            ($0.identifier?.rawValue.hasPrefix("main") ?? false) && $0.canBecomeMain
        }) {
            main.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    // MARK: - States

    private var idleState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Scan your apps for privacy & safety signals")
                .font(.title3.bold())
            Text("Click **Scan** to analyse everything in /Applications and ~/Applications, then sort by risk and filter for unsigned apps, tracking SDKs, missing sandboxing, embedded launch items, and more.\n\nHold ⇧ while clicking Scan — or use **Choose Folder…** — to scan a specific folder.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button { model.scanDefault() } label: {
                Label("Scan Installed Apps", systemImage: "magnifyingglass")
            }
            .controlSize(.large).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
            Text(model.phase == .cancelled ? "Scan cancelled" : "No apps found")
                .font(.headline)
            Text(model.scopeLabel.isEmpty
                 ? "Nothing to analyse in the chosen location."
                 : "No .app bundles found under: \(model.scopeLabel)")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Chips & badges

/// A toggle chip for one concern flag in the filter bar.
private struct FlagChip: View {
    let flag: BatchFlag
    let count: Int
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: flag.systemImage).imageScale(.small)
                Text(flag.shortLabel).font(.caption)
                Text("\(count)").font(.caption2.monospacedDigit())
                    .foregroundStyle(isOn ? Color.white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isOn ? Color.accentColor : Color.secondary.opacity(0.12), in: .capsule)
            .foregroundStyle(isOn ? Color.white : .primary)
        }
        .buttonStyle(.plain)
        .help(flag.explanation)
    }
}

/// Inline concern badges shown in the Flags table column.
private struct FlagBadges: View {
    let flags: [BatchFlag]
    var body: some View {
        if flags.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                ForEach(flags.prefix(5)) { flag in
                    Image(systemName: flag.systemImage)
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                        .help(flag.shortLabel + " — " + flag.explanation)
                }
                if flags.count > 5 {
                    Text("+\(flags.count - 5)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Small file-system app icon for the App column.
private struct AppIconThumbnail: View {
    let url: URL
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: 18, height: 18)
    }
}
