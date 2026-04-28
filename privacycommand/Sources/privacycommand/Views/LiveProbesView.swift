import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Audit log of pasteboard / camera / microphone events captured by the
/// `LiveProbeMonitor` across the run.
struct LiveProbesView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    @State private var enabledKinds: Set<LiveProbeEvent.Kind.Category> = Set(LiveProbeEvent.Kind.Category.allCases)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            countsRow
            filterChips
            if filtered.isEmpty {
                empty
            } else {
                table
            }
        }
        .padding(20)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Live probes — audit log").font(.title3.bold())
            FidelityBadge(.bestEffort,
                          detail: "Pasteboard reads aren't observable from outside the kernel; we detect writes only. Camera / microphone use is detected via AVCaptureDevice state polling at 500 ms.")
            InfoButton(articleID: "live-probes")
            Spacer()
            if coordinator.isMonitoring {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("live").foregroundStyle(.green).font(.caption)
                }
            } else {
                Text("snapshot frozen").foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    // MARK: - Counts

    private var countsRow: some View {
        let pasteCount = coordinator.liveProbeEvents.filter { $0.kind == .pasteboardWrite }.count
        let cameraStarts = coordinator.liveProbeEvents.filter { $0.kind == .cameraStart }.count
        let micStarts = coordinator.liveProbeEvents.filter { $0.kind == .microphoneStart }.count
        let screenStarts = coordinator.liveProbeEvents.filter { $0.kind == .screenRecordingStart }.count

        return HStack(spacing: 16) {
            counter(value: pasteCount, label: "pasteboard write\(pasteCount == 1 ? "" : "s")",
                    icon: "doc.on.clipboard",
                    colour: pasteCount > 0 ? .orange : .secondary)
            counter(value: cameraStarts, label: "camera session\(cameraStarts == 1 ? "" : "s")",
                    icon: "camera.fill",
                    colour: cameraStarts > 0 ? .red : .secondary)
            counter(value: micStarts, label: "microphone session\(micStarts == 1 ? "" : "s")",
                    icon: "mic.fill",
                    colour: micStarts > 0 ? .red : .secondary)
            counter(value: screenStarts, label: "screen recording\(screenStarts == 1 ? "" : "s")",
                    icon: "rectangle.dashed.badge.record",
                    colour: screenStarts > 0 ? .red : .secondary)
            Spacer()
        }
    }

    private func counter(value: Int, label: String, icon: String, colour: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(colour)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)").font(.title3.monospacedDigit().bold()).foregroundStyle(colour)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Filters

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(LiveProbeEvent.Kind.Category.allCases, id: \.self) { cat in
                let on = enabledKinds.contains(cat)
                Button {
                    if on { enabledKinds.remove(cat) } else { enabledKinds.insert(cat) }
                } label: {
                    Text(cat.rawValue.capitalized)
                        .font(.caption.weight(on ? .semibold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(on ? Color.accentColor.opacity(0.18)
                                       : Color.secondary.opacity(0.10),
                                    in: .capsule)
                        .foregroundStyle(on ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !filtered.isEmpty {
                Text("\(filtered.count) of \(coordinator.liveProbeEvents.count) shown")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(filtered) {
            TableColumn("Time") { e in
                Text(e.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110, max: 130)

            TableColumn("Kind") { e in
                HStack(spacing: 4) {
                    Image(systemName: e.kind.icon).foregroundStyle(colour(for: e.kind))
                    Text(e.kind.rawValue).font(.caption)
                }
            }
            .width(min: 130, ideal: 160, max: 200)

            TableColumn("Process") { e in
                if e.pid > 0 {
                    Text("\(e.processName) [\(e.pid)]").font(.callout.monospaced())
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 130, ideal: 180, max: 240)

            TableColumn("Detail") { e in
                Text(e.detail ?? "—")
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(e.detail ?? "")
            }
            .width(min: 200, ideal: 320)
        }
    }

    // MARK: - Empty state

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 32))
                .foregroundStyle(coordinator.liveProbeEvents.isEmpty
                                 ? Color.secondary : Color.green)
            Text(coordinator.liveProbeEvents.isEmpty
                 ? "No pasteboard, camera, or microphone activity captured yet."
                 : "All filtered out — re-enable a category above.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if coordinator.liveProbeEvents.isEmpty && !coordinator.isMonitoring {
                Text("Start a monitored run from the toolbar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Helpers

    private var filtered: [LiveProbeEvent] {
        coordinator.liveProbeEvents
            .filter { enabledKinds.contains($0.kind.category) }
            .sorted { $0.timestamp > $1.timestamp }   // newest first
    }

    private func colour(for kind: LiveProbeEvent.Kind) -> Color {
        switch kind {
        case .pasteboardWrite:                                return .orange
        case .cameraStart, .microphoneStart, .screenRecordingStart: return .red
        case .cameraStop, .microphoneStop, .screenRecordingStop:    return .secondary
        }
    }
}
