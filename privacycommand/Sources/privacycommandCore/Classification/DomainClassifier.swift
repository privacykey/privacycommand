import Foundation

// MARK: - Public types

public struct DomainClassification: Codable, Hashable, Sendable {
    public let category: Category
    /// The suffix pattern that matched, useful for an "explain why" tooltip.
    public let matchedPattern: String

    public init(category: Category, matchedPattern: String) {
        self.category = category
        self.matchedPattern = matchedPattern
    }

    public enum Category: String, Codable, Hashable, Sendable, CaseIterable {
        case apple
        case google
        case microsoft
        case meta
        case amazon
        case adTech
        case analytics
        case errorReporting
        case telemetry
        case cdn
        case payment
        case socialAuth
        case devTools
        case unknown

        public var label: String {
            switch self {
            case .apple:           return "Apple"
            case .google:          return "Google"
            case .microsoft:       return "Microsoft"
            case .meta:            return "Meta"
            case .amazon:          return "Amazon"
            case .adTech:          return "Ad / tracking"
            case .analytics:       return "Analytics"
            case .errorReporting:  return "Error reporting"
            case .telemetry:       return "Telemetry"
            case .cdn:             return "CDN"
            case .payment:         return "Payment"
            case .socialAuth:      return "Social auth"
            case .devTools:        return "Dev tools"
            case .unknown:         return "Unknown"
            }
        }

        public var systemImage: String {
            switch self {
            case .apple:           return "applelogo"
            case .google:          return "g.circle"
            case .microsoft:       return "square.grid.2x2"
            case .meta:            return "f.circle"
            case .amazon:          return "a.circle"
            case .adTech:          return "megaphone"
            case .analytics:       return "chart.bar"
            case .errorReporting:  return "ladybug"
            case .telemetry:       return "antenna.radiowaves.left.and.right"
            case .cdn:             return "globe.americas"
            case .payment:         return "creditcard"
            case .socialAuth:      return "person.badge.key"
            case .devTools:        return "hammer"
            case .unknown:         return "questionmark.circle"
            }
        }

        /// Knowledge-base article ID matching this category, e.g. "domain-analytics".
        public var kbArticleID: String { "domain-\(rawValue)" }
    }
}

// MARK: - Classifier

/// Maps a hostname (e.g. `api.segment.io`) to a category by walking a curated
/// list of suffix patterns. Patterns are matched against the lowercased host
/// in order; first match wins. Specific entries should appear before general
/// ones — e.g. `doubleclick.net` (ad tech) comes before `google.com` (Google).
///
/// Adding a domain: append to the right table below. The category table is
/// the single source of truth.
public struct DomainClassifier: Sendable {

    public init() {}

    public func classify(_ host: String) -> DomainClassification {
        let lower = host.lowercased()
        for entry in DomainClassifier.patterns {
            if lower == entry.pattern || lower.hasSuffix("." + entry.pattern) {
                return DomainClassification(category: entry.category, matchedPattern: entry.pattern)
            }
        }
        return DomainClassification(category: .unknown, matchedPattern: "")
    }

    // MARK: - Pattern table

    private struct Entry { let pattern: String; let category: DomainClassification.Category }

