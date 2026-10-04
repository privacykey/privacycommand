#if os(macOS)
import AppKit
import SwiftUI

/// The standard app menu and Help menu. `Settings…` with ⌘, comes from the
/// app's Settings scene. SwiftUI always puts that item last in its own group,
/// so Check for Updates… takes the next block down, above Services.
public struct SurfaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    private let app: SurfaceApp
    private let help: SurfaceHelp
    private let updates: SurfaceUpdates?

    public init(app: SurfaceApp, help: SurfaceHelp, updates: SurfaceUpdates? = nil) {
        self.app = app
        self.help = help
        self.updates = updates
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(app.name)") {
                NSApplication.shared.activate()
                openWindow(id: SurfaceAboutWindow.id)
            }
        }
        CommandGroup(before: .systemServices) {
            if let updates, case .openSource = app.distribution {
                Button("Check for Updates…") { updates.check() }
                Divider()
            }
        }
        CommandGroup(replacing: .help) {
            Button("\(app.name) Help") { help.openManual() }
            Button("Keyboard Shortcuts") { help.openShortcuts() }
                .keyboardShortcut("?", modifiers: .command)
            if let replay = help.replayWelcome {
                Divider()
                Button("Welcome to \(app.name)") { replay() }
            }
        }
    }
}
#endif
