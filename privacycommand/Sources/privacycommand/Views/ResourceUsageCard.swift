import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Live resource-use card for the dashboard. Renders four counters
/// (CPU%, RAM, disk read in last 60s, disk write in last 60s) plus a
/// tiny inline sparkline for CPU% over the available history.
struct ResourceUsageCard: View {
    let samples: [SystemResourceMonitor.Sample]

    var body: some View {
        if !samples.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Text("Resource use")
                InfoButton(articleID: "resource-monitor")
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        counter(label: "CPU",
                                value: String(format: "%.0f%%", latest.cpuPercent),
                                colour: cpuColour(latest.cpuPercent))
                        counter(label: "RAM",
                                value: ByteCountFormatter.string(
                                    fromByteCount: Int64(latest.residentBytes),
                                    countStyle: .memory),
                                colour: .primary)
                        counter(label: "Disk read · 60 s",
                                value: ByteCountFormatter.string(
                                    fromByteCount: Int64(diskRead60s),
                                    countStyle: .file),
                                colour: .secondary)
                        counter(label: "Disk written · 60 s",
                                value: ByteCountFormatter.string(
                                    fromByteCount: Int64(diskWrite60s),
                                    countStyle: .file),
                                colour: .secondary)
                        Spacer()
                    }
                    sparkline
                    if recentSpikes > 0 {
                        Label("\(recentSpikes) CPU spike\(recentSpikes == 1 ? "" : "s") in the last 60 s",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Aggregates

    private var latest: SystemResourceMonitor.Sample {
        samples.last!     // guarded by `!samples.isEmpty` in body
    }

    private var last60: ArraySlice<SystemResourceMonitor.Sample> {
        samples.suffix(60)   // 60 samples ≈ 60 s at 1 Hz
    }

    private var diskRead60s: UInt64 {
        last60.reduce(0) { $0 + $1.diskReadBytesDelta }
    }
    private var diskWrite60s: UInt64 {
        last60.reduce(0) { $0 + $1.diskWriteBytesDelta }
    }
    private var recentSpikes: Int {
        last60.filter(\.wasSpike).count
    }

    // MARK: - Sub-views

    private func counter(label: String, value: String, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.monospacedDigit().bold()).foregroundStyle(colour)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Trivial sparkline — connect-the-dots polyline of CPU% over the
    /// last 60 samples. No axis labels; just a quick at-a-glance shape.
    private var sparkline: some View {
        let recent = Array(last60)
        let cpuValues = recent.map(\.cpuPercent)
        let maxVal = max(cpuValues.max() ?? 100, 100)
        return GeometryReader { geo in
            Path { path in
                guard cpuValues.count > 1 else { return }
                let stepX = geo.size.width / CGFloat(cpuValues.count - 1)
                for (i, v) in cpuValues.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height
                        * (1 - CGFloat(v / maxVal))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else      { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
        .frame(height: 36)
        .background(Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private func cpuColour(_ pct: Double) -> Color {
        if pct >= 100 { return .red }
        if pct >= 50  { return .orange }
        return .primary
    }
}
