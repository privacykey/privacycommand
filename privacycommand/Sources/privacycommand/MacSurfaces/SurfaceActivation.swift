#if os(macOS)
import AppKit

/// Keeps a menu bar utility in the Dock while any of its windows is open, so
/// the main menu and ⌘, work, and returns it to the menu bar when the last one
/// closes. Every titled window counts: Settings, About and the manual included.
@MainActor
public final class SurfaceActivation {
    public static let shared = SurfaceActivation()

    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Call once at launch in a menu bar utility. Does nothing when repeated.
    public func start() {
        guard observers.isEmpty else { return }
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
#endif
