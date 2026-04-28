import Foundation

final class HelperToolListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 1. Validate the connecting process — must be signed by the same
        // Team ID as us. SMAppService daemons are *typically* only reachable
        // from the main app, but we belt-and-suspenders this anyway.
        guard CodeSignValidator.validateConnection(newConnection) else {
            NSLog("[privacycommandHelper] Rejecting connection: signature mismatch")
            return false
        }

        let exportedInterface = NSXPCInterface(with: HelperToolProtocol.self)
        let remoteInterface = NSXPCInterface(with: HelperToolEventReceiver.self)

        let service = HelperToolService(connection: newConnection)
        newConnection.exportedInterface = exportedInterface
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = remoteInterface
        newConnection.invalidationHandler = { [weak service] in service?.invalidate() }
        newConnection.interruptionHandler = { [weak service] in service?.invalidate() }
        newConnection.resume()
        return true
    }
}

final class HelperToolService: NSObject, HelperToolProtocol {
    private let connection: NSXPCConnection
    private var fsUsageRunner: FsUsageRunner?
    /// Shared across the helper's lifetime — a single instance owns
    /// the pf anchor file and tracks whether /etc/pf.conf has been
    /// modified, so install/remove from any client are safe.
    private static let killSwitch = PfctlKillSwitch()

    init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    func invalidate() {
        fsUsageRunner?.stop()
        fsUsageRunner = nil
    }

    private var remoteReceiver: HelperToolEventReceiver? {
        connection.remoteObjectProxy as? HelperToolEventReceiver
    }

    // MARK: - HelperToolProtocol

    func helperVersion(reply: @escaping (String, Int) -> Void) {
        reply("privacycommandHelper 0.1.0", HelperToolID.protocolVersion)
    }

    func startFileMonitor(forPID pid: Int32, reply: @escaping (Bool, String?) -> Void) {
        guard fsUsageRunner == nil else {
            reply(false, "Already monitoring")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let runner = FsUsageRunner(pid: pid,
                                   onEvent: { [weak self] event in
            guard let self else { return }
            do {
                let data = try encoder.encode(event)
                self.remoteReceiver?.helperDidEmitFileEvent(data)
            } catch {
                self.remoteReceiver?.helperDidEmitLog("encode error: \(error)")
            }
        }, onLog: { [weak self] msg in
            self?.remoteReceiver?.helperDidEmitLog(msg)
        })
        fsUsageRunner = runner
        do {
            try runner.start()
            reply(true, nil)
        } catch {
            fsUsageRunner = nil
            reply(false, error.localizedDescription)
        }
    }

    func stopFileMonitor(reply: @escaping () -> Void) {
        fsUsageRunner?.stop()
        fsUsageRunner = nil
        reply()
    }

    func installNetworkKillSwitch(addresses: [String],
                                  reply: @escaping (Bool, String?) -> Void) {
        do {
            try Self.killSwitch.install(addresses: addresses)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func removeNetworkKillSwitch(reply: @escaping (Bool, String?) -> Void) {
        do {
            try Self.killSwitch.remove()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func uninstall(reply: @escaping () -> Void) {
        // GUI is responsible for SMAppService.unregister(); we just stop work.
        // Best-effort tear-down of any kill-switch we installed so we
        // don't leave the user with a half-blocked machine.
        try? Self.killSwitch.remove()
        invalidate()
        reply()
    }

    func runSfltoolDumpBTM(reply: @escaping (String?, String?) -> Void) {
        // We're already root inside the helper, so `sfltool dumpbtm`
        // executes without triggering Authorization Services.
        let path = "/usr/bin/sfltool"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            reply(nil, "sfltool not present at \(path) (pre-macOS-13?)")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["dumpbtm"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            reply(nil, "sfltool launch failed: \(error.localizedDescription)")
            return
        }
        // sfltool dumpbtm normally finishes in well under a second.
        // Cap at 8 seconds in case the BTM database is huge or
        // misbehaving — the GUI side has its own deadline too.
        let deadline = Date().addingTimeInterval(8)
        while task.isRunning {
            if Date() > deadline { task.terminate(); break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        if let s = String(data: outData, encoding: .utf8), !s.isEmpty {
            reply(s, nil)
        } else {
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            reply(nil, errStr.isEmpty
                  ? "sfltool produced no output (status \(task.terminationStatus))"
                  : "sfltool failed: \(errStr)")
        }
    }
}
