import Foundation
import Network
#if canImport(privacycommandGuestProtocol)
import privacycommandGuestProtocol
#endif

/// Host-side client for the in-VM `privacycommand-guest` agent.
///
/// The guest agent (`privacycommandGuestAgent`) listens on TCP 49374 and
/// speaks the length-prefixed JSON protocol in `privacycommandGuestProtocol`
/// (`GuestEnvelope` / `GuestWireCodec`). This is the *only* piece on the
/// host that talks to it. Two jobs:
///
/// 1. **Connectivity check** — `probe(host:port:)` opens a connection, runs
///    the `.handshake` → `.agentReady` exchange, and reports whether the
///    agent is reachable and version-compatible. This is what gates the
///    "Run in VM" affordance in the UI.
///
/// 2. **A monitored run** — `start(guestBundlePath:)` performs the same
///    handshake, then sends `.launchAndMonitor` and translates the stream of
///    `GuestObservation`s back into the host's own model types
///    (`DynamicEvent` / `LiveProbeEvent` / `SystemResourceMonitor.Sample`) so
///    guest activity flows into the same Dashboard / Network / Files / Probes
///    tabs as a host run. File events are classified host-side with the same
///    `PathClassifier` / `RiskClassifier` used for local runs.
///
/// **Fidelity caveat:** paths and the path-classifier's home-directory logic
/// are host-relative, so a guest whose username differs from the host's may
/// have some file events bucketed as `.userHomeOther` rather than the precise
/// category. Risk promotion still applies. This is surfaced as a fidelity
/// note on VM runs.
public actor VMGuestSession {

    // MARK: - Public result types

    public struct AgentInfo: Sendable, Hashable {
        public let guestVersion: Int
        public let agentBuild: String
        public let hostName: String
        public let macOSVersion: String
    }

    /// Outcome of a connectivity probe. Mirrors the failure modes that
    /// matter to the UI: reachable, version-incompatible, or unreachable.
    public enum ProbeOutcome: Sendable {
        case connected(AgentInfo)
        case versionMismatch(guestVersion: Int, hostVersion: Int)
        case unreachable(String)
    }

    /// Out-of-band notices during a run that aren't `DynamicEvent`s:
    /// agent log lines, the target exiting, or a fatal agent error.
    public enum Notice: Sendable {
        case log(level: String, message: String)
        case targetExited(exitCode: Int32, signal: Int32?)
        case agentError(String)
    }

    public enum SessionError: Error, LocalizedError {
        case unreachable(String)
        case versionMismatch(guestVersion: Int, hostVersion: Int)
        case handshakeTimeout
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .unreachable(let why):
                return "Couldn't reach the guest agent: \(why)"
            case .versionMismatch(let g, let h):
                return "Guest agent protocol v\(g) doesn't match this host (v\(h)). Rebuild and reinstall the guest agent from the installer DMG."
            case .handshakeTimeout:
                return "The guest agent didn't answer the handshake in time."
            case .notConnected:
                return "Not connected to a guest agent."
            }
        }
    }

    // MARK: - Streams (a run feeds these)

    public nonisolated let events: AsyncStream<DynamicEvent>
    public nonisolated let liveProbes: AsyncStream<LiveProbeEvent>
    public nonisolated let resourceSamples: AsyncStream<SystemResourceMonitor.Sample>
    public nonisolated let notices: AsyncStream<Notice>

    private let eventsCont: AsyncStream<DynamicEvent>.Continuation
    private let liveProbesCont: AsyncStream<LiveProbeEvent>.Continuation
    private let resourceCont: AsyncStream<SystemResourceMonitor.Sample>.Continuation
    private let noticesCont: AsyncStream<Notice>.Continuation

    // MARK: - Config + connection state

    private let host: String
    private let port: UInt16
    private let ownerBundleURL: URL?
    private let pathClassifier: PathClassifier
    private let riskClassifier: RiskClassifier

    private var connection: NWConnection?
    private var readBuffer = Data()
    private var didFinish = false

    /// Pending handshake waiter — resolved by the first `.agentReady`
    /// (or an early `.agentError`) after we send `.handshake`.
    private var handshakeCont: CheckedContinuation<AgentInfo, Error>?

    private static let queue = DispatchQueue(label: "com.privacycommand.vmguest")

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Init

    public init(host: String,
                port: UInt16,
                ownerBundleURL: URL? = nil,
                pathClassifier: PathClassifier = .init(),
                riskClassifier: RiskClassifier = .init()) {
        self.host = host
        self.port = port
        self.ownerBundleURL = ownerBundleURL
        self.pathClassifier = pathClassifier
        self.riskClassifier = riskClassifier

        let (es, ec) = AsyncStream<DynamicEvent>.makeStream()
        let (ls, lc) = AsyncStream<LiveProbeEvent>.makeStream()
        let (rs, rc) = AsyncStream<SystemResourceMonitor.Sample>.makeStream()
        let (ns, nc) = AsyncStream<Notice>.makeStream()
        self.events = es; self.eventsCont = ec
        self.liveProbes = ls; self.liveProbesCont = lc
        self.resourceSamples = rs; self.resourceCont = rc
        self.notices = ns; self.noticesCont = nc
    }

    // MARK: - Connectivity probe

    /// Connect, handshake, and report reachability — then disconnect.
    /// Never throws; failures are folded into `ProbeOutcome` so the UI can
    /// render the right remediation. `timeout` bounds the whole exchange.
    public static func probe(host: String,
                             port: UInt16,
                             timeout: TimeInterval = 4) async -> ProbeOutcome {
        let session = VMGuestSession(host: host, port: port)
        defer { Task { await session.stop() } }
        do {
            let info = try await session.connectAndHandshake(timeout: timeout)
            return .connected(info)
        } catch let SessionError.versionMismatch(g, h) {
            return .versionMismatch(guestVersion: g, hostVersion: h)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    // MARK: - Run lifecycle

    /// Handshake, then ask the agent to launch + monitor the bundle at
    /// `guestBundlePath` (a path *inside the guest*). Observations begin
    /// flowing into `events` / `liveProbes` / `resourceSamples` / `notices`.
    /// Returns the agent info on success.
    @discardableResult
    public func start(guestBundlePath: String,
                      handshakeTimeout: TimeInterval = 5) async throws -> AgentInfo {
        let info = try await connectAndHandshake(timeout: handshakeTimeout)
        try send(.command(.launchAndMonitor(bundlePathInGuest: guestBundlePath)))
        return info
    }

    /// Tell the agent to stop the run and close the socket. Idempotent.
    public func stop() async {
        if connection != nil {
            try? send(.command(.stopMonitoring))
        }
        failHandshakeIfPending(SessionError.notConnected)
        finishStreams()
        connection?.cancel()
        connection = nil
    }

    // MARK: - Connect + handshake

    private func connectAndHandshake(timeout: TimeInterval) async throws -> AgentInfo {
        do {
            try await openConnection(timeout: timeout)
            startReceiveLoop()
            return try await withThrowingTaskGroup(of: AgentInfo.self) { group in
                group.addTask { try await self.awaitHandshake() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    throw SessionError.handshakeTimeout
                }
                defer { group.cancelAll() }
                guard let info = try await group.next() else {
                    throw SessionError.handshakeTimeout
                }
                return info
            }
        } catch {
            // Resolve any still-pending handshake waiter (e.g. the timeout
            // task won) exactly once, and drop the half-open connection.
            failHandshakeIfPending(error)
            throw error
        }
    }

    /// Arm the handshake waiter and fire the `.handshake` in the *same*
    /// actor-isolated, non-suspending region so the receive callback can't
    /// deliver `.agentReady` before `handshakeCont` is set (which would
    /// drop the reply and hang until the timeout).
    private func awaitHandshake() async throws -> AgentInfo {
        try await withCheckedThrowingContinuation { cont in
            self.handshakeCont = cont
            do {
                try send(.command(.handshake(hostVersion: GuestProtocolVersion.current)))
            } catch {
                self.handshakeCont = nil
                cont.resume(throwing: error)
            }
        }
    }

    private func openConnection(timeout: TimeInterval) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SessionError.unreachable("invalid port \(port)")
        }
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: nwPort,
                                using: .tcp)
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // `stateUpdateHandler` fires on `Self.queue`, so the resume guard
            // must be thread-safe — `ResumeOnce` serialises the one-shot.
            let once = ResumeOnce(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.succeed()
                case .failed(let err):
                    once.fail(SessionError.unreachable(err.localizedDescription))
                case .waiting(let err):
                    // Connection refused / no route — for a probe we want a
                    // fast, definitive answer rather than NW's silent retry.
                    once.fail(SessionError.unreachable(err.localizedDescription))
                case .cancelled:
                    once.fail(SessionError.unreachable("connection cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: Self.queue)
        }
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.onReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func onReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            readBuffer.append(data)
            drainFrames()
        }
        if isComplete || error != nil {
            if let error {
                deliver(.agentError(error.localizedDescription))
                failHandshakeIfPending(SessionError.unreachable(error.localizedDescription))
            }
            finishStreams()
            return
        }
        startReceiveLoop()
    }

    private func drainFrames() {
        while true {
            let decoded: (envelope: GuestEnvelope, bytesConsumed: Int)?
            do {
                decoded = try GuestWireCodec.decodeOne(from: readBuffer, decoder: decoder)
            } catch {
                // Stream desync (frame-too-large). Drop the connection rather
                // than spin on a corrupt buffer.
                deliver(.agentError("Protocol desync: \(error.localizedDescription)"))
                readBuffer.removeAll()
                return
            }
            guard let decoded else { return }   // need more bytes
            readBuffer.removeFirst(decoded.bytesConsumed)
            handle(decoded.envelope)
        }
    }

    // MARK: - Observation handling / translation

    private func handle(_ envelope: GuestEnvelope) {
        guard case .observation(let obs) = envelope.payload else { return }
        let ts = envelope.timestamp

        switch obs {
        case .agentReady(let guestVersion, let agentBuild, let hostName, let macOSVersion):
            let info = AgentInfo(guestVersion: guestVersion,
                                 agentBuild: agentBuild,
                                 hostName: hostName,
                                 macOSVersion: macOSVersion)
            if guestVersion != GuestProtocolVersion.current {
                failHandshakeIfPending(SessionError.versionMismatch(
                    guestVersion: guestVersion,
                    hostVersion: GuestProtocolVersion.current))
            } else {
                resolveHandshake(info)
            }

        case .acknowledge:
            break

        case .logMessage(let level, let message):
            deliver(.log(level: level.rawValue, message: message))

        case .processEvent(let pid, let ppid, let kind, let path, let arguments):
            let pe = ProcessEvent(timestamp: ts,
                                  kind: ProcessEvent.Kind(rawValue: kind.rawValue) ?? .start,
                                  pid: pid, ppid: ppid,
                                  path: path, arguments: arguments)
            eventsCont.yield(.process(pe))

        case .networkEvent(let pid, let processName, let remoteHost, let remoteAddress,
                           let remotePort, let netProto, let bytesSent, let bytesReceived, let tlsSNI):
            let ne = NetworkEvent(
                firstSeen: ts, lastSeen: ts,
                pid: pid, processName: processName,
                netProto: NetworkEvent.NetProto(rawValue: netProto.lowercased()) ?? .other,
                localEndpoint: .init(address: "", port: 0),
                remoteEndpoint: .init(address: remoteAddress, port: remotePort),
                remoteHostname: remoteHost,
                bytesSent: bytesSent, bytesReceived: bytesReceived,
                tlsSNI: tlsSNI, payloadSamples: [],
                risk: .expected)
            eventsCont.yield(.network(ne))

        case .fileEvent(let pid, let processName, let op, let path, let secondaryPath):
            eventsCont.yield(.file(classifyFile(ts: ts, pid: pid, processName: processName,
                                                op: op, path: path, secondaryPath: secondaryPath)))

        case .resourceSample(let cpuPercent, let residentBytes, let diskRead, let diskWrite, let wasSpike):
            let sample = SystemResourceMonitor.Sample(
                timestamp: ts, pidCount: 0,
                cpuPercent: cpuPercent, residentBytes: residentBytes,
                diskReadBytesDelta: diskRead, diskWriteBytesDelta: diskWrite,
                wasSpike: wasSpike)
            resourceCont.yield(sample)

        case .liveProbe(let kind, let pid, let processName, let detail):
            liveProbesCont.yield(LiveProbeEvent(timestamp: ts,
                                                kind: Self.mapProbeKind(kind),
                                                pid: pid, processName: processName,
                                                detail: detail))

        case .targetExited(let exitCode, let signal):
            deliver(.targetExited(exitCode: exitCode, signal: signal))

        case .agentError(let message):
            deliver(.agentError(message))
        }
    }

    /// Build a classified `FileEvent` from a guest-side raw event, reusing
    /// the host's path + risk classifiers so VM file events colour the same
    /// way host ones do.
    private func classifyFile(ts: Date, pid: Int32, processName: String,
                              op: String, path: String, secondaryPath: String?) -> FileEvent {
        let category = pathClassifier.classify(path, ownerBundleURL: ownerBundleURL)
        let base = FileEvent(timestamp: ts, pid: pid, processName: processName,
                             op: FileEvent.Op(rawValue: op) ?? .other,
                             path: path, secondaryPath: secondaryPath,
                             category: category, risk: .expected, ruleID: nil)
        let decision = riskClassifier.classify(file: base)
        return FileEvent(id: base.id, timestamp: base.timestamp,
                         pid: base.pid, processName: base.processName,
                         op: base.op, path: base.path, secondaryPath: base.secondaryPath,
                         category: base.category, risk: decision.risk, ruleID: decision.ruleID)
    }

    private static func mapProbeKind(_ kind: LiveProbeKind) -> LiveProbeEvent.Kind {
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

    // MARK: - Send

    private func send(_ payload: GuestEnvelope.Payload) throws {
        guard let conn = connection else { throw SessionError.notConnected }
        let envelope = GuestEnvelope(payload: payload)
        let data = try GuestWireCodec.encode(envelope, encoder: encoder)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Continuation / stream bookkeeping

    private func resolveHandshake(_ info: AgentInfo) {
        handshakeCont?.resume(returning: info)
        handshakeCont = nil
    }

    private func failHandshakeIfPending(_ error: Error) {
        handshakeCont?.resume(throwing: error)
        handshakeCont = nil
    }

    private func deliver(_ notice: Notice) {
        noticesCont.yield(notice)
    }

    private func finishStreams() {
        guard !didFinish else { return }
        didFinish = true
        eventsCont.finish()
        liveProbesCont.finish()
        resourceCont.finish()
        noticesCont.finish()
    }
}

/// One-shot, thread-safe resume guard for a `CheckedContinuation` that's
/// driven from an `NWConnection` state handler (which fires on a dispatch
/// queue, not the actor). Guarantees the continuation resumes exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Error>?

    init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }

    func succeed() { resume(.success(())) }
    func fail(_ error: Error) { resume(.failure(error)) }

    private func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
