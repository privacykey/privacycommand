#if os(macOS)
import AppKit
import SwiftUI

/// Whether the menu bar item is shown and which glyph it uses. Writes that do
/// not change a value are ignored: an unguarded `MenuBarExtra(isInserted:)`
/// binding re-renders in a loop.
@MainActor
public final class SurfaceMenuBarPreference: ObservableObject {
    @Published public private(set) var isShown: Bool
    @Published public private(set) var icon: String

    private let defaults: UserDefaults
    private let shownKey: String
    private let iconKey: String

    public init(
        defaultIcon: String,
        shownByDefault: Bool = true,
        defaults: UserDefaults = .standard,
        prefix: String = "surface.menuBar",
        shownKey: String? = nil,
        iconKey: String? = nil
    ) {
        self.defaults = defaults
        self.shownKey = shownKey ?? prefix + ".shown"
        self.iconKey = iconKey ?? prefix + ".icon"
        isShown = defaults.object(forKey: self.shownKey) as? Bool ?? shownByDefault
        icon = defaults.string(forKey: self.iconKey) ?? defaultIcon
    }

    public func setShown(_ value: Bool) {
        guard value != isShown else { return }
        isShown = value
        defaults.set(value, forKey: shownKey)
    }

    public func setIcon(_ value: String) {
        guard value != icon else { return }
        icon = value
        defaults.set(value, forKey: iconKey)
    }

    /// For `MenuBarExtra(isInserted:)` in an app with a Dock icon. Dragging the
    /// item out of the menu bar writes the same setting.
    public var insertion: Binding<Bool> {
        Binding(get: { self.isShown }, set: { self.setShown($0) })
    }
}

/// One choice in the icon picker.
public struct SurfaceMenuBarIcon: Identifiable {
    public let id: String
    public let title: String
    public let image: Image

    public init(id: String, title: String, image: Image) {
        self.id = id
        self.title = title
        self.image = image
    }
}

/// The Menu bar section of General: show or hide (Dock apps only), the icon
/// picker, then a toggle for each optional action the app passes in.
public struct SurfaceMenuBarSection<Actions: View>: View {
    private let app: SurfaceApp
    @ObservedObject private var preference: SurfaceMenuBarPreference
    private let icons: [SurfaceMenuBarIcon]
    private let actions: Actions

    public init(
        app: SurfaceApp,
        preference: SurfaceMenuBarPreference,
        icons: [SurfaceMenuBarIcon],
        @ViewBuilder actions: () -> Actions
    ) {
        self.app = app
        self.preference = preference
        self.icons = icons
        self.actions = actions()
    }

    public var body: some View {
        Section("Menu bar") {
            if app.shape.canHideMenuBarItem {
                Toggle("Show \(app.name) in the menu bar", isOn: preference.insertion)
            }
            Group {
                if icons.count > 1 {
                    LabeledContent("Icon") {
                        HStack(spacing: 6) {
                            ForEach(icons) { icon in
                                iconTile(icon)
                            }
                        }
                    }
                }
                actions
            }
            .disabled(app.shape.canHideMenuBarItem && !preference.isShown)
        }
    }

    private func iconTile(_ icon: SurfaceMenuBarIcon) -> some View {
        let isSelected = icon.id == preference.icon
        return Button {
            preference.setIcon(icon.id)
        } label: {
            VStack(spacing: 3) {
                icon.image
                    .frame(width: 30, height: 22)
                    .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary),
                                in: RoundedRectangle(cornerRadius: 6))
                Text(icon.title).font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Opens Settings from a menu bar item. A utility is activated first so the
/// window does not open behind another app.
struct SurfaceSettingsAction {
    let open: OpenSettingsAction

    @MainActor
    func callAsFunction() {
        NSApplication.shared.activate()
        open()
    }
}

/// The top of a menu bar popover: the mark and the app name.
public struct SurfacePopoverHeader<Trailing: View>: View {
    private let app: SurfaceApp
    private let mark: AnyView
    private let trailing: Trailing

    /// `mark` is drawn at 20 points; `trailing` sits at the right edge, for a
    /// filter menu or a status glyph.
    public init(app: SurfaceApp, mark: Image, @ViewBuilder trailing: () -> Trailing) {
        self.app = app
        self.mark = AnyView(mark.resizable().aspectRatio(contentMode: .fit))
        self.trailing = trailing()
    }

    /// A drawn mark, such as a SwiftUI shape, instead of an image.
    public init<Mark: View>(app: SurfaceApp, @ViewBuilder mark: () -> Mark, @ViewBuilder trailing: () -> Trailing) {
        self.app = app
        self.mark = AnyView(mark())
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 8) {
            mark
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(app.name).font(.headline)
            Spacer()
            trailing
        }
    }
}

extension SurfacePopoverHeader where Trailing == EmptyView {
    public init(app: SurfaceApp, mark: Image) {
        self.init(app: app, mark: mark) { EmptyView() }
    }
}

extension SurfaceMenuBarSection where Actions == EmptyView {
    /// For an item with no optional actions: show or hide and the icon picker only.
    public init(app: SurfaceApp, preference: SurfaceMenuBarPreference, icons: [SurfaceMenuBarIcon]) {
        self.init(app: app, preference: preference, icons: icons) { EmptyView() }
    }
}

/// The bottom of a menu bar popover: Open <App> on the left, then a gear for
/// Settings (⌘,) and Quit <App> (⌘Q). About is reached through Settings.
public struct SurfacePopoverFooter: View {
    @Environment(\.openSettings) private var openSettings
    private let app: SurfaceApp
    private let openApp: (@MainActor () -> Void)?

    /// Pass `openApp` only when the app has a main window.
    public init(app: SurfaceApp, openApp: (@MainActor () -> Void)? = nil) {
        self.app = app
        self.openApp = openApp
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let openApp {
                Button("Open \(app.name)") { openApp() }
            }
            Spacer()
            Button {
                SurfaceSettingsAction(open: openSettings)()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",", modifiers: .command)
            Button("Quit \(app.name)") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
    }
}

/// The closing items of a native menu bar menu: Open <App>, Settings…, Quit.
public struct SurfaceMenuItems: View {
    @Environment(\.openSettings) private var openSettings
    private let app: SurfaceApp
    private let openApp: (@MainActor () -> Void)?

    public init(app: SurfaceApp, openApp: (@MainActor () -> Void)? = nil) {
        self.app = app
        self.openApp = openApp
    }

    public var body: some View {
        Divider()
        if let openApp {
            Button("Open \(app.name)") { openApp() }
        }
        Button("Settings…") { SurfaceSettingsAction(open: openSettings)() }
            .keyboardShortcut(",", modifiers: .command)
        Button("Quit \(app.name)") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
#endif
