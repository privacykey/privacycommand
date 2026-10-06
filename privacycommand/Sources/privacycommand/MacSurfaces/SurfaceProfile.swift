#if os(macOS)
import AppKit
import SwiftUI

/// How the app reaches its users. Decides the About links, the legal line,
/// the capability grid and whether update controls exist.
public enum SurfaceDistribution: Sendable, Equatable {
    case appStore(website: URL, support: URL, creator: SurfaceLink)
    case openSource(repository: URL, issues: URL, licence: String)
}

/// Whether the app lives in the Dock, the menu bar, or both.
public enum SurfaceShape: Sendable, Equatable {
    case dockApp
    case dockAppWithMenuBarItem
    case menuBarUtility

    /// Only an app with a Dock icon may hide its menu bar item.
    public var canHideMenuBarItem: Bool { self == .dockAppWithMenuBarItem }
}

public enum SurfaceSettingsLayout: Sendable, Equatable {
    case tabs
    case sidebar
}

public struct SurfaceLink: Identifiable, Sendable, Equatable {
    public let title: String
    public let url: URL
    /// A source link prints its URL beneath the title.
    public let showsURL: Bool

    public var id: URL { url }

    public init(_ title: String, url: URL, showsURL: Bool = false) {
        self.title = title
        self.url = url
        self.showsURL = showsURL
    }
}

public struct SurfaceCapability: Identifiable, Sendable, Equatable {
    public let title: String
    public let detail: String

    public var id: String { title }

    public init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public struct SurfaceAcknowledgement: Identifiable, Sendable, Equatable {
    public let name: String
    public let licence: String
    public let text: String

    public var id: String { name }

    public init(name: String, licence: String, text: String) {
        self.name = name
        self.licence = licence
        self.text = text
    }
}

/// The app name split in two; the second part takes the accent colour.
public struct SurfaceWordmark: Sendable, Equatable {
    public let lead: String
    public let accent: String

    public var plain: String { lead + accent }

    public init(lead: String, accent: String) {
        self.lead = lead
        self.accent = accent
    }
}

/// Everything the shared surfaces need to know about one app.
public struct SurfaceApp: Sendable {
    public var wordmark: SurfaceWordmark
    public var accent: Color
    public var summary: String
    public var capabilities: [SurfaceCapability]
    public var distribution: SurfaceDistribution
    public var shape: SurfaceShape
    public var acknowledgements: [SurfaceAcknowledgement]

    public var name: String { wordmark.plain }

    public init(
        wordmark: SurfaceWordmark,
        accent: Color,
        summary: String,
        capabilities: [SurfaceCapability] = [],
        distribution: SurfaceDistribution,
        shape: SurfaceShape,
        acknowledgements: [SurfaceAcknowledgement] = []
    ) {
        self.wordmark = wordmark
        self.accent = accent
        self.summary = summary
        self.capabilities = capabilities
        self.distribution = distribution
        self.shape = shape
        self.acknowledgements = acknowledgements
    }

    public var settingsLayout: SurfaceSettingsLayout {
        switch distribution {
        case .appStore: .sidebar
        case .openSource: .tabs
        }
    }

    public var showsCapabilityGrid: Bool {
        if case .openSource = distribution { return !capabilities.isEmpty }
        return false
    }

    public var links: [SurfaceLink] {
        switch distribution {
        case let .appStore(website, support, creator):
            [SurfaceLink(String(localized: "Website"), url: website),
             SurfaceLink(String(localized: "Support"), url: support), creator]
        case let .openSource(repository, issues, _):
            [SurfaceLink(String(localized: "Source on GitHub"), url: repository, showsURL: true),
             SurfaceLink(String(localized: "Report an Issue"), url: issues)]
        }
    }

    /// The last line of About. `copyright` is the Info.plist value, if any.
    public func legalLine(copyright: String?, year: Int) -> String {
        let stated = copyright?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mark = (stated?.isEmpty == false ? stated : nil) ?? "© \(year)"
        switch distribution {
        case .appStore: return mark
        case let .openSource(_, _, licence): return "\(licence) · \(mark)"
        }
    }
}

/// What the three Help items do. Leave `openManual` and `openShortcuts` nil
/// to use the shared `SurfaceManualWindow` and `SurfaceShortcutsWindow`.
public struct SurfaceHelp {
    public var openManual: (@MainActor () -> Void)?
    public var openShortcuts: (@MainActor () -> Void)?
    /// Nil in an app that has no first-run welcome; the item is then omitted.
    public var replayWelcome: (@MainActor () -> Void)?

    public init(
        openManual: (@MainActor () -> Void)? = nil,
        openShortcuts: (@MainActor () -> Void)? = nil,
        replayWelcome: (@MainActor () -> Void)? = nil
    ) {
        self.openManual = openManual
        self.openShortcuts = openShortcuts
        self.replayWelcome = replayWelcome
    }

    @MainActor
    func manual(_ openWindow: OpenWindowAction) {
        if let openManual { openManual(); return }
        NSApplication.shared.activate()
        openWindow(id: SurfaceManualWindow.id)
    }

    @MainActor
    func shortcuts(_ openWindow: OpenWindowAction) {
        if let openShortcuts { openShortcuts(); return }
        NSApplication.shared.activate()
        openWindow(id: SurfaceShortcutsWindow.id)
    }
}
#endif
