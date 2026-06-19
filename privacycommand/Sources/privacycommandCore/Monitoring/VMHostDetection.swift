import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Detects installed macOS-VM front-ends — VirtualBuddy, UTM,
/// Parallels Desktop, VMware Fusion — and exposes a small surface for
/// starting a chosen VM and asking it to mount the guest-agent
/// installer DMG.
///
/// **The automation channel differs per tool — there is no single
/// shared AppleScript surface, despite what an earlier version of this
/// comment claimed:**
/// - **UTM** ships an OSAScript dictionary (`Scripting/UTM.sdef`): a
///   `virtual machine` class with a `status` enum and a `start` verb.
///   Used for both list and start.
/// - **Parallels Desktop** is driven via AppleScript (`start (first
///   virtual machine whose name is …)`).
/// - **VirtualBuddy is NOT AppleScript-scriptable** — its app has no
///   `.sdef` and no `NSAppleScriptEnabled`. Its public automation
///   surface is the `virtualbuddy://` URL scheme (`open` / `boot` /
///   `stop` actions, handled by VirtualBuddy's `DeepLinkSentinel`,
///   gated by a one-time per-client authorization prompt). That scheme
///   has no "list" action, so `listVMs` is `.unsupported` for
///   VirtualBuddy and `startVM` opens a `virtualbuddy://boot` deep link.
/// - **VMware Fusion** exposes no scripting surface we can rely on —
///   `.unsupported` for both list and start.
///
/// Mounting the installer DMG into a running guest is the messier
/// part — none of the tools expose a public "attach disk image"
/// verb. We sidestep by relying on the user manually dragging the DMG
/// file onto their VM (works in every tool) once we reveal the file in
/// Finder for them.
public enum VMHostDetection {

    public struct Tool: Sendable, Hashable {
        public let kind: Kind
        public let appURL: URL
        public let displayName: String

        public enum Kind: String, Sendable, Hashable {
            case virtualBuddy = "VirtualBuddy"
            case utm          = "UTM"
            case parallels    = "Parallels Desktop"
            case vmwareFusion = "VMware Fusion"
        }
    }

    public struct VMSummary: Sendable, Hashable {
        public let toolKind: Tool.Kind
        public let name: String
        public let isRunning: Bool
    }

    /// Outcome of asking a tool for its VM list. We model the failure
    /// modes explicitly instead of collapsing everything to an empty
    /// array, because "this tool has zero VMs" and "macOS blocked the
    /// Apple event" need very different remediation in the UI. The old
    /// behaviour — return `[]` on any error — is exactly what made a
    /// permission/entitlement problem look like an empty VM library.
    public enum VMQueryOutcome: Sendable, Equatable {
        /// The query ran; here are the VMs (possibly empty).
        case ok([VMSummary])
        /// Apple events are blocked (errAEEventNotPermitted, -1743).
        /// Either the `com.apple.security.automation.apple-events`
        /// entitlement is missing on a hardened-runtime build, or the
        /// user hasn't granted Automation access for this tool yet.
        case notAuthorized
        /// The script ran but the app reported an error — e.g. the tool
        /// isn't running, or its AppleScript dictionary uses different
        /// terms on this version. `message` is the human-readable text.
        case scriptError(code: Int, message: String)
        /// This tool has no VM-list AppleScript surface we can rely on.
        case unsupported

        /// VMs if the query succeeded, otherwise empty. Convenience for
        /// callers that only care about the happy path.
        public var vms: [VMSummary] {
            if case .ok(let v) = self { return v }
            return []
        }
    }

    // MARK: - Detection

    public static func detectInstalled() -> [Tool] {
        let fm = FileManager.default
        let candidates: [(Tool.Kind, [String])] = [
            (.virtualBuddy, ["/Applications/VirtualBuddy.app",
                             "\(NSHomeDirectory())/Applications/VirtualBuddy.app"]),
            (.utm,          ["/Applications/UTM.app",
                             "\(NSHomeDirectory())/Applications/UTM.app",
                             "/Applications/Setapp/UTM.app"]),
            (.parallels,    ["/Applications/Parallels Desktop.app"]),
            (.vmwareFusion, ["/Applications/VMware Fusion.app"])
        ]
        return candidates.compactMap { kind, paths in
            for path in paths where fm.fileExists(atPath: path) {
                return Tool(kind: kind,
                            appURL: URL(fileURLWithPath: path),
                            displayName: kind.rawValue)
            }
            return nil
        }
    }

    // MARK: - VM enumeration

