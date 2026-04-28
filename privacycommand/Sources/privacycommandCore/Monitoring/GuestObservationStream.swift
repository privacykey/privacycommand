import Foundation
import Darwin   // POSIX socket / read / write / connect / close
// Under SwiftPM the protocol types live in a sibling target and we
// import the module. Under Xcode the same .swift files are compiled
// directly into the app target — there's no separate
// `privacycommandGuestProtocol` module to import — so we use
// `canImport` (evaluated at compile time against actual module
// availability) rather than `SWIFT_PACKAGE` (a build-flag that
// Xcode doesn't define but `swift build` does).
#if canImport(privacycommandGuestProtocol)
import privacycommandGuestProtocol
#endif

/// Host-side connector for the guest agent. Opens a TCP connection
/// to the agent running inside a macOS VM, ships `GuestCommand`s, and
/// exposes received `GuestObservation`s as an `AsyncStream` the
/// `AnalysisCoordinator` can wire into its existing live state.
///
/// **Lifecycle.** Caller `connect()`s, awaits the handshake reply
/// (versions checked), then sends `.launchAndMonitor(...)` and reads
/// from `observations` until they're done. `disconnect()` closes the
/// socket and finishes the stream.
///
/// **What this scaffold doesn't do (yet).**
///   • It assumes the guest is reachable at a host:port the caller
///     supplies. Wiring through `Virtualization.framework` to start
///     the VM and resolve its IP is a follow-up task.
///   • It doesn't translate guest paths into host paths. Files and
///     bundles inside the guest live in the guest's filesystem; the
///     UI should label these clearly when surfaced.
///   • Reconnection on transient socket loss isn't handled — if the
///     guest reboots or the network blips, the stream finishes and
///     the caller has to re-`connect()`.
public actor GuestObservationStream {

    public struct ConnectionInfo: Sendable, Hashable {
        public let host: String
        public let port: UInt16
        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    public enum StreamError: Error, LocalizedError {
        case connectFailed(String)
        case handshakeMismatch(hostVersion: Int, guestVersion: Int)
        case agentReportedError(String)
        case connectionClosed
        public var errorDescription: String? {
            switch self {
            case .connectFailed(let m): return "Connection to guest agent failed: \(m)"
            case .handshakeMismatch(let h, let g):
                return "Host / guest protocol mismatch (host=\(h), guest=\(g))."
            case .agentReportedError(let m): return "Guest agent error: \(m)"
            case .connectionClosed: return "Guest connection closed."
            }
        }
    }

    public nonisolated let observations: AsyncStream<GuestObservation>
    private var continuation: AsyncStream<GuestObservation>.Continuation?

    private var socketFD: Int32 = -1
    private var readTask: Task<Void, Never>?
    private var stopped = false

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

    public init() {
        var c: AsyncStream<GuestObservation>.Continuation!
        self.observations = AsyncStream { c = $0 }
        self.continuation = c
    }

    // MARK: - Connect / disconnect

    public func connect(to info: ConnectionInfo) throws {
        guard socketFD < 0 else { return }
        let fd = try Self.openTCP(host: info.host, port: info.port)
        socketFD = fd
        startReader()
    }

    public func disconnect() {
        stopped = true
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        readTask?.cancel()
        readTask = nil
        continuation?.finish()
    }

    // MARK: - Sending commands

    public func send(_ command: GuestCommand) throws {
        guard socketFD >= 0 else { throw StreamError.connectionClosed }
        let envelope = GuestEnvelope(payload: .command(command))
        let data = try GuestWireCodec.encode(envelope, encoder: encoder)
        try Self.writeAll(socketFD, data)
    }

    /// Convenience: issues `.handshake` and waits up to `timeout`
    /// seconds for the matching `.agentReady`. Throws on mismatch
    /// or timeout. Useful for validating the connection at startup.
    public func performHandshake(timeout: TimeInterval = 5) async throws {
        try send(.handshake(hostVersion: GuestProtocolVersion.current))
        let deadline = Date().addingTimeInterval(timeout)
        for await obs in observations {
            // Time-budget check first — if the deadline has passed
            // while we were blocked on the iterator, bail out before
            // dispatching the next observation. Putting the check
            // *before* the switch (rather than after) is what makes
            // it reachable: the switch terminates every path with
            // `return` / `throw` / `continue`, so any code after the
            // switch is unreachable.
            if Date() > deadline {
                throw StreamError.connectFailed("handshake timed out")
            }
            switch obs {
            case .agentReady(let guestVersion, _, _, _):
                if guestVersion != GuestProtocolVersion.current {
                    throw StreamError.handshakeMismatch(
                        hostVersion: GuestProtocolVersion.current,
                        guestVersion: guestVersion)
                }
                return
            case .agentError(let msg):
                throw StreamError.agentReportedError(msg)
            default:
                continue
            }
        }
        throw StreamError.connectionClosed
    }

    // MARK: - Read loop

    private func startReader() {
        let fd = socketFD
        readTask = Task.detached { [weak self] in
            guard let self else { return }
            var buffer = Data()
            let chunkSize = 4096
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            while !Task.isCancelled {
                let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, chunkSize) }
                if n <= 0 {
                    await self.finishStream()
                    return
                }
                buffer.append(contentsOf: chunk.prefix(n))
                while !buffer.isEmpty {
                    do {
                        guard let res = try GuestWireCodec.decodeOne(
                            from: buffer, decoder: self.decoder) else { break }
                        buffer.removeSubrange(0..<res.bytesConsumed)
                        if case .observation(let obs) = res.envelope.payload {
                            await self.yield(obs)
                        }
                    } catch {
                        await self.finishStream()
                        return
                    }
                }
            }
        }
    }

    private func yield(_ obs: GuestObservation) {
        guard !stopped else { return }
        continuation?.yield(obs)
    }

    private func finishStream() {
        stopped = true
        continuation?.finish()
    }

    // MARK: - Static socket helpers

    private static func openTCP(host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        guard getaddrinfo(host, portString, &hints, &result) == 0,
              let head = result else {
            throw StreamError.connectFailed("getaddrinfo failed for \(host):\(port)")
        }
        defer { freeaddrinfo(head) }

        var node = Optional(head)
        while let info = node?.pointee {
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if fd >= 0 {
                // Qualify as Darwin.connect — the actor declares its
                // own `connect(to:)` instance method, and Swift's
                // unqualified lookup picks the member over the global
                // POSIX call.
                if Darwin.connect(fd, info.ai_addr, info.ai_addrlen) == 0 {
                    return fd
                }
                close(fd)
            }
            node = info.ai_next
        }
        throw StreamError.connectFailed("connect() to \(host):\(port) failed")
    }

    /// Repeatedly write until the whole buffer's gone — handles
    /// short writes which are technically possible on a stream.
    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        var written = 0
        try data.withUnsafeBytes { buf in
            let base = buf.baseAddress!
            while written < data.count {
                let n = write(fd, base.advanced(by: written), data.count - written)
                if n <= 0 {
                    throw StreamError.connectionClosed
                }
                written += n
            }
        }
    }
}
