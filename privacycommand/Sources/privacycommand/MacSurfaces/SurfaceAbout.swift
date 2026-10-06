#if os(macOS)
import AppKit
import SwiftUI

/// The app's one About window. Add it to the App body; `SurfaceCommands` and
/// `SurfaceAboutButton` both open it.
public struct SurfaceAboutWindow: Scene {
    public static let id = "surface-about"

    private let app: SurfaceApp
    private let help: SurfaceHelp
    private let build: SurfaceBuild

    public init(app: SurfaceApp, help: SurfaceHelp, build: SurfaceBuild = .current) {
        self.app = app
        self.help = help
        self.build = build
    }

    public var body: some Scene {
        let title = "About \(app.name)"
        return Window(title, id: Self.id) {
            SurfaceAboutView(app: app, help: help, build: build)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}

/// Opens the About window. In a tab layout this is the last row of General; in
/// a sidebar layout it is pinned under the category list.
public struct SurfaceAboutButton: View {
    @Environment(\.openWindow) private var openWindow
    private let app: SurfaceApp

    public init(app: SurfaceApp) {
        self.app = app
    }

    public var body: some View {
        Button("About \(app.name)") {
            NSApplication.shared.activate()
            openWindow(id: SurfaceAboutWindow.id)
        }
    }
}

public struct SurfaceAboutView: View {
    @Environment(\.openWindow) private var openWindow
    private let app: SurfaceApp
    private let help: SurfaceHelp
    private let build: SurfaceBuild

    @State private var showsAcknowledgements = false
    @State private var copied = false

    public init(app: SurfaceApp, help: SurfaceHelp, build: SurfaceBuild = .current) {
        self.app = app
        self.help = help
        self.build = build
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            wordmark
            version
            Text(app.summary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if app.showsCapabilityGrid {
                Divider()
                capabilities
            }
            Divider()
            links
            HStack(spacing: 18) {
                Button("\(app.name) Help") { help.manual(openWindow) }
                Button("Keyboard Shortcuts") { help.shortcuts(openWindow) }
            }
            .buttonStyle(.link)
            footer
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(width: 440)
        .sheet(isPresented: $showsAcknowledgements) {
            SurfaceAcknowledgementsView(items: app.acknowledgements)
        }
    }

    private var wordmark: some View {
        HStack(spacing: 0) {
            Text(app.wordmark.lead)
            Text(app.wordmark.accent).foregroundStyle(app.accent)
        }
        .font(.system(size: 34, weight: .semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
    }

    private var version: some View {
        VStack(spacing: 4) {
            Text(build.versionLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let provenance = build.provenanceLine {
                Button {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString("\(build.versionLine)\n\(provenance)", forType: .string)
                    copied = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(provenance)
                            .font(.caption.monospaced())
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy build details")
            }
        }
    }

    private var capabilities: some View {
        let columns = [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(app.capabilities) { capability in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(capability.title).font(.callout.weight(.semibold))
                        Text(capability.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private var links: some View {
        if app.links.contains(where: \.showsURL) {
            VStack(spacing: 8) {
                ForEach(app.links) { link in
                    VStack(spacing: 2) {
                        Link(link.title, destination: link.url)
                        if link.showsURL {
                            Text(link.url.absoluteString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 18) {
                ForEach(app.links) { link in
                    Link(link.title, destination: link.url)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if !app.acknowledgements.isEmpty {
                Button("Acknowledgements") { showsAcknowledgements = true }
                    .buttonStyle(.link)
            }
            Text(app.legalLine(copyright: build.copyright,
                               year: Calendar.current.component(.year, from: .now)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct SurfaceAcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    let items: [SurfaceAcknowledgement]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Acknowledgements").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.callout.weight(.semibold))
                            Text(item.licence).font(.caption).foregroundStyle(.secondary)
                            Text(item.text)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 420)
    }
}
#endif
