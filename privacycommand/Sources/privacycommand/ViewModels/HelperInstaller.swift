import Foundation
import SwiftUI
import ServiceManagement
import AppKit
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Installs / uninstalls / connects to the privileged helper daemon.
///
/// Lifecycle (macOS 13+ via `SMAppService`):
///  1. The app bundle ships with the helper executable at
///     `Contents/MacOS/privacycommandHelper` and the launchd plist at
///     `Contents/Library/LaunchDaemons/<bundleID>.HelperTool.plist`.
///  2. The user clicks "Install" in the wizard. We call
///     `SMAppService.daemon(plistName:).register()`.
///  3. macOS shows a system prompt; user opens **System Settings → General
///     → Login Items** and toggles the switch on. (We deep-link there.)
///  4. Once approved, the daemon is loaded by launchd and we can connect via
///     `NSXPCConnection(machServiceName:)`.
///
/// Status values mirror the user-visible states the wizard cares about.
@MainActor
final class HelperInstaller: ObservableObject {

    enum Status: Equatable {
        case unknown               // never queried
        case notFound              // helper isn't bundled or plist missing
        case notRegistered         // bundled but never installed
        case requiresApproval      // installed, awaiting user toggle in System Settings
        case installed             // running and accepting connections
        case error(String)
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var helperVersion: String?
    @Published private(set) var lastEventCount: Int = 0

    private let plistName = HelperToolID.daemonPlistName
    private let machServiceName = HelperToolID.machServiceName

    private var connection: NSXPCConnection?
    private let receiver = HelperEventReceiver()

    /// Refresh the cached status by querying SMAppService.
    func refresh() {
        let service = SMAppService.daemon(plistName: plistName)
        switch service.status {
        case .notRegistered:
            // Not yet registered — but maybe because the plist isn't bundled.
            // If the daemon plist file isn't where SMAppService expects, the
            // daemon() factory still returns a valid object; only register()
            // will fail with a missing-plist error. Detect that by checking
            // the bundle resource directly.
            status = bundledPlistExists ? .notRegistered : .notFound
        case .enabled:
            status = .installed
        case .requiresApproval:
            status = .requiresApproval
        case .notFound:
            status = .notFound
        @unknown default:
            status = .unknown
        }
    }

    /// Begin installation. On a clean install the OS shows a system prompt;
    /// status will move to `.requiresApproval` until the user toggles the
    /// switch in System Settings.
    func install() {
        let service = SMAppService.daemon(plistName: plistName)
        do {
            try service.register()
            // After register(), status may transition asynchronously. Re-query.
            refresh()
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Uninstall (unload + remove) the helper. Idempotent.
    func uninstall() {
        let service = SMAppService.daemon(plistName: plistName)
        connection?.invalidate()
        connection = nil
        do {
            try service.unregister()
            status = .notRegistered
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Open System Settings on the Login Items pane so the user can toggle
    /// the switch. macOS deep-links via `x-apple.systempreferences`.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Connection

    /// Connect to the helper if installed. Idempotent — returns the existing
    /// connection if one is already alive.
    func ensureConnected() -> NSXPCConnection? {
        if let connection { return connection }
        guard status == .installed else { return nil }

        let c = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
        c.exportedInterface = NSXPCInterface(with: HelperToolEventReceiver.self)
        c.exportedObject = receiver
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.resume()
        connection = c

        // Probe version as a liveness check.
        if let proxy = c.remoteObjectProxyWithErrorHandler({ [weak self] err in
            Task { @MainActor in self?.status = .error(err.localizedDescription) }
        }) as? HelperToolProtocol {
            proxy.helperVersion { [weak self] version, protoVersion in
                Task { @MainActor in
                    self?.helperVersion = "\(version) (proto v\(protoVersion))"
                }
            }
        }
        return c
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - High-level RPCs

    enum HelperError: Error, LocalizedError {
        case notInstalled
        case rpcFailed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled:        return "Helper is not installed."
            case .rpcFailed(let msg):  return "Helper RPC failed: \(msg)"
            }
        }
    }

    /// Tells the helper to begin streaming file events for the given PID.
    /// Throws `HelperError.notInstalled` if the helper hasn't been registered.
    func startFileMonitor(forPID pid: Int32) async throws {
        guard let conn = ensureConnected() else {
            throw HelperError.notInstalled
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: HelperError.rpcFailed(error.localizedDescription))
            } as? HelperToolProtocol
            guard let proxy else {
                cont.resume(throwing: HelperError.rpcFailed("proxy unavailable"))
                return
            }
            proxy.startFileMonitor(forPID: pid) { success, message in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: HelperError.rpcFailed(message ?? "unknown"))
                }
            }
        }
    }

