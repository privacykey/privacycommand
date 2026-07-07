import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// The "requested vs granted vs used" permission matrix — the visible half of
/// Feature B. The data is machine/run state (TCC + the monitored run), computed
/// at view time by `StaticAnalysisView` and passed in; it is never persisted
/// into the content-keyed `StaticReport`.
struct PermissionMatrixView: View {
    let reconciliation: PermissionReconciliation?
    let loading: Bool

    @State private var importedMacAptGrants: [TCCGrant]?
    @State private var showingMacAptSheet = false
    @State private var macAptError: String?

    var body: some View {
        GroupBox(label: HStack {
            Text("Permissions: requested vs granted vs used")
            InfoButton(articleID: "permission-matrix")
            FidelityBadge(.staticAnalysis)
        }) {
            VStack(alignment: .leading, spacing: 10) {
                if let recon = reconciliation {
                    content(recon)
                } else if loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading permission grants…").foregroundStyle(.secondary)
                    }
                } else {
                    Text("Permission data unavailable.").foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 2)
                macAptImportRow
            }
            .padding(8)
        }
        .sheet(isPresented: $showingMacAptSheet) { macAptSheet }
        .alert("Couldn't import mac_apt export",
               isPresented: Binding(get: { macAptError != nil },
                                    set: { if !$0 { macAptError = nil } })) {
            Button("OK", role: .cancel) { macAptError = nil }
        } message: {
            Text(macAptError ?? "")
        }
    }

    // MARK: - mac_apt forensic import (offline corroboration)

    private var macAptImportRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.badge.gearshape").foregroundStyle(.secondary).font(.caption)
            Text("Have a mac_apt export? Import its TCC table to corroborate these grants from an offline capture.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Import mac_apt export…") { importMacAptExport() }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var macAptSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("mac_apt TCC export — \(importedMacAptGrants?.count ?? 0) grants").font(.headline)
                Spacer()
                Button("Close") { showingMacAptSheet = false }
            }
            .padding(12)
            Divider()
            if let grants = importedMacAptGrants, !grants.isEmpty {
                Table(grants) {
                    TableColumn("Service") { Text($0.serviceLabel) }
                    TableColumn("Client") { Text($0.client).font(.caption.monospaced()) }
                    TableColumn("Decision") { Text($0.decision.rawValue) }
                    TableColumn("Type") { Text($0.clientType == .bundleID ? "bundle ID" : "path") }
                }
            } else {
                VStack { Spacer(); Text("No TCC grants in that export.").foregroundStyle(.secondary); Spacer() }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    private func importMacAptExport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a mac_apt SQLite export"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importedMacAptGrants = try MacAptImporter.importTCC(from: url)
            showingMacAptSheet = true
        } catch {
            macAptError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @ViewBuilder
    private func content(_ recon: PermissionReconciliation) -> some View {
        if !recon.tccReadable {
            fdaCard
        }
        if recon.rows.isEmpty && recon.systemAccessGrants.isEmpty {
            Text("This app declares no privacy-sensitive categories, and macOS has no grants on record for it.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if !recon.rows.isEmpty {
            matrix(recon)
            Text("“Used” is observed only for camera, microphone, and screen recording during a monitored run; other rows show “—”.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !recon.systemAccessGrants.isEmpty {
            Divider().padding(.vertical, 2)
            systemAccess(recon.systemAccessGrants)
        }
    }

    // MARK: - Matrix

    private func matrix(_ recon: PermissionReconciliation) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            GridRow {
                Text("Category").font(.caption.bold()).foregroundStyle(.secondary)
                Text("Requested").font(.caption.bold()).foregroundStyle(.secondary)
                Text("Granted").font(.caption.bold()).foregroundStyle(.secondary)
                Text("Used").font(.caption.bold()).foregroundStyle(.secondary)
                Text("Verdict").font(.caption.bold()).foregroundStyle(.secondary)
            }
            Divider().gridCellColumns(5)
            ForEach(recon.rows) { row in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(color(for: row.verdict.severity)).frame(width: 7, height: 7)
                        Text(row.category.displayName)
                    }
                    .help(row.requestedEvidence.joined(separator: "\n"))

                    requestedCell(row)
                    grantedCell(row, tccReadable: recon.tccReadable)
                    usedCell(row)
                    Text(row.verdict.headline)
                        .font(.caption)
                        .foregroundStyle(color(for: row.verdict.severity))
                }
            }
        }
    }

    @ViewBuilder
    private func requestedCell(_ row: PermissionReconciliation.Row) -> some View {
        if row.requested {
            Label("Yes", systemImage: "checkmark").labelStyle(.titleOnly)
                .foregroundStyle(.primary)
        } else if row.presentInBinary {
            Text("in binary").foregroundStyle(.secondary).italic()
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func grantedCell(_ row: PermissionReconciliation.Row, tccReadable: Bool) -> some View {
        if !tccReadable {
            Text("unknown").foregroundStyle(.secondary)
        } else if let decision = row.grant {
            Text(decisionLabel(decision)).foregroundStyle(decisionColor(decision))
        } else {
            Text("no record").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func usedCell(_ row: PermissionReconciliation.Row) -> some View {
        switch row.used {
        case .observed:      Text("used").foregroundStyle(.primary)
        case .notObserved:   Text("not seen").foregroundStyle(.secondary)
        case .notObservable: Text("—").foregroundStyle(.secondary)
        }
    }

    // MARK: - System access

    private func systemAccess(_ grants: [TCCGrant]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("System access granted").font(.callout.bold())
                InfoButton(articleID: "full-disk-access-grant")
            }
            ForEach(grants) { grant in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(grant.decision.isAllowed ? .red : .secondary)
                        .font(.caption)
                    Text(grant.serviceLabel).bold()
                    Text("— \(decisionLabel(grant.decision))")
                        .foregroundStyle(decisionColor(grant.decision))
                    Text("(\(grant.scope.rawValue))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - FDA remediation card

    private var fdaCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Grant Full Disk Access to read permission grants").bold()
                Text("macOS protects the TCC databases. Give privacycommand Full Disk Access in System Settings, then reopen this app, to see what the OS has actually granted.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Full Disk Access settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            Spacer()
            InfoButton(articleID: "tcc-needs-fda")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    // MARK: - Formatting

    private func decisionLabel(_ decision: TCCDecision) -> String {
        switch decision {
        case .allowed: return "allowed"
        case .limited: return "limited"
        case .denied:  return "denied"
        case .unknown: return "not determined"
        }
    }

    private func decisionColor(_ decision: TCCDecision) -> Color {
        switch decision {
        case .allowed, .limited: return .primary
        case .denied:            return .secondary
        case .unknown:           return .secondary
        }
    }

    private func color(for severity: Finding.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warn:  return .orange
        case .info:  return .secondary
        }
    }
}
