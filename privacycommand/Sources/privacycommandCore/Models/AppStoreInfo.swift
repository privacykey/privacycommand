import Foundation

/// Aggregated App Store information for a Mac App Store-distributed app:
/// metadata returned by the iTunes Lookup API plus the developer's
/// declared **Privacy Nutrition Labels** scraped from the product page.
///
/// All fields are optional because the data flows in stages — the Mac
/// App Store receipt detection happens during static analysis (no
/// network), and the actual lookup + privacy-label fetch are async.
/// A bundle-without-MAS-receipt won't have any of this; a fresh detect
/// before the network calls finish has only `isMASApp = true`. The
/// Dashboard's `PrivacyLabelsCard` reads this struct to render the
/// right state at each point.
public struct AppStoreInfo: Sendable, Hashable, Codable {
    /// True when `_MASReceipt/receipt` was found inside the bundle —
    /// the canonical proof that the user installed the bundle from
    /// the Mac App Store.
    public let isMASApp: Bool
    /// Bundle ID we'll feed to the iTunes Lookup endpoint.
    public let bundleID: String?
    /// Numeric Apple ID (the `id` in `apps.apple.com/app/.../id<n>`).
    public let trackID: String?
    /// `https://apps.apple.com/<country>/app/<slug>/id<trackID>` —
    /// where to send the user when they want the actual product page.
    public let trackViewURL: String?
    /// Locale-aware app name from iTunes Lookup.
    public let storeName: String?
    /// Apple-displayed seller, e.g. "Apple Inc.", "Microsoft Corporation".
    public let sellerName: String?
    /// Currently-listed price as a localised string ("$0.00", "Free").
    public let priceFormatted: String?
    /// Apple's primary genre name ("Productivity", "Social Networking").
    public let genreName: String?
    /// App version string from the lookup. Useful to compare against
    /// the on-disk `CFBundleShortVersionString` — a large gap means
    /// the user is running an old build.
    public let storeVersion: String?
    /// ISO-8601 release date of the current store version.
    public let storeVersionReleaseDate: String?
    /// Privacy labels scraped from the App Store HTML page. Nil when
    /// (a) we haven't fetched yet, (b) the developer declared
    /// "No Details Provided", or (c) the parse failed.
    public let privacyLabels: PrivacyLabels?
    /// "No Details Provided" 3-state flag — separate from
    /// `privacyLabels == nil` because Apple shows a specific
    /// disclaimer when the developer hasn't filled in the labels yet.
    public let privacyDetailsStatus: PrivacyDetailsStatus?
    /// Developer-supplied privacy policy URL scraped from the page.
    public let privacyPolicyURL: String?
    /// Set when the lookup or fetch failed in a way the user should
    /// know about. We deliberately don't promote network failures to
    /// big red errors — the Dashboard card just shows the issue
    /// inline.
    public let error: String?

    public init(
        isMASApp: Bool,
        bundleID: String? = nil,
        trackID: String? = nil,
        trackViewURL: String? = nil,
        storeName: String? = nil,
        sellerName: String? = nil,
        priceFormatted: String? = nil,
        genreName: String? = nil,
        storeVersion: String? = nil,
        storeVersionReleaseDate: String? = nil,
        privacyLabels: PrivacyLabels? = nil,
        privacyDetailsStatus: PrivacyDetailsStatus? = nil,
        privacyPolicyURL: String? = nil,
        error: String? = nil
    ) {
        self.isMASApp = isMASApp
        self.bundleID = bundleID
        self.trackID = trackID
        self.trackViewURL = trackViewURL
        self.storeName = storeName
        self.sellerName = sellerName
        self.priceFormatted = priceFormatted
        self.genreName = genreName
        self.storeVersion = storeVersion
        self.storeVersionReleaseDate = storeVersionReleaseDate
        self.privacyLabels = privacyLabels
        self.privacyDetailsStatus = privacyDetailsStatus
        self.privacyPolicyURL = privacyPolicyURL
        self.error = error
    }

    /// Most-common case: bundle isn't from the App Store at all.
    public static let notMAS = AppStoreInfo(isMASApp: false)

    public enum PrivacyDetailsStatus: String, Sendable, Hashable, Codable {
        /// Developer has filled in privacy labels.
        case provided
        /// Apple's "No Details Provided" disclaimer is on the page.
        case noDetailsProvided
        /// We couldn't decide either way (parse failure, etc.).
        case unknown
    }
}

// MARK: - PrivacyLabels