    /// Tells the helper to stop streaming. Best-effort — never throws.
    func stopFileMonitor() async {
        guard let conn = connection,
              let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in }) as? HelperToolProtocol else {
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proxy.stopFileMonitor { cont.resume() }
        }
    }

    /// Install the pf-based network kill switch. Throws on failure so
    /// the caller can show a meaningful error to the user.
    func installKillSwitch(addresses: [String]) async throws {
        guard let conn = ensureConnected() else {
            throw HelperError.notInstalled
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: HelperError.rpcFailed(error.localizedDescription))
            } as? HelperToolProtocol
            guard let proxy else {
                cont.resume(throwing: HelperError.rpcFailed("proxy unavailable"))
                return
            }
            proxy.installNetworkKillSwitch(addresses: addresses) { success, message in
                if success { cont.resume() }
                else { cont.resume(throwing: HelperError.rpcFailed(message ?? "unknown")) }
            }
        }
    }

    /// Run `sfltool dumpbtm` via the privileged helper and return
    /// its stdout (or a short error message on failure). Completion
    /// fires on a background queue — the caller is responsible for
    /// hopping back to MainActor before touching `@State`.
    ///
    /// **Why not `async`.** This is invoked from `StaticAnalysisView`
    /// inside a `withCheckedContinuation`, which already handles the
    /// async-bridging. The completion-handler shape lines up
    /// naturally with the underlying XPC reply.
    func dumpBTM(completion: @escaping (String?, String?) -> Void) {
        guard let conn = ensureConnected() else {
            completion(nil, "Helper isn't running.")
            return
        }
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            completion(nil, "Helper RPC failed: \(error.localizedDescription)")
        } as? HelperToolProtocol
        guard let proxy else {
            completion(nil, "Helper proxy unavailable.")
            return
        }
        proxy.runSfltoolDumpBTM { stdout, error in
            completion(stdout, error)
        }
    }

    /// Remove the pf-based network kill switch. Throws on failure;
    /// caller can decide whether to surface the error or proceed.
    func removeKillSwitch() async throws {
        guard let conn = ensureConnected() else {
            throw HelperError.notInstalled
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: HelperError.rpcFailed(error.localizedDescription))
            } as? HelperToolProtocol
            guard let proxy else {
                cont.resume(throwing: HelperError.rpcFailed("proxy unavailable"))
                return
            }
            proxy.removeNetworkKillSwitch { success, message in
                if success { cont.resume() }
                else { cont.resume(throwing: HelperError.rpcFailed(message ?? "unknown")) }
            }
        }
    }

    // MARK: - Probes

    private var bundledPlistExists: Bool {
        guard let resource = Bundle.main.url(
            forResource: "Contents/Library/LaunchDaemons/\(plistName)",
            withExtension: nil
        ) else {
            // Try Contents/Library/LaunchDaemons relative to bundleURL.
            let direct = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchDaemons")
                .appendingPathComponent(plistName)
            return FileManager.default.fileExists(atPath: direct.path)
        }
        return FileManager.default.fileExists(atPath: resource.path)
    }

    // MARK: - Bridge: receive events from helper, forward into a stream

    /// AsyncStream of `FileEvent`s pushed by the helper. Subscribe from the
    /// dynamic monitor when a run is active.
    var fileEventStream: AsyncStream<FileEvent> { receiver.stream }
}

/// XPC-exported object that the helper calls back on.
final class HelperEventReceiver: NSObject, HelperToolEventReceiver {
    let stream: AsyncStream<FileEvent>
    private let continuation: AsyncStream<FileEvent>.Continuation

    override init() {
        var c: AsyncStream<FileEvent>.Continuation!
        // Bounded buffer so events between runs (when nobody's iterating)
        // don't accumulate. Drops oldest under sustained pressure.
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(2048)) { c = $0 }
        self.continuation = c
        super.init()
    }

    func helperDidEmitFileEvent(_ data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The helper's wire format mirrors FileEvent's Codable shape.
        if let event = try? decoder.decode(FileEvent.self, from: data) {
            continuation.yield(event)
        }
    }

    func helperDidEmitLog(_ message: String) {
        // Keep helper logs in the unified Console for now. The wizard view
        // could surface these too; left as a TODO.
        NSLog("[Helper] %@", message)
    }
}
