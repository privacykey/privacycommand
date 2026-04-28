import Foundation
import privacycommandGuestProtocol

// MARK: - Entry point
//
// `privacycommand-guest` is a small daemon that runs inside the guest
// macOS VM. The host (running the main privacycommand app) connects
// to it over TCP, ships `GuestCommand`s, and consumes the
// `GuestObservation`s the agent emits as the inspected app runs.
//
// **Wiring on first deploy.** Build this target inside the guest VM
// (or build on the host as a Universal binary and copy in via shared
// folder) and add a launchd plist that boots it at login. The agent
// listens on `49374` by default; override with `--port <n>`.
//
// **Observation pipeline status.** The agent's process / network /
// file / live-probe monitors are *intended to be the same classes
// the host uses today* — we'd link against `privacycommandCore` in a
// later step so the guest gets ProcessTracker / NetworkMonitor /
// ResourceMonitor / LiveProbeMonitor / DeviceUsageProbe out of the
// box. For this scaffold the launch-and-monitor flow is stubbed
// with a clear TODO so the wire protocol can be exercised
// end-to-end without pulling Core in yet.

let port = parsePort(CommandLine.arguments) ?? 49374
let agent = GuestAgent(listenPort: UInt16(port))
agent.runForever()

// MARK: - Argument parsing

private func parsePort(_ args: [String]) -> Int? {
    var iter = args.makeIterator()
    while let a = iter.next() {
        if a == "--port", let next = iter.next(), let n = Int(next) { return n }
    }
    return nil
}

// MARK: - GuestAgent

final class GuestAgent {
    let listenPort: UInt16

    private var listenSocket: Int32 = -1
    /// Single-client design — there's only ever one host inspecting
    /// at a time. If a second host connects, we close the previous
    /// connection.
    private var clientSocket: Int32 = -1
    private var clientLock = NSLock()
    private let writeQueue = DispatchQueue(label: "guest-agent.write")

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

    /// Whether the agent is currently running an inspected target.
    /// Bound only on the read thread.
    private var monitoring = false

    init(listenPort: UInt16) {
        self.listenPort = listenPort
    }

    func runForever() -> Never {
        log(.info, "privacycommand-guest starting on port \(listenPort)")
        listenSocket = openListener()
        guard listenSocket >= 0 else {
            FileHandle.standardError.write(
                "fatal: couldn't open listener on \(listenPort)\n".data(using: .utf8)!)
            exit(2)
        }

        while true {
            let client = acceptClient(listenSocket)
            if client < 0 {
                log(.warn, "accept() failed; retrying")
                continue
            }
            clientLock.lock()
            // Boot the previous client out — single-tenant.
            if clientSocket >= 0 { close(clientSocket) }
            clientSocket = client
            clientLock.unlock()
            log(.info, "host connected (fd=\(client))")
            handleClient(client)
            log(.info, "host disconnected")
        }
    }

    // MARK: - Socket setup

    private func openListener() -> Int32 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        // Reuse address so a quick restart of the agent doesn't bind-fail.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = UInt16(listenPort).bigEndian
        addr.sin6_addr = in6addr_any
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard rc == 0, listen(fd, 4) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    private func acceptClient(_ listener: Int32) -> Int32 {
        var addr = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        return withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                accept(listener, rebound, &len)
            }
        }
    }

    // MARK: - Per-client read loop

    private func handleClient(_ fd: Int32) {
        var buffer = Data()
        let chunkSize = 4096
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, chunkSize) }
            if n <= 0 {
                close(fd)
                clientLock.lock()
                if clientSocket == fd { clientSocket = -1 }
                clientLock.unlock()
                return
            }
            buffer.append(contentsOf: chunk.prefix(n))

            // Drain as many envelopes as the buffer holds.
            while !buffer.isEmpty {
                do {
                    guard let result = try GuestWireCodec.decodeOne(
                        from: buffer, decoder: decoder) else { break }
                    buffer.removeSubrange(0..<result.bytesConsumed)
                    handleEnvelope(result.envelope)
                } catch {
                    log(.error, "decode failure: \(error.localizedDescription)")
                    close(fd)
                    return
                }
            }
        }
    }

    private func handleEnvelope(_ env: GuestEnvelope) {
        guard case .command(let cmd) = env.payload else {
            log(.warn, "ignoring non-command envelope")
            return
        }
        switch cmd {
        case .ping:
            send(.acknowledge(commandID: env.id))
        case .handshake(let hostVersion):
            guard hostVersion == GuestProtocolVersion.current else {
                send(.agentError(message: "Protocol version mismatch — host=\(hostVersion) guest=\(GuestProtocolVersion.current)"))
                return
            }
            send(.agentReady(
                guestVersion: GuestProtocolVersion.current,
                agentBuild: "privacycommand-guest 0.1.0",
                hostName: ProcessInfo.processInfo.hostName,
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString))
        case .launchAndMonitor(let path):
            // TODO: link against privacycommandCore and re-use
            // ProcessTracker / NetworkMonitor / ResourceMonitor /
            // LiveProbeMonitor here. The monitors don't actually need
            // the host bits — they're pure libproc / lsof / Core
            // queries that work the same inside a guest.
            //
            // For now we ack, log, and stop — proves the wire is alive.
            send(.acknowledge(commandID: env.id))
            send(.logMessage(level: .info,
                             message: "Launching \(path) — monitoring is stubbed in this build"))
            monitoring = true
        case .stopMonitoring:
            send(.acknowledge(commandID: env.id))
            send(.logMessage(level: .info, message: "Monitoring stopped"))
            monitoring = false
        case .startLiveProbes:
            send(.acknowledge(commandID: env.id))
            send(.logMessage(level: .info,
                             message: "Live probes stubbed — see TODO in guest agent"))
        case .stopLiveProbes:
            send(.acknowledge(commandID: env.id))
        case .shutdown:
            send(.acknowledge(commandID: env.id))
            log(.info, "shutdown requested; exiting")
            exit(0)
        }
    }

    // MARK: - Sending

    private func send(_ obs: GuestObservation) {
        let env = GuestEnvelope(payload: .observation(obs))
        do {
            let data = try GuestWireCodec.encode(env, encoder: encoder)
            writeQueue.async { [weak self] in
                guard let self else { return }
                self.clientLock.lock()
                let fd = self.clientSocket
                self.clientLock.unlock()
                guard fd >= 0 else { return }
                _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            }
        } catch {
            log(.error, "encode failure: \(error)")
        }
    }

    // MARK: - Logging

    private func log(_ level: LogLevel, _ message: String) {
        let line = "[\(level.rawValue)] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        // If we're connected, mirror the message to the host so it
        // shows up in the live event stream alongside its own logs.
        if level != .debug {
            send(.logMessage(level: level, message: message))
        }
    }
}
