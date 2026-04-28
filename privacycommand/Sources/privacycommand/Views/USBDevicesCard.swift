import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Dashboard card listing currently-connected USB devices and any
/// connect/disconnect changes captured during the run. Attribution to
/// the inspected app is best-effort — macOS doesn't expose a clean API
/// for "which process is talking to which USB device" without
/// entitlements we don't have.
struct USBDevicesCard: View {
    let connected: [USBDeviceMonitor.Device]
    let changes: [USBDeviceMonitor.Change]

    var body: some View {
        // Render only when there's something to show.
        if !connected.isEmpty || !changes.isEmpty {
            GroupBox(label: HStack(spacing: 6) {
                Text("USB devices")
                InfoButton(articleID: "usb-monitor")
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    if !connected.isEmpty {
                        Text("Connected (\(connected.count))").font(.caption.bold())
                        ForEach(connected) { d in
                            deviceRow(d)
                        }
                    }
                    if !changes.isEmpty {
                        if !connected.isEmpty { Divider() }
                        Text("Changes during this run (\(changes.count))")
                            .font(.caption.bold())
                        ForEach(changes.suffix(10).reversed()) { c in
                            changeRow(c)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func deviceRow(_ d: USBDeviceMonitor.Device) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "cable.connector")
                .foregroundStyle(.secondary)
            Text(d.name).font(.callout)
            if let manuf = d.manufacturer {
                Text("· \(manuf)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                if let v = d.vendorID { tag("VID \(v)", .secondary) }
                if let p = d.productID { tag("PID \(p)", .secondary) }
                if d.serial != nil { tag("S/N", .blue) }
            }
        }
    }

    private func changeRow(_ c: USBDeviceMonitor.Change) -> some View {
        HStack(spacing: 6) {
            Image(systemName: c.kind == .connected
                  ? "arrow.down.to.line.compact"
                  : "arrow.up.to.line.compact")
                .foregroundStyle(c.kind == .connected ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(c.device.name) \(c.kind.rawValue)").font(.caption)
                Text(c.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2.monospaced())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(c.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(c)
    }
}