    /// List the VMs the chosen tool knows about. The returned
    /// `VMQueryOutcome` distinguishes a genuinely-empty library from a
    /// blocked Apple event or a script error so the UI can give the
    /// right remediation instead of a flat "0 VMs".
    public static func listVMs(for tool: Tool) -> VMQueryOutcome {
        switch tool.kind {
        case .virtualBuddy:
            // VirtualBuddy isn't AppleScript-scriptable and its
            // `virtualbuddy://` deep-link API has no "list" action, so
            // we enumerate by scanning its library folder for `.vbvm`
            // packages (read-only). See `listVirtualBuddyVMs`.
            return listVirtualBuddyVMs()
        case .utm:
            return runListScript(utmListScript, toolKind: .utm)
        case .parallels:
            return runListScript(parallelsListScript, toolKind: .parallels)
        case .vmwareFusion:
            // VMware Fusion's AppleScript is sparse — no list verb we
            // can rely on. The user can still drag the installer DMG
            // onto a running VM manually.
            return .unsupported
        }
    }

    /// Bundle identifier of the VirtualBuddy app, used to read its
    /// preferences for a user-configured library path.
    private static let virtualBuddyBundleID = "codes.rambo.VirtualBuddy"

    /// Enumerate VirtualBuddy's VMs by scanning its library folder for
    /// `*.vbvm` packages. VirtualBuddy isn't AppleScript-scriptable and
    /// its `virtualbuddy://` deep-link API has no "list" action, so a
    /// read-only filesystem scan is the only way to populate the list.
    ///
    /// Each VM is a `<name>.vbvm` package whose VM name is exactly the
    /// filename minus the extension (VirtualBuddy's `VBVirtualMachine`
    /// derives `name` as `bundleURL.deletingPathExtension()
    /// .lastPathComponent`). So the names we hand back here match what
    /// `virtualbuddy://boot?name=…` expects.
    ///
    /// This couples us to VirtualBuddy's on-disk layout, which is
    /// undocumented and could change — but the scan is read-only and, if
    /// the folder is missing/unreadable/empty, degrades to `.ok([])` so
    /// the UI falls back to its "type a name → Start" affordance rather
    /// than showing an error.
    private static func listVirtualBuddyVMs() -> VMQueryOutcome {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: virtualBuddyLibraryURL(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return .ok([])
        }
        let names = entries
            .filter { $0.pathExtension == VirtualBuddyConstants.bundleExtension }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return .ok(names.map {
            VMSummary(toolKind: .virtualBuddy, name: $0, isRunning: false)
        })
    }

    private enum VirtualBuddyConstants {
        /// VirtualBuddy's VM package extension (`VBVirtualMachine
        /// .bundleExtension`).
        static let bundleExtension = "vbvm"
    }

    /// VirtualBuddy's VM library folder: the path the user configured
    /// (read from VirtualBuddy's own preferences under `libraryPath`) if
    /// set, else the default `~/Library/Application Support/VirtualBuddy`.
    private static func virtualBuddyLibraryURL() -> URL {
        if let custom = UserDefaults(suiteName: virtualBuddyBundleID)?
            .string(forKey: "libraryPath"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support",
                                        isDirectory: true)
        return appSupport.appendingPathComponent("VirtualBuddy",
                                                 isDirectory: true)
    }

    // MARK: - Start a VM

    public static func startVM(named name: String, tool: Tool) -> Bool {
        let script: String
        switch tool.kind {
        case .virtualBuddy:
            // VirtualBuddy isn't AppleScript-scriptable. Its public
            // automation surface is the `virtualbuddy://` URL scheme,
            // dispatched through LaunchServices and handled by
            // VirtualBuddy's `DeepLinkSentinel`. The `boot` action
            // launches the named VM and auto-boots it. The first deep
            // link we send triggers VirtualBuddy's one-time
            // authorization prompt; once the user approves, later boots
            // go straight through. Returns whether LaunchServices found
            // VirtualBuddy to hand the URL to — not whether the VM has
            // finished booting (that happens asynchronously inside
            // VirtualBuddy, possibly behind the auth prompt).
            return openVirtualBuddyDeepLink(action: "boot", vmName: name)
        case .utm:
            // UTM's `virtual machine` class exposes no boolean `running`
            // property — only `status`, an enum whose "VM is running"
            // value is `started` (stopped/starting/started/pausing/
            // paused/resuming/stopping). The old `running of vm` raised an
            // AppleScript error, so `start` never fired and the button
            // silently no-op'd. Guard on `status … is not started` instead;
            // `start` then also resumes a paused VM. Verified against
            // Scripting/UTM.sdef in the utmapp/UTM repo.
            script = """
                tell application "UTM"
                    set vm to virtual machine named "\(name)"
                    if status of vm is not started then start vm
                end tell
                """
        case .parallels:
            script = """
                tell application "Parallels Desktop"
                    start (first virtual machine whose name is "\(name)")
                end tell
                """
        case .vmwareFusion:
            return false   // no AppleScript surface we can rely on
        }
        return runAppleScript(silent: script)
    }

