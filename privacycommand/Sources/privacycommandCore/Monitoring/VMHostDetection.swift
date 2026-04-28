import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Detects installed macOS-VM front-ends — VirtualBuddy, UTM,
/// Parallels Desktop, VMware Fusion — and exposes a small AppleScript
/// surface for starting a chosen VM and asking it to mount the
/// guest-agent installer DMG.
///
/// **Why AppleScript and not each tool's "real" automation API?**
/// VirtualBuddy ships an OSAScript dictionary (`VBVirtualMachine`).
/// UTM ships an OSAScript dictionary (`UTMVirtualMachine`). Parallels
/// and VMware also expose OSAScript dictionaries. Targeting that
/// shared surface gives us a uniform "start named VM / list VMs"
/// API across all four without having to reverse-engineer each
/// tool's REST or websocket protocol.
///
/// Mounting the installer DMG into a running guest is the messier
/// part — none of the tools expose a public "attach disk image"
/// AppleScript verb. We sidestep by relying on the user manually
/// dragging the DMG file onto their VM (works in every tool) once we
/// reveal the file in Finder for them.
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

    /// List the VMs the chosen tool knows about. Best-effort —
    /// AppleScript dictionaries vary across versions; we fall back
    /// to an empty array on errors so the UI can still render the
    /// tool with a "couldn't enumerate" state.
    public static func listVMs(for tool: Tool) -> [VMSummary] {
        switch tool.kind {
        case .virtualBuddy:
            return runAppleScript(virtualBuddyListScript)
                .map { VMSummary(toolKind: .virtualBuddy, name: $0,
                                 isRunning: false) }
        case .utm:
            return runAppleScript(utmListScript)
                .map { VMSummary(toolKind: .utm, name: $0,
                                 isRunning: false) }
        case .parallels:
            return runAppleScript(parallelsListScript)
                .map { VMSummary(toolKind: .parallels, name: $0,
                                 isRunning: false) }
        case .vmwareFusion:
            // VMware Fusion's AppleScript is sparse. Returning empty
            // is honest; the user can still drag the installer DMG
            // onto a running VM manually.
            return []
        }
    }

    // MARK: - Start a VM

    public static func startVM(named name: String, tool: Tool) -> Bool {
        let script: String
        switch tool.kind {
        case .virtualBuddy:
            script = """
                tell application "VirtualBuddy"
                    start virtual machine named "\(name)"
                end tell
                """
        case .utm:
            script = """
                tell application "UTM"
                    set vm to virtual machine named "\(name)"
                    if not (running of vm) then start vm
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

    /// Run an AppleScript that's expected to return a list of strings
    /// (one VM name per line). Errors → empty array.
    private static func runAppleScript(_ source: String) -> [String] {
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return [] }
        // The result is either a list of strings or a single string;
        // normalise to [String].
        if result.descriptorType == typeAEList {
            var items: [String] = []
            for i in 1...max(result.numberOfItems, 0) {
                if let s = result.atIndex(i)?.stringValue { items.append(s) }
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

    private static let virtualBuddyListScript = """
        tell application "VirtualBuddy"
            set vmList to {}
            repeat with vm in (every virtual machine)
                set end of vmList to (name of vm)
            end repeat
            return vmList
        end tell
        """

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
