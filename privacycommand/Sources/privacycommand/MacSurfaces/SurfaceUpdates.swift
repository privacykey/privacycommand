#if os(macOS)
import SwiftUI

/// The updater calls the surfaces need. Sparkle's `SPUUpdater` already has
/// every member; see SurfaceSparkle.swift. Main-actor isolated, as Sparkle's
/// updater is.
@MainActor
public protocol SurfaceUpdateDriver: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }
    var lastUpdateCheckDate: Date? { get }
    func checkForUpdates()
}

public enum SurfaceUpdateInterval: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .daily: 86_400
        case .weekly: 604_800
        case .monthly: 2_592_000
        }
    }

    /// The nearest named interval to an updater's stored value.
    public init(seconds: TimeInterval) {
        if seconds <= 2 * 86_400 {
            self = .daily
        } else if seconds <= 14 * 86_400 {
            self = .weekly
        } else {
            self = .monthly
        }
    }
}

/// Update state for the Updates pane and the Check for Updates… item.
/// Automatic checks stay off until the user turns them on; set
/// `SUEnableAutomaticChecks` to false in Info.plist so Sparkle does not ask.
@MainActor
public final class SurfaceUpdates: ObservableObject {
    private let driver: any SurfaceUpdateDriver
    public let channel: String
    public let releaseNotes: URL?

    @Published public private(set) var canCheck: Bool
    @Published public private(set) var lastCheck: Date?
    @Published public var checksAutomatically: Bool {
        didSet {
            if driver.automaticallyChecksForUpdates != checksAutomatically {
                driver.automaticallyChecksForUpdates = checksAutomatically
            }
        }
    }
    @Published public var interval: SurfaceUpdateInterval {
        didSet {
            if SurfaceUpdateInterval(seconds: driver.updateCheckInterval) != interval {
                driver.updateCheckInterval = interval.seconds
            }
        }
    }

    public init(driver: any SurfaceUpdateDriver, channel: String = "Stable", releaseNotes: URL? = nil) {
        self.driver = driver
        self.channel = channel
        self.releaseNotes = releaseNotes
        canCheck = driver.canCheckForUpdates
        lastCheck = driver.lastUpdateCheckDate
        checksAutomatically = driver.automaticallyChecksForUpdates
        interval = SurfaceUpdateInterval(seconds: driver.updateCheckInterval)
    }

    public func check() {
        driver.checkForUpdates()
        refresh()
    }

    /// Re-reads the updater. Values that have not changed are not republished.
    public func refresh() {
        if canCheck != driver.canCheckForUpdates { canCheck = driver.canCheckForUpdates }
        if lastCheck != driver.lastUpdateCheckDate { lastCheck = driver.lastUpdateCheckDate }
        if checksAutomatically != driver.automaticallyChecksForUpdates {
            checksAutomatically = driver.automaticallyChecksForUpdates
        }
        let stored = SurfaceUpdateInterval(seconds: driver.updateCheckInterval)
        if interval != stored { interval = stored }
    }
}

/// The sections of the Updates pane.
public struct SurfaceUpdateSections: View {
    @ObservedObject private var updates: SurfaceUpdates
    private let build: SurfaceBuild

    public init(updates: SurfaceUpdates, build: SurfaceBuild = .current) {
        self.updates = updates
        self.build = build
    }

    public var body: some View {
        Section("This version") {
            LabeledContent("Version", value: "\(build.marketingVersion) · \(updates.channel) channel")
            LabeledContent("Last checked", value: lastChecked)
        }
        .onAppear { updates.refresh() }
        Section("Automatic checks") {
            Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
            Picker("Frequency", selection: $updates.interval) {
                ForEach(SurfaceUpdateInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .disabled(!updates.checksAutomatically)
        }
        Section {
            HStack {
                Button("Check Now") { updates.check() }
                    .disabled(!updates.canCheck)
                if let notes = updates.releaseNotes {
                    Link("Release Notes", destination: notes)
                }
            }
        } footer: {
            if !updates.canCheck {
                Text("This build cannot check for updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lastChecked: String {
        updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never"
    }
}

extension SurfacePane {
    /// The Updates pane, always the last tab in a Sparkle app.
    @MainActor
    public static func updates(_ updates: SurfaceUpdates, build: SurfaceBuild = .current) -> SurfacePane {
        SurfacePane("Updates", systemImage: "arrow.down.circle") {
            SurfaceUpdateSections(updates: updates, build: build)
        }
    }
}
#endif
