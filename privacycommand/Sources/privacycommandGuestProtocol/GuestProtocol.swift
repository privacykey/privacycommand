import Foundation

// MARK: - Versioning

/// Bump on any wire-format-incompatible change. The guest agent
/// rejects connections from older / newer hosts to avoid
/// mis-decoding a freshly-deployed wire change.
public enum GuestProtocolVersion {
    public static let current: Int = 1
}

// MARK: - Envelope

/// Every message — host → guest or guest → host — is wrapped in a
/// `GuestEnvelope` and serialised as JSON, then framed on the wire as
/// `<UInt32 big-endian length><JSON bytes>`. The framing keeps the
/// receiver from having to look for newlines inside the payload (paths
/// and error strings legitimately contain them) and survives short
/// reads.
public struct GuestEnvelope: Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let payload: Payload

    public enum Payload: Codable, Hashable, Sendable {
        case command(GuestCommand)
        case observation(GuestObservation)
    }

    public init(id: UUID = .init(),
                timestamp: Date = .init(),
                payload: Payload) {
        self.id = id
        self.timestamp = timestamp
        self.payload = payload
    }
}

// MARK: - Commands (host → guest)

public enum GuestCommand: Codable, Hashable, Sendable {
    /// Liveness check. Guest replies with `.acknowledge`.
    case ping

    /// Hand-shake. Guest verifies the version and replies with
    /// `.agentReady`. Should be the first message on every connection.
    case handshake(hostVersion: Int)

    /// Launch the .app at `bundlePathInGuest` (a path inside the
    /// guest's filesystem — the host is responsible for transferring
    /// the bundle in via shared folder / scp / whatever the VM image
    /// supports), then start streaming observations until
    /// `.stopMonitoring` arrives.
    case launchAndMonitor(bundlePathInGuest: String)

    /// Stop the current run; terminate the inspected process tree
    /// inside the guest. Idempotent.
    case stopMonitoring

    /// Begin pasteboard / camera / mic / screen-recording probes
    /// inside the guest. Equivalent to `LiveProbeMonitor` running
    /// host-side.
    case startLiveProbes

    case stopLiveProbes

    /// Politely shut the agent down. Caller should close the socket
    /// after sending this.
    case shutdown
}

// MARK: - Observations (guest → host)

public enum GuestObservation: Codable, Hashable, Sendable {

    /// Sent in reply to `.handshake`. `.guestVersion` is the
    /// `GuestProtocolVersion.current` of the agent's build; the host
    /// rejects the connection if it doesn't match its own.
    case agentReady(guestVersion: Int,
                    agentBuild: String,
                    hostName: String,
                    macOSVersion: String)

    case acknowledge(commandID: UUID)

    /// A non-fatal log line the agent wants to surface in the host
    /// UI ("starting fs_usage", "couldn't read /private/var/db",
    /// etc.). Maps to a row in the live event stream tagged
    /// "guest-agent".
    case logMessage(level: LogLevel, message: String)

    /// Mirror of `ProcessEvent` — a process inside the guest
    /// started or exited. Path is the on-disk path *inside* the
    /// guest, not the host.
    case processEvent(pid: Int32, ppid: Int32, kind: ProcessKind,
                      path: String, arguments: [String]?)

    /// Mirror of `NetworkEvent` — connection observed inside the
    /// guest. The remote address may be reachable from the host
    /// (depending on the VM's networking mode) or guest-only.
    case networkEvent(pid: Int32, processName: String,
                      remoteHost: String?, remoteAddress: String,
                      remotePort: UInt16, netProto: String,
                      bytesSent: UInt64, bytesReceived: UInt64,
                      tlsSNI: String?)

    /// Mirror of `FileEvent`. Paths are guest-side.
    case fileEvent(pid: Int32, processName: String,
                   op: String, path: String, secondaryPath: String?)

    /// CPU% / RAM / disk-IO sample — same fields as
    /// `SystemResourceMonitor.Sample`.
    case resourceSample(cpuPercent: Double,
                        residentBytes: UInt64,
                        diskReadBytesDelta: UInt64,
                        diskWriteBytesDelta: UInt64,
                        wasSpike: Bool)

    /// Equivalent of `LiveProbeEvent` — pasteboard / camera / mic /
    /// screen recording inside the guest.
    case liveProbe(kind: LiveProbeKind, pid: Int32,
                   processName: String, detail: String?)

    /// The inspected target inside the guest exited. Run is over.
    case targetExited(exitCode: Int32, signal: Int32?)

    /// A fatal error happened inside the agent. The connection
    /// should be considered finished after this.
    case agentError(message: String)
}

// MARK: - Helper enums

public enum LogLevel: String, Codable, Hashable, Sendable {
    case debug, info, warn, error
}

public enum ProcessKind: String, Codable, Hashable, Sendable {
    case start, exec, exit
}

public enum LiveProbeKind: String, Codable, Hashable, Sendable {
    case pasteboardWrite
    case cameraStart, cameraStop
    case microphoneStart, microphoneStop
    case screenRecordingStart, screenRecordingStop
}

// MARK: - Wire framing helpers

/// Encode an envelope for the wire: 4-byte big-endian length prefix,
/// followed by JSON bytes. Convenience for both host + agent.
public enum GuestWireCodec {

    public static func encode(_ envelope: GuestEnvelope,
                              encoder: JSONEncoder = .init()) throws -> Data {
        let body = try encoder.encode(envelope)
        var lengthBE = UInt32(body.count).bigEndian
        var out = Data()
        withUnsafeBytes(of: &lengthBE) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// Attempt to read a single envelope from `buffer`. On success
    /// returns the envelope and the number of bytes consumed; the
    /// caller should drop the prefix from its buffer. Returns nil if
    /// not enough bytes have arrived yet — caller should read more
    /// and try again.
    public static func decodeOne(from buffer: Data,
                                 decoder: JSONDecoder = .init()) throws
        -> (envelope: GuestEnvelope, bytesConsumed: Int)? {
        guard buffer.count >= 4 else { return nil }
        let lengthBE: UInt32 = buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let length = Int(UInt32(bigEndian: lengthBE))
        // 16 MB hard ceiling — guards against a corrupted prefix
        // making us try to allocate a giant buffer.
        guard length < 16 * 1024 * 1024 else {
            throw GuestWireError.frameTooLarge(length)
        }
        guard buffer.count >= 4 + length else { return nil }
        let body = buffer.subdata(in: 4..<(4 + length))
        let envelope = try decoder.decode(GuestEnvelope.self, from: body)
        return (envelope, 4 + length)
    }
}

public enum GuestWireError: Error, LocalizedError {
    case frameTooLarge(Int)
    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let n):
            return "Envelope frame claims \(n) bytes — likely a stream desync."
        }
    }
}
