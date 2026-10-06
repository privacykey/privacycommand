#if os(macOS)
import SwiftUI

/// One row of the Keyboard Shortcuts window.
public struct SurfaceShortcut: Identifiable, Hashable, Sendable {
    public let keys: String
    public let title: String
    public let detail: String?

    public var id: String { keys + " " + title }

    public init(_ keys: String, _ title: String, detail: String? = nil) {
        self.keys = keys
        self.title = title
        self.detail = detail
    }
}

public struct SurfaceShortcutGroup: Identifiable, Hashable, Sendable {
    public let title: String
    public let items: [SurfaceShortcut]

    public var id: String { title }

    public init(_ title: String, items: [SurfaceShortcut]) {
        self.title = title
        self.items = items
    }

    /// The shortcuts every app has. Put it first.
    public static func standard(for app: SurfaceApp) -> SurfaceShortcutGroup {
        SurfaceShortcutGroup(String(localized: "General"), items: [
            SurfaceShortcut("⌘,", String(localized: "Settings…")),
            SurfaceShortcut("⌘?", String(localized: "Keyboard Shortcuts")),
            SurfaceShortcut("⌘H", String(localized: "Hide \(app.name)")),
            SurfaceShortcut("⌘Q", String(localized: "Quit \(app.name)")),
        ])
    }
}

public struct SurfaceShortcutsView: View {
    private let groups: [SurfaceShortcutGroup]

    public init(groups: [SurfaceShortcutGroup]) {
        self.groups = groups
    }

    public var body: some View {
        Form {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        LabeledContent {
                            Text(item.keys)
                                .font(.body.monospaced())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        } label: {
                            Text(item.title)
                            if let detail = item.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 160, maxHeight: 720)
    }
}

/// The Keyboard Shortcuts window (Help ▸ Keyboard Shortcuts, ⌘?).
public struct SurfaceShortcutsWindow: Scene {
    public static let id = "surface-shortcuts"

    private let groups: [SurfaceShortcutGroup]

    public init(groups: [SurfaceShortcutGroup]) {
        self.groups = groups
    }

    public var body: some Scene {
        Window("Keyboard Shortcuts", id: Self.id) {
            SurfaceShortcutsView(groups: groups)
                .surfaceNotRestored()
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}
#endif
