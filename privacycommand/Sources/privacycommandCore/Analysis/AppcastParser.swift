import Foundation

// MARK: - Public types

public struct AppcastItem: Codable, Hashable, Sendable {
    public let title: String?
    public let shortVersionString: String?    // sparkle:shortVersionString — "4.5"
    public let buildVersion: String?          // sparkle:version — "4500"
    public let pubDate: Date?
    public let downloadURL: URL?
    public let length: Int64?                 // declared size in bytes
    public let contentType: String?
    public let releaseNotesHTML: String?
    public let minimumSystemVersion: String?

    public init(
        title: String?, shortVersionString: String?, buildVersion: String?,
        pubDate: Date?, downloadURL: URL?, length: Int64?, contentType: String?,
        releaseNotesHTML: String?, minimumSystemVersion: String?
    ) {
        self.title = title
        self.shortVersionString = shortVersionString
        self.buildVersion = buildVersion
        self.pubDate = pubDate
        self.downloadURL = downloadURL
        self.length = length
        self.contentType = contentType
        self.releaseNotesHTML = releaseNotesHTML
        self.minimumSystemVersion = minimumSystemVersion
    }
}

public struct Appcast: Codable, Hashable, Sendable {
    public let items: [AppcastItem]

    /// "Latest" by appcast convention is the first item (Sparkle inserts new
    /// items at the top). If items have pubDates we still respect the
    /// declared order — appcasts can publish older items below current for
    /// changelog purposes.
    public var latest: AppcastItem? { items.first }
}

// MARK: - Parser

/// Streaming XML parser that turns a Sparkle appcast (RSS 2.0 with the
/// `sparkle:` namespace) into `AppcastItem` instances.
///
/// Resilient by design: malformed items are skipped rather than failing the
/// whole feed. Empty fields are treated as nil.
public final class AppcastParser: NSObject {

    public static func parse(_ data: Data) -> Appcast {
        let p = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.shouldProcessNamespaces = false   // keep "sparkle:..." attribute keys intact
        parser.parse()
        return Appcast(items: p.items)
    }

    private var items: [AppcastItem] = []
    private var inItem = false
    private var collectingText = false
    private var currentText = ""

    // Per-item scratch
    private var currentTitle: String?
    private var currentVersion: String?
    private var currentBuildVersion: String?
    private var currentPubDate: Date?
    private var currentURL: URL?
    private var currentLength: Int64?
    private var currentType: String?
    private var currentReleaseNotes: String?
    private var currentMinSysVersion: String?

    private static let pubDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()
}

extension AppcastParser: XMLParserDelegate {

    public func parser(_ parser: XMLParser,
                       didStartElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?,
                       attributes attributeDict: [String : String] = [:]) {
        switch elementName {
        case "item":
            inItem = true
            currentTitle = nil
            currentVersion = nil
            currentBuildVersion = nil
            currentPubDate = nil
            currentURL = nil
            currentLength = nil
            currentType = nil
            currentReleaseNotes = nil
            currentMinSysVersion = nil

        case "enclosure":
            // The download URL + Sparkle-namespaced version attributes live
            // entirely on the enclosure tag.
            if let s = attributeDict["url"], !s.isEmpty {
                currentURL = URL(string: s)
            }
            // Some Sparkle appcasts put version on the enclosure, some put
            // it on a sibling element. Prefer enclosure when present.
            currentVersion       = currentVersion       ?? attributeDict["sparkle:shortVersionString"]
            currentBuildVersion  = currentBuildVersion  ?? attributeDict["sparkle:version"]
            currentLength        = currentLength        ?? attributeDict["length"].flatMap { Int64($0) }
            currentType          = currentType          ?? attributeDict["type"]

        case "title", "pubDate", "description", "content:encoded":
            collectingText = true
            currentText = ""

        case "sparkle:version":
            collectingText = true
            currentText = ""

        case "sparkle:shortVersionString":
            collectingText = true
            currentText = ""

        case "sparkle:minimumSystemVersion":
            collectingText = true
            currentText = ""

        case "sparkle:releaseNotesLink":
            collectingText = true
            currentText = ""

        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText { currentText.append(string) }
    }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if collectingText, let s = String(data: CDATABlock, encoding: .utf8) {
            currentText.append(s)
        }
    }

    public func parser(_ parser: XMLParser,
                       didEndElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "item":
            // Only emit if we have at least a download URL — otherwise the
            // item is unusable and we'd just produce a noisy nil-everything
            // entry.
            if let url = currentURL {
                items.append(AppcastItem(
                    title: currentTitle,
                    shortVersionString: currentVersion,
                    buildVersion: currentBuildVersion,
                    pubDate: currentPubDate,
                    downloadURL: url,
                    length: currentLength,
                    contentType: currentType,
                    releaseNotesHTML: currentReleaseNotes,
                    minimumSystemVersion: currentMinSysVersion
                ))
            }
            inItem = false

        case "title":
            if inItem { currentTitle = trimmed.isEmpty ? nil : trimmed }
            collectingText = false

        case "pubDate":
            if inItem {
                currentPubDate = Self.pubDateFormatter.date(from: trimmed)
            }
            collectingText = false

        case "description", "content:encoded":
            if inItem { currentReleaseNotes = trimmed.isEmpty ? nil : trimmed }
            collectingText = false

        case "sparkle:version":
            if inItem { currentBuildVersion = trimmed.isEmpty ? currentBuildVersion : trimmed }
            collectingText = false

        case "sparkle:shortVersionString":
            if inItem { currentVersion = trimmed.isEmpty ? currentVersion : trimmed }
            collectingText = false

        case "sparkle:minimumSystemVersion":
            if inItem { currentMinSysVersion = trimmed.isEmpty ? nil : trimmed }
            collectingText = false

        case "sparkle:releaseNotesLink":
            // Some appcasts use a link to the notes instead of inline. Stash
            // the URL as the "release notes" payload so the UI can show it.
            if inItem, !trimmed.isEmpty, currentReleaseNotes == nil {
                currentReleaseNotes = "Release notes: \(trimmed)"
            }
            collectingText = false

        default:
            break
        }
    }
}
