import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct BTMAuditView: View {
    let result: BTMAuditResult
    /// True while a BTM dump (helper or direct) is in flight.
    let isRunning: Bool
    /// True when the privileged helper is installed — the view uses
    /// this to phrase the "automatic vs requires admin prompt"
    /// explanation correctly.
    let helperInstalled: Bool
    /// Invoked when the user clicks "Run BTM audit (requires
    /// admin)". The handler shells out to /usr/bin/sfltool from the
    /// unprivileged app, which on macOS 14+ triggers a system
    /// authorization prompt — that's expected at the moment of the
    /// click, never as a side-effect of the tab appearing.
    let onRunDirect: () -> Void

    var body: some View {
        switch result.state {
        case .toolUnavailable:
            GroupBox(label: header) {
                Text("`sfltool dumpbtm` is not available on this system (requires macOS 13+).")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(8)
            }
        case .notRequested:
            // The tab just became visible and we haven't tried the
            // helper, or the helper isn't installed. Render the
            // explainer + opt-in button.
            GroupBox(label: header) {
                optInBody
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
            // Helper attempt failed (helper crashed, sfltool errored,
            // etc.). Show the message and let the user retry via the
            // direct path.
            GroupBox(label: header) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    optInBody
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .ok:
            if result.matched.isEmpty {
                GroupBox(label: header) {
                    Text("No background services or login items are registered for this app (\(result.allRecordCount) records scanned).")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(8)
                }
            } else {
                GroupBox(label: HStack(spacing: 6) {
                    Text("Background services & login items")
                    InfoButton(articleID: "btm-overview")
                }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(result.matched.count) service\(result.matched.count == 1 ? "" : "s") registered for this app (out of \(result.allRecordCount) on the system).")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(result.matched) { rec in
                            row(rec)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Background Task Management")
            InfoButton(articleID: "btm-overview")
        }
    }

    /// Shared "explain + button" body used by `.notRequested` and
    /// `.failed`. Phrasing changes based on whether the helper is
    /// available: with helper, the prompt text says "auto-runs via
    /// the helper"; without, it leads with the admin-prompt
    /// caveat.
    @ViewBuilder
    private var optInBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if helperInstalled {
                Text("BTM data is fetched automatically via the privileged helper. Click below to retry.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("On macOS 14+, `sfltool dumpbtm` requires admin authorization. We don't run it automatically — install the privileged helper (Settings → Helper) for prompt-free access, or click below to run it now and approve the system prompt.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    onRunDirect()
                } label: {
                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView().controlSize(.small)
                        }
                        Text(helperInstalled
                             ? "Retry BTM audit"
                             : "Run BTM audit (requires admin)")
                    }
                }
                .disabled(isRunning)
                Spacer()
            }
        }
    }

    private func row(_ rec: BTMRecord) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon(rec.kind))
                .foregroundStyle(rec.isEnabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(rec.bundleID ?? rec.identifier ?? rec.url?.lastPathComponent ?? "(unknown)")
                        .font(.caption.monospaced())
                    if rec.isEnabled { tag("enabled", .green) }
                    else             { tag("disabled", .secondary) }
                    if !rec.isAllowed { tag("not allowed", .orange) }
                }
                if let url = rec.url {
                    Text(url.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(rec.kind.rawValue).font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.secondary)
        }
    }

    private func icon(_ k: BTMRecord.Kind) -> String {
        switch k {
        case .loginItem, .loginItemFolder: return "person.crop.circle"
        case .agent:                       return "person.crop.circle.badge.checkmark"
        case .daemon:                      return "shield.lefthalf.filled"
        case .helper:                      return "wrench"
        case .extensionItem:               return "puzzlepiece.extension"
        case .other:                       return "questionmark.circle"
        }
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(c)
    }
}
