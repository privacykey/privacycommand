import Foundation

/// Hits Apple's public iTunes Lookup API to convert a Mac App Store
/// bundle ID into the metadata we need for the rest of the pipeline:
/// the numeric `trackId`, the human-facing product-page URL, the
/// current store version, and a small bag of nice-to-haves (price,
/// genre, seller).
///
/// **What the API does and doesn't give us.** iTunes Lookup is the
/// stable, public, key-free endpoint Apple has documented for years.
/// It returns the same metadata the App Store search shows. It does
/// **not** include privacy nutrition labels — those only appear on
/// the actual product-page HTML, which `AppStorePrivacyLabelFetcher`
/// handles separately. We use Lookup as the cheap, reliable first
/// hop; the HTML scrape comes second.
///
/// **Rate-limit etiquette.** iTunes Lookup enforces an undocumented
/// per-IP rolling-minute limit (somewhere around 20 requests). We
/// don't currently batch — Auditor only looks up one app at a time —
/// but we honour `Retry-After` if Apple sends it and back off
/// gracefully on `429` responses. Failures here are non-fatal: the
/// caller falls back to "MAS app, no metadata yet".
public enum AppStoreLookup {

    public struct Result: Sendable {
        public let trackID: String
        public let trackViewURL: String
        public let storeName: String?
        public let sellerName: String?
        public let priceFormatted: String?
        public let genreName: String?
        public let storeVersion: String?
        public let storeVersionReleaseDate: String?
    }

    public enum LookupError: Error, Sendable {
        case invalidBundleID
        case rateLimited(retryAfter: TimeInterval?)
        case http(status: Int)
        case malformedResponse
        case notFound
        case network(String)
    }

    /// Query the Lookup endpoint for a Mac App Store bundle ID.
    ///
    /// - Parameters:
    ///   - bundleID: Reverse-DNS bundle identifier (`com.apple.dt.Xcode`).
    ///   - country: ISO 3166-1 alpha-2 storefront code. Apple's
    ///     metadata is region-specific, so a US-only app won't be
    ///     found in the AU storefront. Defaults to `"us"` because
    ///     it has the broadest catalog; the caller can override per
    ///     locale.
    ///   - timeout: How long to wait before giving up. The default
    ///     of 8 seconds is generous — Lookup typically responds in
    ///     under 500 ms.
    public static func lookup(
        bundleID: String,
        country: String = "us",
        timeout: TimeInterval = 8
    ) async throws -> Result {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(encoded)&entity=macSoftware&country=\(country)")
        else {
            throw LookupError.invalidBundleID
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // A plain Mac User-Agent — this endpoint is public, but
        // identifying ourselves by class avoids being mistaken for a
        // generic scraper bot when Apple tightens rate-limits.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LookupError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LookupError.malformedResponse
        }

        if http.statusCode == 429 {
            let retryAfter = parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            throw LookupError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LookupError.http(status: http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let entry = results.first
        else {
            throw LookupError.malformedResponse
        }

        // resultCount can be 0 for unknown bundle IDs even though the
        // request itself returned 200. Treat that as a normal "not
        // in the store" outcome so the caller can render a tidy
        // explanation rather than a generic error.
        let count = json["resultCount"] as? Int ?? results.count
        if count == 0 || entry.isEmpty {
            throw LookupError.notFound
        }

        guard let trackID = stringValue(entry["trackId"]) else {
            throw LookupError.malformedResponse
        }
        let trackViewURL = (entry["trackViewUrl"] as? String) ?? ""

        return Result(
            trackID: trackID,
            trackViewURL: trackViewURL,
            storeName: entry["trackName"] as? String,
            sellerName: entry["sellerName"] as? String ?? entry["artistName"] as? String,
            priceFormatted: entry["formattedPrice"] as? String,
            genreName: entry["primaryGenreName"] as? String,
            storeVersion: entry["version"] as? String,
            storeVersionReleaseDate: entry["currentVersionReleaseDate"] as? String
        )
    }

    // MARK: - Helpers

    /// `trackId` arrives as a JSON number; coerce to a string so the
    /// rest of the pipeline can pass it around without worrying about
    /// integer overflow on 32-bit fields.
    private static func stringValue(_ raw: Any?) -> String? {
        if let s = raw as? String, !s.isEmpty { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    /// Honours either the seconds-form or the HTTP-date form of
    /// `Retry-After`, capped at 10 minutes — anything bigger we'd
    /// rather time out and try later than block the UI on.
    private static func parseRetryAfter(_ raw: String?) -> TimeInterval? {
        guard let raw, !raw.isEmpty else { return nil }
        if let secs = TimeInterval(raw), secs > 0 {
            return min(secs, 600)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            let delta = date.timeIntervalSinceNow
            return delta > 0 ? min(delta, 600) : nil
        }
        return nil
    }
}
