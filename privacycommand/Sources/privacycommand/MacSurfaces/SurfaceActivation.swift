#if os(macOS)
import AppKit
import SwiftUI

/// Keeps a menu bar utility in the Dock while any of its windows is open, so
/// the main menu and ⌘, work, and returns it to the menu bar when the last one
/// closes. Every titled window counts: Settings, About and the manual included.
@MainActor
public final class SurfaceActivation {
    public static let shared = SurfaceActivation()

    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Call once at launch in a menu bar utility. Does nothing when repeated.
    /// `initialPolicy` is applied at once; an app without `LSUIElement`, as
    /// when run from `swift run`, passes `.accessory` to start in the menu bar.
    public func start(initialPolicy: NSApplication.ActivationPolicy? = nil) {
        guard observers.isEmpty else { return }
        if let initialPolicy, NSApplication.shared.activationPolicy() != initialPolicy {
            NSApplication.shared.setActivationPolicy(initialPolicy)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SurfaceActivation.shared.update(closing: nil) }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { SurfaceActivation.shared.update(closing: closing) }
        })
    }

    /// A titled window at the normal level. Popovers, menus and the status
    /// item's own window do not count.
    public nonisolated static func countsAsWindow(isVisible: Bool, isTitled: Bool, isPanel: Bool, isNormalLevel: Bool) -> Bool {
        isVisible && isTitled && !isPanel && isNormalLevel
    }

    private func update(closing: ObjectIdentifier?) {
        let hasWindow = NSApplication.shared.windows.contains { window in
            ObjectIdentifier(window) != closing && Self.countsAsWindow(
                isVisible: window.isVisible,
                isTitled: window.styleMask.contains(.titled),
                isPanel: window is NSPanel,
                isNormalLevel: window.level == .normal
            )
        }
        let wanted: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if NSApplication.shared.activationPolicy() != wanted {
            NSApplication.shared.setActivationPolicy(wanted)
            if hasWindow { NSApplication.shared.activate() }
        }
    }
}

/// Marks the hosting window as not restorable, so About, the manual and the
/// shortcuts window do not reopen at the next launch when left open at quit.
struct SurfaceNotRestored: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { view.window?.isRestorable = false }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.window?.isRestorable = false
    }
}

extension View {
    /// Apply to the root view of a secondary window.
    public func surfaceNotRestored() -> some View {
        background(SurfaceNotRestored())
    }
}

/// Opens the Settings scene from AppKit code: a status item's menu, an
/// `NSMenu` action or an app delegate. SwiftUI code uses `openSettings`.
public enum SurfaceSettingsOpener {
    /// Sends the app menu's Settings… item (⌘,), which is what SwiftUI wires;
    /// the `showSettingsWindow:` selector no longer opens it on current macOS.
    @MainActor
    public static func open() {
        NSApplication.shared.activate()
        if let item = settingsItem(in: NSApplication.shared.mainMenu), let action = item.action {
            NSApplication.shared.sendAction(action, to: item.target, from: item)
        } else {
            NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    @MainActor
    static func settingsItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let appMenu = menu?.items.first?.submenu else { return nil }
        return appMenu.items.first { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == [.command] }
    }
}
#endif
