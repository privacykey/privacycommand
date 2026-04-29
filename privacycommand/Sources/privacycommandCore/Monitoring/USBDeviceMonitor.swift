import Foundation

/// Polls `system_profiler SPUSBDataType -json` periodically and emits a
/// `USBChange` whenever the connected-device set changes.
///
/// **Attribution caveat.** macOS doesn't expose a clean public API for
/// "which process is talking to which USB device" — IOKit user-clients
/// would tell us, but require entitlements that aren't available to a
/// third-party tool. So we report system-wide changes and leave
/// attribution to context (was the inspected app frontmost when a
/// device appeared? did the bundle declare the USB-device-access
/// entitlement?). Best-effort.
public actor USBDeviceMonitor {

    public struct Device: Sendable, Hashable, Codable, Identifiable {
        public var id: String { uniqueKey }
        public let name: String
        public let manufacturer: String?
        public let vendorID: String?
        public let productID: String?
        public let serial: String?
        /// Stable hash across polls — used for connect/disconnect diff.
        public let uniqueKey: String

        public init(name: String, manufacturer: String?, vendorID: String?,
                    productID: String?, serial: String?) {
            self.name = name
            self.manufacturer = manufacturer
            self.vendorID = vendorID
            self.productID = productID
            self.serial = serial
            // Prefer serial, fall back to vendor+product+name. Better than
            // a numeric IORegistry path because devices keep that key
            // across reconnections.
            self.uniqueKey = [serial, vendorID, productID, name]
                .compactMap { $0 }.joined(separator: "/")
        }
    }

    public struct Change: Sendable, Hashable, Codable, Identifiable {
        public var id: UUID
        public let timestamp: Date
        public let kind: Kind
        public let device: Device
        public enum Kind: String, Sendable, Hashable, Codable {
            case connected, disconnected
        }
    }

    public nonisolated let stream: AsyncStream<Change>
    private var continuation: AsyncStream<Change>.Continuation?

    public nonisolated let pollInterval: TimeInterval

    private var connected: [String: Device] = [:]
    private var pollTask: Task<Void, Never>?
    private var stopped = false
    private var seeded = false

    public init(pollInterval: TimeInterval = 5.0) {
        self.pollInterval = pollInterval
        // See LiveProbeMonitor.init for why we use makeStream() instead
        // of the IUO trick — this initialiser is the same shape and
        // the same fix applies.
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    public func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.poll()
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        stopped = true
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
    }

    /// Snapshot of devices currently connected — used by the UI to
    /// render the dashboard card without waiting for the next change.
    public var currentDevices: [Device] {
        Array(connected.values).sorted { $0.name < $1.name }
    }

    // MARK: - Polling

    private func poll() async {
        guard !stopped else { return }
        let devices = await Self.runSystemProfiler()
        // Dictionary(uniqueKeysWithValues:) traps on duplicate keys.
        // `uniqueKey` collapses to just `name` when the device has no
        // serial / vendor / product (typical for unnamed USB hubs and
        // bus root nodes), and on real-world hardware with a hub-of-
        // hubs setup — e.g. the CalDigit TS5 Plus, which exposes three
        // USB-3 hub children with similar metadata — that collision
        // path is reachable. Use `uniquingKeysWith:` instead and keep
        // the first occurrence so a colliding sibling can't crash the
        // monitor. Diff semantics are slightly degraded (the second
        // device with the same key won't get its own connect event),
        // but USB monitoring is already documented as best-effort and
        // not crashing is strictly more important than perfect diffs.
        let nowMap = Dictionary(devices.map { ($0.uniqueKey, $0) },
                                uniquingKeysWith: { first, _ in first })

        if seeded {
            // Connect events.
            for (key, dev) in nowMap where connected[key] == nil {
                emit(.init(id: UUID(), timestamp: Date(), kind: .connected, device: dev))
            }
            // Disconnect events.
            for (key, dev) in connected where nowMap[key] == nil {
                emit(.init(id: UUID(), timestamp: Date(), kind: .disconnected, device: dev))
            }
        }
        connected = nowMap
        seeded = true
    }

    private func emit(_ change: Change) {
        guard !stopped else { return }
        continuation?.yield(change)
    }

    // MARK: - system_profiler subprocess

    /// Run `system_profiler SPUSBDataType -json` and walk the (deeply
    /// nested) result tree to collect every leaf USB device. Returns
    /// an empty array on parse failure or a 5 s timeout — USB
    /// monitoring is best-effort, never load-bearing.
    private static func runSystemProfiler() async -> [Device] {
        await withCheckedContinuation { (cont: CheckedContinuation<[Device], Never>) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            task.arguments = ["SPUSBDataType", "-json"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()

            // 5-second timeout — system_profiler usually finishes in
            // well under 1 s but can wedge on flaky devices.
            let deadline = DispatchTime.now() + .seconds(5)
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if task.isRunning { task.terminate() }
            }

            task.terminationHandler = { _ in
                // `try? readToEnd()` flattens to `Data?` via Swift's
                // `try?`-on-throwing-optional rule; the `?? Data()`
                // unwraps to a non-optional `Data`. So no further
                // `guard let` is needed before parsing.
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
                      let dict = json as? [String: Any],
                      let entries = dict["SPUSBDataType"] as? [[String: Any]] else {
                    cont.resume(returning: [])
                    return
                }
                cont.resume(returning: walk(entries: entries))
            }

            do { try task.run() }
            catch { cont.resume(returning: []) }
        }
    }

    /// Recursively walk the nested USB tree. Every dict that looks like
    /// a leaf (has `_name` plus identifying fields) becomes a Device.
    private static func walk(entries: [[String: Any]]) -> [Device] {
        var out: [Device] = []
        for entry in entries {
            // Hubs and root controllers list their downstream devices in
            // `_items`. Walk those recursively.
            if let kids = entry["_items"] as? [[String: Any]] {
                out.append(contentsOf: walk(entries: kids))
            }
            // Filter out the top-level controllers (they don't have
            // vendor/product IDs and aren't user-meaningful).
            if let name = entry["_name"] as? String,
               (entry["vendor_id"] != nil || entry["product_id"] != nil) {
                out.append(Device(
                    name: name,
                    manufacturer: entry["manufacturer"] as? String,
                    vendorID: entry["vendor_id"] as? String,
                    productID: entry["product_id"] as? String,
                    serial: entry["serial_num"] as? String))
            }
        }
        return out
    }
}
