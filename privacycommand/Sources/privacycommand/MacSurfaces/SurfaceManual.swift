#if os(macOS)
import AppKit
import SwiftUI

/// A block of a manual page, parsed from Markdown.
public enum SurfaceMarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case code(String)
    case quote(String)
    case rule
    case image(file: String, alt: String)
}

/// The small Markdown subset manual pages use: headings, paragraphs, bullet
/// and numbered lists, fenced code, quotes, rules, images on their own line,
/// and inline emphasis, code and links inside text. A list item wrapped over
/// several indented lines is one item; a blank line or unindented prose ends
/// the list.
public enum SurfaceMarkdown {
    public static func parse(_ text: String) -> [SurfaceMarkdownBlock] {
        var blocks: [SurfaceMarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(rawLine)
                    code = open
                }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; continue }
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6, !title.isEmpty { flush(); blocks.append(.heading(level: level, text: title)); continue }
            }
            if line.hasPrefix("!["), let close = line.firstIndex(of: "]"), line[line.index(after: close)...].hasPrefix("("), line.hasSuffix(")") {
                let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close])
                let file = String(line[line.index(close, offsetBy: 2)..<line.index(before: line.endIndex)])
                flush(); blocks.append(.image(file: file, alt: alt)); continue
            }
            if line.hasPrefix("> ") || line == ">" {
                flush()
                let body = String(line.dropFirst(line == ">" ? 1 : 2))
                if case let .quote(previous)? = blocks.last { blocks[blocks.count - 1] = .quote(previous + " " + body) } else { blocks.append(.quote(body)) }
                continue
            }
            let indented = rawLine.hasPrefix("  ") || rawLine.hasPrefix("\t")
            if indented, !bullets.isEmpty {
                bullets[bullets.count - 1] += " " + line
                continue
            }
            if indented, !numbered.isEmpty {
                numbered[numbered.count - 1] += " " + line
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if !paragraph.isEmpty || !numbered.isEmpty { flush() }
                bullets.append(String(line.dropFirst(2)))
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                if !paragraph.isEmpty || !bullets.isEmpty { flush() }
                numbered.append(String(line[line.index(dot, offsetBy: 2)...]))
                continue
            }
            if !bullets.isEmpty || !numbered.isEmpty { flush() }
            paragraph.append(line)
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// Inline Markdown (emphasis, code, links) for one run of text.
    public static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// One page of the bundled manual: a Markdown file whose first heading is
/// its title. Pages are ordered by file name, so number them.
public struct SurfaceManualPage: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let markdown: String
    public let blocks: [SurfaceMarkdownBlock]

    public init(id: String, markdown: String) {
        self.id = id
        self.markdown = markdown
        blocks = SurfaceMarkdown.parse(markdown)
        title = blocks.compactMap { if case let .heading(_, text) = $0 { text } else { nil } }.first ?? id
    }
}

public enum SurfaceManual {
    /// The app's bundled manual: a `Manual` folder of Markdown files in the
    /// main bundle, copied with the app so it always matches the version.
    public static var bundledFolder: URL? {
        Bundle.main.url(forResource: "Manual", withExtension: nil)
    }

    public static func pages(in folder: URL?) -> [SurfaceManualPage] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return SurfaceManualPage(id: url.deletingPathExtension().lastPathComponent, markdown: text)
            }
    }
}

/// Renders parsed Markdown. Links to another page (`[text](02-page.md)`)
/// select that page; other links open in the browser.
public struct SurfaceMarkdownView: View {
    private let blocks: [SurfaceMarkdownBlock]
    private let folder: URL?

    public init(blocks: [SurfaceMarkdownBlock], folder: URL? = nil) {
        self.blocks = blocks
        self.folder = folder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 680, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: SurfaceMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(level == 1 ? .largeTitle.weight(.bold) : level == 2 ? .title2.weight(.semibold) : .headline)
                .padding(.top, level == 1 ? 0 : 8)
        case let .paragraph(text):
            Text(SurfaceMarkdown.inline(text)).lineSpacing(3)
        case let .bullets(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•")
                        Text(SurfaceMarkdown.inline(item))
                    }
                }
            }
        case let .numbered(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "\(index + 1).").monospacedDigit()
                        Text(SurfaceMarkdown.inline(item))
                    }
                }
            }
        case let .code(text):
            Text(text)
                .font(.body.monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                Text(SurfaceMarkdown.inline(text)).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        case let .image(file, alt):
            if let folder, let image = NSImage(contentsOf: folder.appending(path: file)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 640)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(alt)
            } else {
                Text(alt).italic().foregroundStyle(.secondary)
            }
        }
    }
}

/// The in-app manual: pages in a sidebar, a search field, the page beside it.
public struct SurfaceManualView: View {
    private let app: SurfaceApp
    private let pages: [SurfaceManualPage]
    private let folder: URL?
    @State private var selection: String?
    @State private var query = ""

    public init(app: SurfaceApp, folder: URL?) {
        self.app = app
        self.folder = folder
        pages = SurfaceManual.pages(in: folder)
        _selection = State(initialValue: pages.first?.id)
    }

    private var shown: [SurfaceManualPage] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return pages }
        return pages.filter { $0.title.localizedCaseInsensitiveContains(needle) || $0.markdown.localizedCaseInsensitiveContains(needle) }
    }

    public var body: some View {
        NavigationSplitView {
            List(shown, selection: $selection) { page in
                Text(page.title).tag(page.id)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
            .searchable(text: $query, placement: .sidebar)
        } detail: {
            if let page = pages.first(where: { $0.id == selection }) {
                ScrollView {
                    SurfaceMarkdownView(blocks: page.blocks, folder: folder)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .environment(\.openURL, OpenURLAction { url in
                    if url.pathExtension == "md", pages.contains(where: { $0.id == url.deletingPathExtension().lastPathComponent }) {
                        selection = url.deletingPathExtension().lastPathComponent
                        return .handled
                    }
                    return .systemAction
                })
            } else {
                ContentUnavailableView("This manual has no pages yet", systemImage: "book")
            }
        }
        .navigationTitle("\(app.name) Help")
    }
}

/// The manual window. Add it to the App body beside the About window.
public struct SurfaceManualWindow: Scene {
    public static let id = "surface-manual"

    private let app: SurfaceApp
    private let folder: URL?

    /// `folder` defaults to the `Manual` folder bundled with the app.
    public init(app: SurfaceApp, folder: URL? = SurfaceManual.bundledFolder) {
        self.app = app
        self.folder = folder
    }

    public var body: some Scene {
        let title = "\(app.name) Help"
        return Window(title, id: Self.id) {
            SurfaceManualView(app: app, folder: folder)
                .surfaceNotRestored()
        }
        .defaultSize(width: 880, height: 620)
        .commandsRemoved()
    }
}
#endif
