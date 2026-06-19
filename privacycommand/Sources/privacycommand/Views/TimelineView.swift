import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct TimelineView: View {
    @EnvironmentObject var coordinator: AnalysisCoordinator
    /// Binary whose static network call sites we're inspecting in a sheet.
    @State private var inspecting: InspectTarget?

    private struct InspectTarget: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live timeline").font(.title3.bold())
                FidelityBadge(.bestEffort,
                              detail: "Events come from process polling and lsof polling. Treat the timeline as a sample, not a complete log.")
                Spacer()
                if ConnectionTracer.isSupported() {
                    Button {
                        coordinator.traceConnections()
                    } label: {
                        Label(coordinator.isTracing ? "Tracing…" : "Trace call sites",
                              systemImage: "scope")
                    }
                    .disabled(coordinator.bundle == nil || coordinator.isTracing)
                    .help("Relaunch this app's binary under a connect()-time tracer to capture which function opened each connection. Non-hardened-runtime binaries only.")
                }
                Text(coordinator.isMonitoring ? "running" : "stopped")
                    .foregroundStyle(coordinator.isMonitoring ? .green : .secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(coordinator.events) { event in
                            row(event).id(event.id)
                        }
                    }
                }
                .onChange(of: coordinator.events.count) { _ in
                    if let last = coordinator.events.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(20)
        .sheet(item: $inspecting) { target in
            DisassemblySummaryView(executableURL: target.url,
                                   onClose: { inspecting = nil })
        }
    }

    private func row(_ e: DynamicEvent) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(e.timestamp.formatted(date: .omitted, time: .standard))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            switch e {
            case .process(let p):
                Image(systemName: p.kind == .exit ? "arrow.down.right.circle" : "arrow.up.right.circle")
                Text("\(p.kind.rawValue) [\(p.pid)] \(p.path)")
                    .font(.callout.monospaced()).lineLimit(1)
            case .file(let f):
                Image(systemName: "folder")
                Text("\(f.op.rawValue) \(f.processName)[\(f.pid)] \(f.path)")
                    .font(.callout.monospaced()).lineLimit(1)
            case .network(let n):
                Image(systemName: "network")
                Text("\(n.netProto.rawValue.uppercased()) \(n.processName)[\(n.pid)] -> \(n.remoteHostname ?? n.remoteEndpoint.address):\(n.remoteEndpoint.port)")
                    .font(.callout.monospaced()).lineLimit(1)
                if let path = n.processPath, !path.isEmpty {
                    Button {
                        inspecting = InspectTarget(url: URL(fileURLWithPath: path))
                    } label: {
                        Image(systemName: "curlybraces")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Inspect this binary's outbound network call sites")
                }
                if let stack = n.callStack, let top = stack.first {
                    Text("← \(top.display)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.purple)
                        .lineLimit(1)
                        .help("Call site captured at connect-time:\n" +
                              stack.prefix(12).map(\.display).joined(separator: "\n"))
                }
            }
        }
        .padding(.vertical, 1)
    }
}
