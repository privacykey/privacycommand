import Foundation

/// Constants shared between the main app and the privileged helper.
///
/// The bundle ID and Mach-service name MUST match the values in:
///   - `Resources/org.privacykey.privacycommand.HelperTool.plist`  (LaunchDaemon plist)
///   - The helper executable's signing identifier
///   - The main app's `SMPrivilegedExecutables` Info.plist key (for SMJobBless)
///   - The arg passed to `SMAppService.daemon(plistName:)`
public enum HelperToolID {
    /// Mach-service name the helper listens on. Also used as the LaunchDaemon Label.
    public static let machServiceName = "org.privacykey.privacycommand.HelperTool"
    /// File name of the bundled launchd plist (relative to Contents/Library/LaunchDaemons/).
    public static let daemonPlistName = "org.privacykey.privacycommand.HelperTool.plist"
    /// Current protocol version. Bump when the wire format changes; helper rejects
    /// older clients to avoid garbage-in-garbage-out.
    public static let protocolVersion = 1
}

/// XPC interface the helper exposes to the main app.
///
/// All methods use completion-handler style because `NSXPCConnection` doesn't
/// natively bridge Swift `async` across a process boundary in older deployment
/// targets, and the completion-handler style works back to macOS 11.
@objc public protocol HelperToolProtocol {
    /// Returns the helper's version string. Useful both as a liveness probe and
    /// as a way for the GUI to detect a stale helper that needs an upgrade.
    func helperVersion(reply: @escaping (String, Int) -> Void)

    /// Begins streaming file events for the given PID and any descendant
    /// process. Replies with `(true, nil)` on success or `(false, "<reason>")`
    /// on failure. Events are delivered via the reverse interface
    /// (`HelperToolEventReceiver`) on the same connection.
    func startFileMonitor(forPID pid: Int32, reply: @escaping (Bool, String?) -> Void)

    /// Stops streaming file events.
    func stopFileMonitor(reply: @escaping () -> Void)

    /// Install a network kill switch — a pf anchor that drops all
    /// outbound traffic to the supplied IPv4 / IPv6 addresses, system-
    /// wide. Callers populate `addresses` from the destinations the
    /// inspected app has been seen contacting (via NetworkMonitor); the
    /// helper writes / loads / enables the anchor on `pf`.
    ///
    /// Replies with `(true, nil)` on success, `(false, "<reason>")`
    /// otherwise. Calling install while a switch is already active
    /// replaces the address set rather than failing.
    func installNetworkKillSwitch(addresses: [String],
                                  reply: @escaping (Bool, String?) -> Void)

    /// Tear down the network kill switch — flush the anchor and remove
    /// the rules. Idempotent.
    func removeNetworkKillSwitch(reply: @escaping (Bool, String?) -> Void)

    /// Uninstalls the helper. The GUI is responsible for calling
    /// `SMAppService.unregister` separately; this just stops any in-flight work.
    func uninstall(reply: @escaping () -> Void)

    /// Run `/usr/bin/sfltool dumpbtm` with elevated privileges and
    /// return its stdout to the caller.
    ///
    /// **Why this is on the helper.** On macOS 14+ Apple tightened
    /// `sfltool dumpbtm` so an unprivileged invocation triggers an
    /// Authorization Services prompt for an admin password — bad UX
    /// to fire every time the user clicks the Static tab. The helper
    /// already runs as root, so it can shell out without prompting.
    ///
    /// **Why we ship the bytes back rather than parsing in the
    /// helper.** Keeping the helper minimal: parsing and matching
    /// against the inspected bundle is pure-Swift work the GUI can
    /// do, and we don't want to grow the helper's API surface every
    /// time we change what fields we extract from the BTM output.
    ///
    /// Replies with `(stdout, nil)` on success or `(nil, "<reason>")`
    /// on failure. `stdout` may be megabytes — the wire layer is XPC,
    /// so it's a single transfer rather than streamed.
    func runSfltoolDumpBTM(reply: @escaping (String?, String?) -> Void)
}

/// Reverse XPC interface: the helper pushes events to the GUI on the same
/// connection. The GUI exports an object that implements this.
///
/// Events are JSON-encoded `FileEvent` instances. We use an opaque `Data` blob
/// to keep the protocol stable across `FileEvent` changes — only the Codable
/// shape needs to match between app and helper builds.
@objc public protocol HelperToolEventReceiver {
    func helperDidEmitFileEvent(_ data: Data)
    func helperDidEmitLog(_ message: String)
}
