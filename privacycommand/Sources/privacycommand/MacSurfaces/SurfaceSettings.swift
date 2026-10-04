#if os(macOS)
import SwiftUI

/// One Settings pane. Supply form sections; the scaffold wraps them in a
/// grouped form.
public struct SurfacePane: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    let content: AnyView

    public init<Content: View>(
        _ title: String,
        systemImage: String,
        id: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id ?? title
        self.title = title
        self.systemImage = systemImage
        self.content = AnyView(content())
    }
}

/// Toolbar-tab Settings for the open-source apps. The first pane is General
/// and ends with the About button. A single pane shows as a plain form.
public struct SurfaceTabSettings: View {
    public nonisolated static let maximumPanes = 5
    public static let width: CGFloat = 560

    /// Five panes at most; merge before adding a sixth.
    public nonisolated static func accepts(paneCount: Int) -> Bool {
        (1...maximumPanes).contains(paneCount)
    }

    private let app: SurfaceApp
    private let panes: [SurfacePane]
    @AppStorage("surface.settings.pane") private var selection = ""

    public init(app: SurfaceApp, panes: [SurfacePane]) {
        assert(Self.accepts(paneCount: panes.count), "Tab Settings take one to \(Self.maximumPanes) panes")
        self.app = app
        self.panes = panes
    }

    public var body: some View {
        Group {
            if panes.count == 1, let only = panes.first {
                form(only)
            } else {
                tabs
            }
        }
        .frame(width: Self.width)
        .onAppear {
            if !panes.contains(where: { $0.id == selection }), let first = panes.first {
                selection = first.id
            }
        }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(macOS 15.0, *) {
            TabView(selection: $selection) {
                ForEach(panes) { pane in
                    Tab(pane.title, systemImage: pane.systemImage, value: pane.id) {
                        form(pane)
                    }
                }
            }
        } else {
            TabView(selection: $selection) {
                ForEach(panes) { pane in
                    form(pane)
                        .tabItem { Label(pane.title, systemImage: pane.systemImage) }
                        .tag(pane.id)
                }
            }
        }
    }

    private func form(_ pane: SurfacePane) -> some View {
        Form {
            pane.content
            if pane.id == panes.first?.id {
                Section {
                    SurfaceAboutButton(app: app)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Sidebar Settings for apps with many panes. A list beside the form, so no
/// collapse button appears; the About button is pinned under the list.
public struct SurfaceSidebarSettings: View {
    public static let minimumSize = CGSize(width: 720, height: 560)
    public static let sidebarWidth: CGFloat = 200

    private let app: SurfaceApp
    private let panes: [SurfacePane]
    @State private var selection: String

    public init(app: SurfaceApp, panes: [SurfacePane]) {
        assert(!panes.isEmpty, "Sidebar Settings need at least one pane")
        self.app = app
        self.panes = panes
        _selection = State(initialValue: panes.first?.id ?? "")
    }

    public var body: some View {
        HStack(spacing: 0) {
            List(selection: selected) {
                ForEach(panes) { pane in
                    Label(pane.title, systemImage: pane.systemImage).tag(pane.id)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                SurfaceAboutButton(app: app)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(width: Self.sidebarWidth)
            Divider()
            Form {
                if let pane = panes.first(where: { $0.id == selection }) {
                    pane.content
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }

    /// One category is always selected: clearing the selection is ignored.
    private var selected: Binding<String?> {
        Binding(
            get: { selection },
            set: { if let value = $0 { selection = value } }
        )
    }
}

/// Picks the layout the app's profile calls for.
public struct SurfaceSettings: View {
    private let app: SurfaceApp
    private let panes: [SurfacePane]

    public init(app: SurfaceApp, panes: [SurfacePane]) {
        self.app = app
        self.panes = panes
    }

    public var body: some View {
        switch app.settingsLayout {
        case .tabs: SurfaceTabSettings(app: app, panes: panes)
        case .sidebar: SurfaceSidebarSettings(app: app, panes: panes)
        }
    }
}
#endif
