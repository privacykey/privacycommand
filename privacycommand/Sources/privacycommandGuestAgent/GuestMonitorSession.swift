import Foundation
import privacycommandCore
import privacycommandGuestProtocol
#if canImport(AppKit)
import AppKit
#endif

/// Drives one monitored run *inside the guest VM*.
///
/// Launches the target `.app` and runs the very same monitors the host
/// uses for a local run — `ProcessTracker`, `NetworkMonitor`,
/// `SystemResourceMonitor`, `LiveProbeMonitor` — then forwards everything
/// they emit to the host as `GuestObservation`s. This is the guest-side
/// mirror of `DynamicMonitor`'s orchestration; the host re-classifies and
/// renders the results in its normal tabs.
///
/// **Scope (matches the host's Tier A):** process / network / resource /
/// live-probe events. File-system events need `fs_usage` (root) and are
/// intentionally out of scope here — same limitation the host has without
/// its privileged helper. A note is logged so the host UI can say so.
actor GuestMonitorSession {

    enum LaunchError: Error, LocalizedError {
        case appKitUnavailable
        case noPID
        var errorDescription: String? {
            switch self {
            case .appKitUnavailable: return "AppKit is unavailable inside the guest; can't launch the target."
            case .noPID:             return "Launched the app but couldn't resolve its PID."
            }
        }
    }

    private let bundlePath: String
    /// Thread-safe sink back to the host (the agent's `send`).
    private let emit: @Sendable (GuestObservation) -> Void

    private var processTracker: ProcessTracker?
    private var networkMonitor: NetworkMonitor?
    private var resourceMonitor: SystemResourceMonitor?
    private var liveProbeMonitor: LiveProbeMonitor?
    private var forwardTasks: [Task<Void, Never>] = []
    private var rootPID: Int32 = -1
    private var stopped = false

    init(bundlePath: String, emit: @escaping @Sendable (GuestObservation) -> Void) {
        self.bundlePath = bundlePath
        self.emit = emit
    }

    // MARK: - Lifecycle

    func start() async {
        let pid: Int32
        do {
            pid = try await launch()
        } catch {
            emit(.agentError(message: (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription))
            return
        }
        rootPID = pid
        emit(.logMessage(level: .info,
                         message: "Launched \((bundlePath as NSString).lastPathComponent) (pid \(pid)). Monitoring process/network/resource/live-probe activity. File-system events require root and are not captured."))

        let pt = ProcessTracker(rootPID: pid, bundlePathPrefix: bundlePath)
        let nm = NetworkMonitor(initialPIDs: [pid])
        let rm = SystemResourceMonitor()
        let lpm = LiveProbeMonitor()
        processTracker = pt
        networkMonitor = nm
        resourceMonitor = rm
        liveProbeMonitor = lpm

        await pt.start()
        await nm.start()
        await rm.updatePIDs([pid])
        await rm.start()
        await lpm.updatePIDs([pid])
        await lpm.setTrackedAppName((bundlePath as NSString).lastPathComponent)
        await lpm.start()

        let sink = emit
        forwardTasks = [
            Task { [weak self] in
                for await event in pt.stream { await self?.onProcess(event) }
            },
            Task {
                for await e in nm.stream {
                    sink(.networkEvent(
                        pid: e.pid, processName: e.processName,
                        remoteHost: e.remoteHostname,
                        remoteAddress: e.remoteEndpoint.address,
                        remotePort: e.remoteEndpoint.port,
                        netProto: e.netProto.rawValue,
                        bytesSent: e.bytesSent, bytesReceived: e.bytesReceived,
                        tlsSNI: e.tlsSNI))
                }
            },
            Task {
                for await s in rm.stream {
                    sink(.resourceSample(
                        cpuPercent: s.cpuPercent, residentBytes: s.residentBytes,
                        diskReadBytesDelta: s.diskReadBytesDelta,
                        diskWriteBytesDelta: s.diskWriteBytesDelta,
                        wasSpike: s.wasSpike))
                }
            },
            Task {
                for await p in lpm.stream {
                    sink(.liveProbe(kind: Self.mapProbeKind(p.kind),
                                    pid: p.pid, processName: p.processName,
                                    detail: p.detail))
                }
            }
        ]
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true

        // Capture the tree before tearing the tracker down, so we can
        // terminate the target afterward.
        let pids = await processTracker?.currentPIDs ?? [rootPID]

        forwardTasks.forEach { $0.cancel() }
        forwardTasks = []
        await processTracker?.stop()
        await networkMonitor?.stop()
        await resourceMonitor?.stop()
        await liveProbeMonitor?.stop()
        processTracker = nil
        networkMonitor = nil
        resourceMonitor = nil
        liveProbeMonitor = nil

        // SIGTERM the target's process tree so the inspected app actually
        // quits when the host stops the run.
        for pid in pids where pid > 0 { kill(pid, SIGTERM) }
    }

    // MARK: - Internal

    private func onProcess(_ event: ProcessEvent) async {
        emit(.processEvent(pid: event.pid, ppid: event.ppid,
                           kind: ProcessKind(rawValue: event.kind.rawValue) ?? .start,
                           path: event.path, arguments: event.arguments))

        // Keep the auxiliary monitors mirroring the live PID tree.
        if let pt = processTracker {
            let pids = await pt.currentPIDs
            await networkMonitor?.updatePIDs(pids)
            await resourceMonitor?.updatePIDs(pids)
            await liveProbeMonitor?.updatePIDs(pids)

            // The root process exiting means the run is over.
            if event.kind == .exit, event.pid == rootPID {
                emit(.targetExited(exitCode: 0, signal: nil))
            }
        }
    }

    private func launch() async throws -> Int32 {
        #if canImport(AppKit)
        let url = URL(fileURLWithPath: bundlePath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        guard app.processIdentifier > 0 else { throw LaunchError.noPID }
        return app.processIdentifier
        #else
        throw LaunchError.appKitUnavailable
        #endif
    }

    private static func mapProbeKind(_ kind: LiveProbeEvent.Kind) -> LiveProbeKind {
        switch kind {
        case .pasteboardWrite:      return .pasteboardWrite
        case .cameraStart:          return .cameraStart
        case .cameraStop:           return .cameraStop
        case .microphoneStart:      return .microphoneStart
        case .microphoneStop:       return .microphoneStop
        case .screenRecordingStart: return .screenRecordingStart
        case .screenRecordingStop:  return .screenRecordingStop
        }
    }
}