    /// Order matters: more-specific tracking domains come BEFORE the parent
    /// vendor (e.g. `doubleclick.net` is ad-tech, even though it's owned by
    /// Google).
    private static let patterns: [Entry] = [
        // ─── Ad / tracking — must come before parent vendors ────────────────
        .init(pattern: "doubleclick.net",            category: .adTech),
        .init(pattern: "googletagmanager.com",       category: .adTech),
        .init(pattern: "googleadservices.com",       category: .adTech),
        .init(pattern: "googlesyndication.com",      category: .adTech),
        .init(pattern: "adservice.google.com",       category: .adTech),
        .init(pattern: "adsystem.amazon.com",        category: .adTech),
        .init(pattern: "amazon-adsystem.com",        category: .adTech),
        .init(pattern: "facebook.com/tr",            category: .adTech), // simplified; suffix-match treats this as a literal host
        .init(pattern: "criteo.com",                 category: .adTech),
        .init(pattern: "criteo.net",                 category: .adTech),
        .init(pattern: "taboola.com",                category: .adTech),
        .init(pattern: "outbrain.com",               category: .adTech),
        .init(pattern: "adsrvr.org",                 category: .adTech),
        .init(pattern: "adnxs.com",                  category: .adTech),
        .init(pattern: "scorecardresearch.com",      category: .adTech),
        .init(pattern: "quantserve.com",             category: .adTech),

        // ─── Analytics / product-usage ──────────────────────────────────────
        .init(pattern: "google-analytics.com",       category: .analytics),
        .init(pattern: "analytics.google.com",       category: .analytics),
        .init(pattern: "segment.com",                category: .analytics),
        .init(pattern: "segment.io",                 category: .analytics),
        .init(pattern: "mixpanel.com",               category: .analytics),
        .init(pattern: "amplitude.com",              category: .analytics),
        .init(pattern: "rudderstack.com",            category: .analytics),
        .init(pattern: "snowplowanalytics.com",      category: .analytics),
        .init(pattern: "heap.io",                    category: .analytics),
        .init(pattern: "heapanalytics.com",          category: .analytics),
        .init(pattern: "hotjar.com",                 category: .analytics),
        .init(pattern: "fullstory.com",              category: .analytics),
        .init(pattern: "logrocket.com",              category: .analytics),
        .init(pattern: "smartlook.com",              category: .analytics),
        .init(pattern: "mouseflow.com",              category: .analytics),
        .init(pattern: "kissmetrics.com",            category: .analytics),
        .init(pattern: "pendo.io",                   category: .analytics),
        .init(pattern: "intercom.com",               category: .analytics),
        .init(pattern: "intercom.io",                category: .analytics),
        .init(pattern: "matomo.cloud",               category: .analytics),
        .init(pattern: "plausible.io",               category: .analytics),

        // ─── Error reporting / crash tracking ───────────────────────────────
        .init(pattern: "sentry.io",                  category: .errorReporting),
        .init(pattern: "ingest.sentry.io",           category: .errorReporting),
        .init(pattern: "rollbar.com",                category: .errorReporting),
        .init(pattern: "bugsnag.com",                category: .errorReporting),
        .init(pattern: "raygun.com",                 category: .errorReporting),
        .init(pattern: "raygun.io",                  category: .errorReporting),
        .init(pattern: "honeybadger.io",             category: .errorReporting),
        .init(pattern: "appcenter.ms",               category: .errorReporting),
        .init(pattern: "datadoghq.com",              category: .telemetry),
        .init(pattern: "newrelic.com",               category: .telemetry),
        .init(pattern: "loggly.com",                 category: .telemetry),
        .init(pattern: "papertrailapp.com",          category: .telemetry),
        .init(pattern: "splunkcloud.com",            category: .telemetry),

        // ─── Payment ────────────────────────────────────────────────────────
        .init(pattern: "stripe.com",                 category: .payment),
        .init(pattern: "stripe.network",             category: .payment),
        .init(pattern: "paypal.com",                 category: .payment),
        .init(pattern: "paypalobjects.com",          category: .payment),
        .init(pattern: "braintree-api.com",          category: .payment),
        .init(pattern: "squareup.com",               category: .payment),
        .init(pattern: "checkout.com",               category: .payment),
        .init(pattern: "klarna.com",                 category: .payment),
        .init(pattern: "afterpay.com",               category: .payment),

        // ─── Social auth / identity ─────────────────────────────────────────
        .init(pattern: "auth0.com",                  category: .socialAuth),
        .init(pattern: "okta.com",                   category: .socialAuth),
        .init(pattern: "oktapreview.com",            category: .socialAuth),
        .init(pattern: "onelogin.com",               category: .socialAuth),
        .init(pattern: "duo.com",                    category: .socialAuth),
        .init(pattern: "duosecurity.com",            category: .socialAuth),

        // ─── Dev tools ──────────────────────────────────────────────────────
        .init(pattern: "github.com",                 category: .devTools),
        .init(pattern: "githubusercontent.com",      category: .devTools),
        .init(pattern: "gitlab.com",                 category: .devTools),
        .init(pattern: "bitbucket.org",              category: .devTools),
        .init(pattern: "npmjs.org",                  category: .devTools),
        .init(pattern: "npmjs.com",                  category: .devTools),
        .init(pattern: "pypi.org",                   category: .devTools),
        .init(pattern: "rubygems.org",               category: .devTools),
        .init(pattern: "homebrew.bintray.com",       category: .devTools),
        .init(pattern: "githubcopilot.com",          category: .devTools),

        // ─── CDN ────────────────────────────────────────────────────────────
        .init(pattern: "cloudfront.net",             category: .cdn),
        .init(pattern: "fastly.net",                 category: .cdn),
        .init(pattern: "akamaiedge.net",             category: .cdn),
        .init(pattern: "akamaihd.net",               category: .cdn),
        .init(pattern: "akamai.net",                 category: .cdn),
        .init(pattern: "edgekey.net",                category: .cdn),
        .init(pattern: "edgesuite.net",              category: .cdn),
        .init(pattern: "jsdelivr.net",               category: .cdn),
        .init(pattern: "unpkg.com",                  category: .cdn),
        .init(pattern: "cdnjs.cloudflare.com",       category: .cdn),
        .init(pattern: "azureedge.net",              category: .cdn),

        // ─── First-party large vendors (after specific tracking entries) ────
        .init(pattern: "apple.com",                  category: .apple),
        .init(pattern: "icloud.com",                 category: .apple),
        .init(pattern: "icloud-content.com",         category: .apple),
        .init(pattern: "mzstatic.com",               category: .apple),
        .init(pattern: "cdn-apple.com",              category: .apple),
        .init(pattern: "itunes.com",                 category: .apple),
        .init(pattern: "applemusic.com",             category: .apple),
        .init(pattern: "ocsp.apple.com",             category: .apple),
        .init(pattern: "push.apple.com",             category: .apple),

        .init(pattern: "google.com",                 category: .google),
        .init(pattern: "googleapis.com",             category: .google),
        .init(pattern: "googleusercontent.com",      category: .google),
        .init(pattern: "gstatic.com",                category: .google),
        .init(pattern: "youtube.com",                category: .google),
        .init(pattern: "ytimg.com",                  category: .google),
        .init(pattern: "ggpht.com",                  category: .google),
        .init(pattern: "withgoogle.com",             category: .google),
        .init(pattern: "firebaseio.com",             category: .google),
        .init(pattern: "firebaseapp.com",            category: .google),

        .init(pattern: "microsoft.com",              category: .microsoft),
        .init(pattern: "msftncsi.com",               category: .microsoft),
        .init(pattern: "msft.net",                   category: .microsoft),
        .init(pattern: "live.com",                   category: .microsoft),
        .init(pattern: "office.com",                 category: .microsoft),
        .init(pattern: "office.net",                 category: .microsoft),
        .init(pattern: "outlook.com",                category: .microsoft),
        .init(pattern: "windows.net",                category: .microsoft),
        .init(pattern: "azurewebsites.net",          category: .microsoft),
        .init(pattern: "windowsazure.com",           category: .microsoft),

        .init(pattern: "facebook.com",               category: .meta),
        .init(pattern: "fbcdn.net",                  category: .meta),
        .init(pattern: "fbsbx.com",                  category: .meta),
        .init(pattern: "fb.me",                      category: .meta),
        .init(pattern: "instagram.com",              category: .meta),
        .init(pattern: "cdninstagram.com",           category: .meta),
        .init(pattern: "whatsapp.net",               category: .meta),
        .init(pattern: "whatsapp.com",               category: .meta),

        .init(pattern: "amazonaws.com",              category: .amazon),
        .init(pattern: "amazon.com",                 category: .amazon),
        .init(pattern: "ssl-images-amazon.com",      category: .amazon)
    ]
}