    /// Whether `startVM(named:tool:)` can launch a VM purely from its
    /// name, with no prior VM list. The UI needs this for tools whose
    /// `listVMs` is `.unsupported` (VirtualBuddy): we can still offer a
    /// "type a name → Start" affordance because the start channel is
    /// name-addressable. VMware Fusion has no start surface at all, so
    /// it returns `false` and the UI shows only the manual instructions.
    public static func supportsStartByName(_ kind: Tool.Kind) -> Bool {
        switch kind {
        case .virtualBuddy, .utm, .parallels: return true
        case .vmwareFusion: return false
        }
    }

    /// Build and open a `virtualbuddy://<action>?name=<vm>` deep link.
    /// VirtualBuddy decodes the action from the URL host (`open` /
    /// `boot` / `stop`) and the VM name from the `name` query item.
    /// Using `URLComponents` ensures the name is correctly percent-
    /// encoded (VM names can contain spaces and other reserved
    /// characters). Returns `false` if the URL can't be built or no
    /// handler for the scheme is registered (e.g. VirtualBuddy has
    /// never been launched, so LaunchServices doesn't know the scheme).
    private static func openVirtualBuddyDeepLink(action: String,
                                                 vmName: String) -> Bool {
        var components = URLComponents()
        components.scheme = "virtualbuddy"
        components.host = action
        components.queryItems = [URLQueryItem(name: "name", value: vmName)]
        guard let url = components.url else { return false }
        #if canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }

    // MARK: - Reveal-in-Finder fallback

    /// Drop the DMG into Finder with selection so the user can drag
    /// it onto whichever VM window is open. Works regardless of
    /// VM-tool capabilities. We always offer this even for tools
    /// where AppleScript-based attach would work, because dragging
    /// is uniformly supported and the user understands what's
    /// happening.
    public static func revealInstallerInFinder(at url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    // MARK: - AppleScript runner

    /// errAEEventNotPermitted — the Apple event was blocked, either by a
    /// missing hardened-runtime entitlement or by the user not having
    /// granted Automation access for the target app.
    private static let errAEEventNotPermitted = -1743

    /// Run a VM-list AppleScript and map the result (or failure) into a
    /// `VMQueryOutcome`. Unlike the old runner, errors are reported
    /// rather than swallowed — a blocked Apple event (-1743) becomes
    /// `.notAuthorized`, everything else `.scriptError`.
    private static func runListScript(_ source: String,
                                      toolKind: Tool.Kind) -> VMQueryOutcome {
        guard let script = NSAppleScript(source: source) else {
            return .scriptError(code: 0,
                                message: "Couldn't compile the VM-list query.")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String)
                ?? (error[NSAppleScript.errorBriefMessage] as? String)
                ?? "AppleScript error \(code)."
            NSLog("[privacycommand] VM list (%@) failed: code=%d msg=%@",
                  toolKind.rawValue, code, message)
            if code == errAEEventNotPermitted { return .notAuthorized }
            return .scriptError(code: code, message: message)
        }
        let names = parseStringList(result)
        return .ok(names.map {
            VMSummary(toolKind: toolKind, name: $0, isRunning: false)
        })
    }

    /// Normalise an AppleScript result descriptor (a list of strings, or
    /// a single newline-joined string) into `[String]`. Guards the
    /// empty-list case — the previous `1...max(numberOfItems, 0)` form
    /// trapped on an empty list because `1...0` is an invalid range.
    private static func parseStringList(
        _ result: NSAppleEventDescriptor) -> [String] {
        if result.descriptorType == typeAEList {
            guard result.numberOfItems > 0 else { return [] }
            var items: [String] = []
            for i in 1...result.numberOfItems {
                if let s = result.atIndex(i)?.stringValue, !s.isEmpty {
                    items.append(s)
                }
            }
            return items
        }
        if let one = result.stringValue, !one.isEmpty {
            return one.split(separator: "\n").map(String.init)
        }
        return []
    }

    /// Fire-and-forget AppleScript runner. True on success.
    @discardableResult
    private static func runAppleScript(silent source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error == nil
    }

    // MARK: - Tool-specific scripts

    private static let utmListScript = """
        tell application "UTM"
            set vmList to {}
            repeat with vm in (every virtual machine)
                set end of vmList to (name of vm)
            end repeat
            return vmList
        end tell
        """

    private static let parallelsListScript = """
        tell application "Parallels Desktop"
            set vmList to {}
            repeat with vm in (every virtual machine)
                set end of vmList to (name of vm)
            end repeat
            return vmList
        end tell
        """
}
