import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct DashboardView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator

    var body: some View {
        if let report = coordinator.staticReport {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ExecutiveSummaryView(report: report,
                                         riskScore: coordinator.riskScore)
                    if let score = coordinator.riskScore {
                        RiskScoreSection(score: score)
                    }
                    TelemetrySummaryCard(hits: report.sdkHits)
                    PrivacyLabelsCard(info: report.appStoreInfo,
                                      isFetching: coordinator.isFetchingAppStoreInfo)
                    declaredAndInferred(report: report)
                    fidelitySection
                    counts(report: report)
                    dynamicSection
                    if !coordinator.liveProbeEvents.isEmpty {
                        liveProbesCard
                    }
                    ResourceUsageCard(samples: coordinator.resourceSamples)
                    USBDevicesCard(
                        connected: coordinator.connectedUSBDevices,
                        changes: coordinator.usbChanges)
                    AnomaliesView(report: coordinator.behaviorReport)
                    warningsSection(report: report)
                }
                .padding(20)
            }
        } else {
            Text("No bundle selected").foregroundStyle(.secondary)
        }
    }

    private func declaredAndInferred(report: StaticReport) -> some View {
        GroupBox(label: HStack { Text("Permissions"); FidelityBadge(.staticAnalysis) }) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Declared").font(.headline)
                    if report.declaredPrivacyKeys.isEmpty {
                        Text("(none)").foregroundStyle(.secondary)
                    } else {
                        ForEach(report.declaredPrivacyKeys) { k in
                            HStack(alignment: .top) {
                                Image(systemName: "key.fill")
                                VStack(alignment: .leading) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(k.humanLabel).bold()
                                        InfoButton(articleID: "privacy-\(k.category.rawValue)")
                                    }
                                    Text(k.purposeString.isEmpty ? "(empty purpose string)" : k.purposeString)
                                        .font(.callout)
                                        .foregroundStyle(k.isEmpty ? .red : .secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Inferred").font(.headline)
                    if report.inferredCapabilities.isEmpty {
                        Text("(none)").foregroundStyle(.secondary)
                    } else {
                        ForEach(report.inferredCapabilities) { cap in
                            HStack(alignment: .top) {
                                Image(systemName: cap.declaredButNotJustified ? "questionmark.circle"
                                                : cap.inferredButNotDeclared ? "exclamationmark.triangle"
                                                : "checkmark.circle")
                                    .foregroundStyle(cap.inferredButNotDeclared ? .orange : .secondary)
                                VStack(alignment: .leading) {
                                    Text(cap.category.rawValue).bold()
                                    Text(cap.evidence.first ?? "")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var fidelitySection: some View {
        GroupBox(label: HStack { Text("Fidelity") }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack { FidelityBadge(.staticAnalysis); Text("Bundle parsing, entitlements, signing.") }
                HStack { FidelityBadge(.bestEffort); Text("Network destinations and process tree (poll-based).") }
                HStack { FidelityBadge(.requiresEntitlement, detail: "File events require the privileged helper or Endpoint Security.")
                    Text("File-system activity") }
            }
            .padding(8)
        }
    }

    private func counts(report: StaticReport) -> some View {
        GroupBox("Bundle composition") {
            HStack(spacing: 24) {
                stat("Frameworks", report.frameworks.count)
                stat("XPC services", report.xpcServices.count)
                stat("Login items", report.loginItems.count)
                stat("URL schemes", report.urlSchemes.flatMap(\.schemes).count)
                stat("Hard-coded domains", report.hardcodedDomains.count)
            }.padding(8)
        }
    }
    private func severityColor(_ s: Finding.Severity) -> Color {
        switch s {
        case .error: return .red
        case .warn:  return .orange
        case .info:  return .secondary
        }
    }

    private func stat(_ label: String, _ count: Int, color: Color = .primary) -> some View {
        VStack(alignment: .leading) {
            Text("\(count)").font(.title.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Compact card showing pasteboard / camera / mic / screen event
    /// counts. Only rendered when there's at least one probe event to
    /// surface.
    private var liveProbesCard: some View {
        let pb = coordinator.liveProbeEvents.filter { $0.kind == .pasteboardWrite }.count
        let cam = coordinator.liveProbeEvents.filter { $0.kind == .cameraStart }.count
        let mic = coordinator.liveProbeEvents.filter { $0.kind == .microphoneStart }.count
        let screen = coordinator.liveProbeEvents.filter { $0.kind == .screenRecordingStart }.count
        return GroupBox(label: HStack(spacing: 6) {
            Text("Live probes")
            InfoButton(articleID: "live-probes")
        }) {
            HStack(spacing: 16) {
                probeCounter(icon: "doc.on.clipboard",
                             value: pb, label: "pasteboard write\(pb == 1 ? "" : "s")",
                             colour: pb > 0 ? .orange : .secondary)
                probeCounter(icon: "camera.fill",
                             value: cam, label: "camera session\(cam == 1 ? "" : "s")",
                             colour: cam > 0 ? .red : .secondary)
                probeCounter(icon: "mic.fill",
                             value: mic, label: "microphone session\(mic == 1 ? "" : "s")",
                             colour: mic > 0 ? .red : .secondary)
                probeCounter(icon: "rectangle.dashed.badge.record",
                             value: screen, label: "screen recording\(screen == 1 ? "" : "s")",
                             colour: screen > 0 ? .red : .secondary)
                Spacer()
                Text("See the Probes tab for the audit log →")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private func probeCounter(icon: String, value: Int, label: String, colour: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(colour)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)").font(.title3.monospacedDigit().bold()).foregroundStyle(colour)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var dynamicSection: some View {
        if let summary = coordinator.runSummary {
            GroupBox(label: HStack(spacing: 8) {
                Text("Monitored run")
                FidelityBadge(.bestEffort,
                              detail: "Process tree polled at 250 ms; network destinations polled from lsof at 500 ms.")
                Spacer()
                runStatusBadge
            }) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 24) {
                        stat("Processes", summary.processCount)
                        stat("File events", summary.fileEventCount)
                        stat("Network conns", summary.networkEventCount)
                        stat("Surprising", summary.surprisingEventCount,
                             color: summary.surprisingEventCount > 0 ? .red : .primary)
                    }

                    if summary.fileEventCount == 0 {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lock").foregroundStyle(.blue)
                            Text("File events disabled in this build — install the privileged helper or grant Endpoint Security entitlement to populate this column.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Divider()
                    TopRemoteHostsView()

                    if !summary.topPathCategories.isEmpty {
                        Divider()
                        Text("Top file-path categories").font(.subheadline.bold())
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(summary.topPathCategories.prefix(8), id: \.category) { c in
                                HStack {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    Text(c.category.rawValue)
                                    Spacer()
                                    Text("\(c.count)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }
        } else if coordinator.staticReport != nil {
            GroupBox("Monitored run") {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle").foregroundStyle(.secondary)
                    Text("Hit ‘Start monitored run’ in the toolbar to launch the target and observe it live.")
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var runStatusBadge: some View {
        let durationSuffix = coordinator.runDurationSeconds.map { " · \($0)s" } ?? ""
        if coordinator.isMonitoring {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("running\(durationSuffix)").font(.caption).foregroundStyle(.green)
            }
        } else {
            Text("stopped\(durationSuffix)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func formatBytes(_ b: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var v = Double(b)
        var u = 0
        while v >= 1024 && u < units.count - 1 { v /= 1024; u += 1 }
        return String(format: u == 0 ? "%.0f%@" : "%.1f%@", v, units[u])
    }

    private func warningsSection(report: StaticReport) -> some View {
        Group {
            if report.warnings.isEmpty {
                EmptyView()
            } else {
                GroupBox("Findings") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.warnings) { f in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: f.severity == .error ? "xmark.octagon"
                                                : f.severity == .warn ? "exclamationmark.triangle"
                                                : "info.circle")
                                    .foregroundStyle(severityColor(f.severity))
                                VStack(alignment: .leading) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(f.message).bold()
                                        InfoButton(articleID: f.kbArticleID)
                                    }
                                    ForEach(f.evidence, id: \.self) {
                                        Text($0).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }.padding(8)
                }
            }
        }
    }
}