/// Apple's "App Privacy" / Privacy Nutrition Labels in structured form.
///
/// The shape mirrors what's on the App Store product page: each
/// `PrivacyType` represents one of the four severity categories (data
/// used to track you, data linked to you, etc.) and lists the
/// `DataCategory` items the developer declared underneath. Mac apps
/// reuse the iOS schema, so the identifiers (`DATA_USED_TO_TRACK_YOU`,
/// `DATA_LINKED_TO_YOU`, …) are identical across platforms.
public struct PrivacyLabels: Sendable, Hashable, Codable {
    public let types: [PrivacyType]

    public init(types: [PrivacyType]) {
        self.types = types
    }

    /// True when the developer made no declaration of any kind — i.e.
    /// Apple's payload contained zero privacy types.
    ///
    /// **This is different from "all types have zero categories".** A
    /// developer who declared `DATA_NOT_COLLECTED` (and nothing else)
    /// has made a *positive* statement that the app collects nothing.
    /// That state shows up as `types == [oneType]` with the lone type
    /// having an empty `categories` array — which is **not** empty in
    /// the sense of "no information". Use `isExplicitlyNotCollected`
    /// to distinguish it from "data is collected but no categories
    /// listed" (which shouldn't happen in well-formed Apple data, but
    /// we guard for it anyway).
    public var isEmpty: Bool {
        types.isEmpty
    }

    /// True when the *only* privacy type declared is `DATA_NOT_COLLECTED`
    /// — the App Store's positive "this app collects no data" answer.
    /// Distinct from `isEmpty` (no declaration at all) and from
    /// `noDetailsProvided` (developer hasn't filled in the form).
    public var isExplicitlyNotCollected: Bool {
        types.count == 1
            && types[0].identifier == TypeIdentifier.notCollected.rawValue
    }

    /// Convenience: the type for one of the four canonical identifiers,
    /// or nil if the developer didn't declare anything in that bucket.
    public func type(for identifier: TypeIdentifier) -> PrivacyType? {
        types.first { $0.identifier == identifier.rawValue }
    }
}

public extension PrivacyLabels {

    struct PrivacyType: Sendable, Hashable, Codable, Identifiable {
        public var id: String { identifier }
        /// Apple-stable identifier — `DATA_USED_TO_TRACK_YOU`,
        /// `DATA_LINKED_TO_YOU`, `DATA_NOT_LINKED_TO_YOU`,
        /// `DATA_NOT_COLLECTED`. Treat as opaque; new identifiers may
        /// appear without warning.
        public let identifier: String
        /// Locale-aware label as Apple shows it ("Data Used to Track
        /// You").
        public let title: String
        /// Apple's verbose explanation under the heading — sometimes
        /// empty.
        public let detail: String
        /// Data categories the developer declared in this bucket.
        public let categories: [DataCategory]

        public init(identifier: String, title: String, detail: String,
                    categories: [DataCategory]) {
            self.identifier = identifier
            self.title = title
            self.detail = detail
            self.categories = categories
        }
    }

    struct DataCategory: Sendable, Hashable, Codable, Identifiable {
        public var id: String { identifier }
        /// Apple-stable identifier — `LOCATION`, `IDENTIFIERS`,
        /// `USAGE_DATA`, `CONTACT_INFO`, `FINANCIAL_INFO`,
        /// `HEALTH_AND_FITNESS`, `SENSITIVE_INFO`, `USER_CONTENT`,
        /// `BROWSING_HISTORY`, `SEARCH_HISTORY`, `CONTACTS`,
        /// `PURCHASES`, `DIAGNOSTICS`, `OTHER`.
        public let identifier: String
        /// Locale-aware label ("Precise Location", "Identifiers", …).
        public let title: String

        public init(identifier: String, title: String) {
            self.identifier = identifier
            self.title = title
        }
    }

    /// The four canonical privacy-type identifiers Apple uses. Defined
    /// as an enum so call sites that want to look up a specific bucket
    /// don't have to hardcode strings.
    enum TypeIdentifier: String, CaseIterable, Sendable {
        case usedToTrack    = "DATA_USED_TO_TRACK_YOU"
        case linked         = "DATA_LINKED_TO_YOU"
        case notLinked      = "DATA_NOT_LINKED_TO_YOU"
        case notCollected   = "DATA_NOT_COLLECTED"

        /// Display ordering, most-severe first. Used by the UI when
        /// the source data isn't already in this order.
        public static let displayOrder: [TypeIdentifier] = [
            .usedToTrack, .linked, .notLinked, .notCollected
        ]
    }
}
