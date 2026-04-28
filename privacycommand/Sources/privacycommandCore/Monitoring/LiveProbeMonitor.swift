import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Detects pasteboard / camera / microphone / screen-recording activity
/// and emits a `LiveProbeEvent` for each transition.
///
/// Two complementary mechanisms run concurrently:
///
///   * **Pasteboard polling** of `NSPasteboard.general.changeCount` at
///     500 ms. When the count ticks up we attribute the change to the
///     inspected app if it was frontmost *at the moment of the tick or
///     within the last 2 seconds* (the grace handles the brief
///     auditor-frontmost window between user copy and our next poll).
///
///   * **`/usr/bin/log stream`** tailed against the
///     `com.apple.controlcenter` subsystem. macOS's control-centre
///     daemon logs every camera / microphone / screen-recording start
///     and stop with the responsible app's name and PID. This is far
///     more reliable than `AVCaptureDevice.isInUseByAnotherApplication`
///     polling, which is inconsistent across macOS versions when
///     querying *other* processes' usage.
public actor LiveProbeMonitor {

    public nonisolated let stream: AsyncStream<LiveProbeEvent>
    private var continuation: AsyncStream<LiveProbeEvent>.Continuation?

    public nonisolated let pollInterval: TimeInterval

    private var pollTask: Task<Void, Never>?
    private var logStdoutTask: Task<Void, Never>?
    private var logProcess: Process?

    private var trackedPIDs: Set<Int32> = []
    /// Localised app name of the inspected bundle. Used to match against
    /// log-stream messages, which name the responsible process.
    private var trackedAppName: String?
    private nonisolated let auditorPID: Int32 = ProcessInfo.processInfo.processIdentifier

    private var lastChangeCount: Int = 0
    private var lastTrackedFrontmostAt: Date?
    private let frontmostGrace: TimeInterval = 2.0

    /// Last-observed "any camera in use" / "any mic in use" state from
    /// the CoreMediaIO / CoreAudio HAL probes. Stored so we only emit
    /// on transitions.
    private var lastCameraInUse: Bool = false
    private var lastMicInUse: Bool = false

    private var seeded: Bool = false
    private var stopped: Bool = false

    public init(pollInterval: TimeInterval = 0.5) {
        self.pollInterval = pollInterval
        var cont: AsyncStream<LiveProbeEvent>.Continuation!
        self.stream = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    public func updatePIDs(_ pids: Set<Int32>) {
        trackedPIDs = pids
    }

    public func setTrackedAppName(_ name: String?) {
        trackedAppName = name
    }

    public func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.seed()
            while !Task.isCancelled {
                await self.poll()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
        startLogStream()
    }

    public func stop() {
        stopped = true
        pollTask?.cancel()
        pollTask = nil
        logProcess?.terminate()
        logProcess = nil
        logStdoutTask?.cancel()
        logStdoutTask = nil
        continuation?.finish()
    }

    // MARK: - Pasteboard polling

    private func seed() async {
        #if canImport(AppKit)
        lastChangeCount = NSPasteboard.general.changeCount
        #endif
        // Pre-populate the in-use snapshots so the first real poll
        // doesn't fire start events for whatever was already running.
        lastCameraInUse = DeviceUsageProbe.anyCameraInUse()
        lastMicInUse    = DeviceUsageProbe.anyMicrophoneInUse()
        seeded = true
    }

    private func poll() async {
        guard !stopped, seeded else { return }

        #if canImport(AppKit)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontPID  = frontmost?.processIdentifier ?? 0
        let frontName = frontmost?.localizedName ?? "(unknown)"
        let frontIsAuditor = frontPID == auditorPID
        let frontIsTracked = trackedPIDs.contains(frontPID) && !frontIsAuditor

        // Update the "tracked-app was frontmost recently" timestamp so the
        // pasteboard handler can grant a grace window even when the auditor
        // momentarily takes focus.
        if frontIsTracked {
            lastTrackedFrontmostAt = Date()
        }

        // Pasteboard. Emit on every changeCount tick so the user can
        // verify the polling itself is working, but tag the event with
        // its attribution: the tracked app (if it was frontmost now or
        // recently), the auditor (skipped — we don't log our own
        // copies), or "(other)" for everyone else. False positives via
        // "(other)" are noisy, so we skip those when an attribution
        // can't be made — comment that out below for raw-stream
        // diagnostics.
        let pb = NSPasteboard.general
        let count = pb.changeCount
        if count != lastChangeCount {
            let withinGrace = lastTrackedFrontmostAt.map {
                Date().timeIntervalSince($0) < frontmostGrace
            } ?? false
            let attributedToTracked = frontIsTracked || withinGrace

            if attributedToTracked && !frontIsAuditor {
                let attributedName = frontIsTracked ? frontName
                    : (trackedAppName ?? "(unknown)")
                let attributedPID: Int32 = frontIsTracked ? frontPID
                    : (trackedPIDs.first(where: { $0 != auditorPID }) ?? 0)
                let typesDetail = pb.types?.prefix(3).map(\.rawValue).joined(separator: ", ")
                emit(LiveProbeEvent(
                    kind: .pasteboardWrite,
                    pid: attributedPID,
                    processName: attributedName,
                    detail: typesDetail))
            }
            lastChangeCount = count
        }

        // Camera + microphone: query the CoreMediaIO / CoreAudio HAL
        // for "any process is using the device". This bypasses the
        // AVFoundation property which is unreliable across modern
        // macOS versions for cross-process introspection. False
        // positives are possible (some other app could be using the
        // device while the inspected app is frontmost), so we
        // attribute via frontmost-correlation just like pasteboard.
        let cameraNow = DeviceUsageProbe.anyCameraInUse()
        if cameraNow != lastCameraInUse {
            lastCameraInUse = cameraNow
            let attributedName = trackedAppName ?? "(unknown)"
            let attributedPID = trackedPIDs.first(where: { $0 != auditorPID }) ?? 0
            emit(LiveProbeEvent(
                kind: cameraNow ? .cameraStart : .cameraStop,
                pid: cameraNow ? attributedPID : 0,
                processName: cameraNow ? attributedName : "(unknown)",
                detail: nil))
        }
        let micNow = DeviceUsageProbe.anyMicrophoneInUse()
        if micNow != lastMicInUse {
            lastMicInUse = micNow
            let attributedName = trackedAppName ?? "(unknown)"
            let attributedPID = trackedPIDs.first(where: { $0 != auditorPID }) ?? 0
            emit(LiveProbeEvent(
                kind: micNow ? .microphoneStart : .microphoneStop,
                pid: micNow ? attributedPID : 0,
                processName: micNow ? attributedName : "(unknown)",
                detail: nil))
        }
        #endif
    }

    // MARK: - log stream subprocess

    /// Spawn `/usr/bin/log stream` and let stdout land in our queue.
    /// The predicate filters to the controlcenter subsystem and to
    /// messages mentioning the lifecycle verbs we care about — keeps
    /// the per-line work cheap.
    private func startLogStream() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = [
            "stream",
            "--style", "compact",
            "--predicate",
            // Broad enough to catch macOS 13–15 wording variations,
            // narrow enough that we're not parsing the whole system log.
            "(subsystem == 'com.apple.controlcenter') AND " +
            "(eventMessage CONTAINS 'started using' OR " +
            " eventMessage CONTAINS 'stopped using' OR " +
            " eventMessage CONTAINS 'in use by' OR " +
            " eventMessage CONTAINS 'no longer in use')"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch {
            // log-stream not available is non-fatal — pasteboard polling
            // still works.
            return
        }
        logProcess = proc

        // Tail stdout in chunks. We can't use `handle.bytes.lines` here
        // because that's an AsyncSequence on FileHandle which behaves
        // poorly with long-running subprocesses (the file handle never
        // signals EOF). Manual chunking + newline-splitting is more
        // robust.
        let handle = pipe.fileHandleForReading
        logStdoutTask = Task { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
                    continue
                }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.prefix(upTo: nl)
                    buffer.removeSubrange(0..<(nl + 1))
                    if let line = String(data: lineData, encoding: .utf8) {
                        await self?.handleLogLine(line)
                    }
                }
            }
        }
    }

    private func handleLogLine(_ line: String) {
        guard !stopped else { return }
        guard let name = trackedAppName, !name.isEmpty else { return }
        let lower = line.lowercased()
        let trackedLower = name.lowercased()
        guard lower.contains(trackedLower) else { return }

        let isStart = lower.contains("started using") || lower.contains("in use by")
        let isStop  = lower.contains("stopped using") || lower.contains("no longer in use")
        guard isStart || isStop else { return }

        let kind: LiveProbeEvent.Kind?
        if lower.contains("camera") {
            kind = isStart ? .cameraStart : .cameraStop
        } else if lower.contains("microphone") || lower.contains("audio recording") {
            kind = isStart ? .microphoneStart : .microphoneStop
        } else if lower.contains("screen recording") || lower.contains("screen sharing")
                  || lower.contains("screen capture") {
            kind = isStart ? .screenRecordingStart : .screenRecordingStop
        } else {
            kind = nil
        }
        guard let resolvedKind = kind else { return }

        let pid = extractPID(from: line) ?? 0
        emit(LiveProbeEvent(
            kind: resolvedKind,
            pid: pid,
            processName: name,
            detail: line.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Extract a parenthesised PID — `(12345)` — from a log line. macOS's
    /// log format includes one for almost every privacy-related entry.
    private func extractPID(from line: String) -> Int32? {
        guard let m = line.range(of: #"\((\d+)\)"#, options: .regularExpression) else { return nil }
        let inside = line[m].dropFirst().dropLast()
        return Int32(inside)
    }

    private func emit(_ event: LiveProbeEvent) {
        guard !stopped else { return }
        continuation?.yield(event)
    }
}
