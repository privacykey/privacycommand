import AppKit
import Combine
import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// Drives the app menu's Install / Uninstall Command Line Tool… item, which
/// links the `auditctl` embedded at `Contents/Helpers/auditctl` into
/// /usr/local/bin for DMG installs. (Homebrew's cask links it on its own.)
///
/// The filesystem work and its safety rules live in `CommandLineTool`; this
/// type adds the menu title and the alerts. Most Macs don't let an admin
/// user write /usr/local/bin without `sudo`, so the common outcome of
/// Install is an alert holding the equivalent Terminal command.
@MainActor
final class CommandLineToolInstaller: ObservableObject {

    @Published private(set) var status: CommandLineTool.Status = .notInstalled

    private let appBundle: URL
    private let tool: CommandLineTool
    private var activation: AnyCancellable?

    init(appBundle: URL = Bundle.main.bundleURL) {
        self.appBundle = appBundle
        self.tool = CommandLineTool(appBundle: appBundle)
        refresh()
        // The link can change from Terminal while the app is in the
        // background; re-read it whenever the app (and its menu) comes back.
        activation = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
    }

    func refresh() {
        let current = tool.status()
        if current != status { status = current }
    }

    /// Uninstall is offered only for the link this item manages; a Homebrew
    /// link belongs to `brew`.
    var menuTitle: String {
        if case .installed(let link) = status, link == tool.link {
            return "Uninstall Command Line Tool…"
        }
        return "Install Command Line Tool…"
    }

    func performMenuAction() {
        refresh()
        switch status {
        case .installed(let link) where link == tool.link:
            confirmUninstall()
        case .installed(let link):
            inform("auditctl is already installed",
                   "\(link.path) links to this copy of privacycommand, so auditctl is already on your PATH. "
                   + "Homebrew manages that link and removes it when you uninstall the cask.")
        default:
            install()
        }
    }

    // MARK: - Install

    private func install() {
        guard !CommandLineTool.isTemporaryLocation(appBundle) else {
            inform("Move privacycommand to Applications first",
                   "privacycommand is running from a disk image or a temporary location, so a link to its "
                   + "command-line tool would stop working. Drag privacycommand to the Applications folder, "
                   + "open it from there, and choose Install Command Line Tool… again.")
            return
        }
        do {
            try tool.install()
            refresh()
            inform("auditctl is installed",
                   "\(tool.link.path) now links to the copy inside privacycommand, so it updates with the app. "
                   + "Open a new Terminal window and run “auditctl --help” to get started.")
        } catch {
            refresh()
            report(error, verb: "install")
        }
    }

    // MARK: - Uninstall

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall the auditctl command?"
        alert.informativeText = "This removes the link at \(tool.link.path). auditctl stays inside "
            + "privacycommand, and you can install it again from this menu."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try tool.uninstall()
            refresh()
        } catch {
            refresh()
            report(error, verb: "uninstall")
        }
    }

    // MARK: - Alerts

    private func report(_ error: Error, verb: String) {
        guard let failure = error as? CommandLineTool.Failure else {
            NSAlert(error: error).runModal()
            return
        }
        switch failure {
        case .permissionDenied(let command):
            showCommand(title: "\(verb.capitalized) auditctl from Terminal",
                        message: "privacycommand needs administrator rights to change \(tool.installDirectory.path). "
                            + "Run this command in Terminal, which asks for your password:",
                        command: command)
        case .occupied(let link, let destination):
            let what = destination.map { "is a link to \($0)" } ?? "is a file"
            inform("Another auditctl is in the way",
                   "\(link.path) \(what), which privacycommand didn't install, so it has left it alone. "
                   + "Remove or rename it, then try again.")
        case .managedElsewhere(let link):
            inform("Homebrew manages this link",
                   "\(link.path) was installed with the privacycommand cask and goes away when you run "
                   + "“brew uninstall --cask privacycommand”.")
        case .notInstalled:
            inform("auditctl isn't installed", "There is no link at \(tool.link.path) to remove.")
        case .unavailable:
            inform("This build doesn't include auditctl",
                   "Release builds of privacycommand carry the command-line tool. To build it from source, "
                   + "see “The auditctl CLI” in the repository's CONTRIBUTING.md.")
        }
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// An alert with a selectable, copyable shell command.
    private func showCommand(title: String, message: String, command: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(wrappingLabelWithString: command)
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.preferredMaxLayoutWidth = 360
        field.frame.size = field.fittingSize
        alert.accessoryView = field
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }
}
