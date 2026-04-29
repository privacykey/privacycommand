import Foundation

/// Fetches Apple's "App Privacy" / Privacy Nutrition Labels for a Mac
/// App Store app and parses them into structured form.
///
/// **The mechanism, in short.** When you load
/// `https://apps.apple.com/.../id<n>` in a browser, Apple ships a JSON
/// blob inline with the HTML — `<script id="serialized-server-data">`
/// — containing the page's data graph, including the privacy labels
/// the developer declared. Apple's own page renders the labels
/// client-side from this blob. We mimic that: fetch the page with a
/// realistic Safari User-Agent, extract the script body, and walk the
/// JSON.
///
/// **Why not the AMP API?** `amp-api.apps.apple.com` returns the same
/// data more cleanly but requires a bearer token that's embedded in
/// the App Store webpage's `<meta name="web-experience-app/config/environment">`
/// tag. Doing two round trips (page → token → AMP) is more code and
/// just as fragile to Apple changing the structure. The HTML scrape
/// is one round trip with a single failure surface, which is enough.
///
/// **Why this lives in Core, not the app target.** It's pure I/O over
/// `URLSession` plus JSON parsing — no AppKit, no SwiftUI. Keeping it
/// in Core means the same code works headlessly (CLI, future server
/// runner) without dragging the GUI into a worker process.
///
/// **Failure modes we surface explicitly.**
///  • `.rateLimited` — Apple's product-page endpoint enforces the
///    same rolling-minute limit as iTunes Search. We honour
///    `Retry-After`.
///  • `.noDetailsProvided` — the developer has not filled in privacy
///    labels yet. Apple shows a specific disclaimer in this case;
///    we detect it and bubble it up so the UI can render Apple's
///    actual copy instead of a generic empty state.
///  • `.parseFailure` — the page loaded but the JSON shape changed.
///    Logged with the relevant key for diagnostics.
public enum AppStorePrivacyLabelFetcher {

    public struct Result: Sendable {
        public let labels: PrivacyLabels?
        public let detailsStatus: AppStoreInfo.PrivacyDetailsStatus
        public let privacyPolicyURL: String?
    }

    public enum FetchError: Error, Sendable {
        case invalidURL
        case rateLimited(retryAfter: TimeInterval?)
        case http(status: Int)
        case noDetailsProvided
        case parseFailure(String)
        case network(String)
    }

    /// Fetch and parse privacy labels for an App Store product-page URL.
    ///
    /// - Parameters:
    ///   - urlString: The `trackViewUrl` returned by `AppStoreLookup`,
    ///     e.g. `https://apps.apple.com/us/app/xcode/id497799835`.
    ///     The URL host is validated — only `apps.apple.com` is
    ///     accepted, so a malformed Lookup response can't redirect
    ///     us to an internal-network host.
    ///   - timeout: Request timeout. The default of 15 seconds tracks
    ///     the iOSauditor scraper — App Store pages are ~500 KB and
    ///     occasionally slow to serve.
    public static func fetch(
        productPageURL urlString: String,
        timeout: TimeInterval = 15
    ) async throws -> Result {
        guard let url = URL(string: urlString),
              url.host?.lowercased() == "apps.apple.com" else {
            throw FetchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FetchError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.parseFailure("non-HTTP response")
        }

        // Apple uses 429 explicitly, but IP-based soft-throttling
        // arrives as 403. Treat both as rate-limit signals so the
        // caller can back off rather than mark the whole bundle as
        // permanently uncheckable.
        if http.statusCode == 429 || http.statusCode == 403 {
            let retryAfter = parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            throw FetchError.rateLimited(retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.http(status: http.statusCode)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw FetchError.parseFailure("non-UTF8 response body")
        }

        return try parse(html: html)
    }

    // MARK: - Parsing

    /// Pulls the `serialized-server-data` JSON out of the App Store
    /// HTML and walks it for privacy types + categories. Public so
    /// tests can feed it canned HTML without a network call.
    public static func parse(html: String) throws -> Result {
        let scriptBody = try extractSerializedServerData(from: html)
        let rootData = try parseJSONRoot(scriptBody)

        // Privacy policy URL — best-effort scrape from the visible
        // page markup, like iOSauditor does. Looks for an anchor
        // labelled by its ARIA "Developer's Privacy Policy" first
        // (the most stable selector), then falls back to a generic
        // "Privacy Policy" link.
        let privacyPolicyURL = extractPrivacyPolicyURL(html: html)

        // Try the modern shelf path first; fall back to the older
        // pageData layout. If neither has anything, check whether
        // Apple's "No Details Provided" disclaimer is on the page —
        // that's a positive answer too, just a different one.
        //
        // **Distinguishing "Data Not Collected" from "No Details
        // Provided".** Both states have a sparse payload, but they're
        // semantically opposite — the first is a developer's explicit
        // "we collect nothing", the second is "the developer hasn't
        // filled this in". The disambiguator is whether *any* privacy
        // type was declared:
        //   • One or more types parsed → `.provided`. That includes
        //     the lone-`DATA_NOT_COLLECTED` case, which has zero
        //     categories under it but is still a positive answer.
        //   • Zero types parsed but the disclaimer copy is on the
        //     page → `.noDetailsProvided`.
        //   • Zero types and no disclaimer → parse failure (Apple
        //     changed the layout).
        if let items = privacyTypeItems(in: rootData), !items.isEmpty {
            let labels = mapToPrivacyLabels(items: items)
            return Result(
                labels: labels,
                detailsStatus: .provided,
                privacyPolicyURL: privacyPolicyURL
            )
        }

        if hasNoDetailsCopy(html: html) {
            throw FetchError.noDetailsProvided
        }

        // Page parsed but no privacy data found. Likely a layout
        // change on Apple's side — surface as a parse failure so we
        // can update the parser, but don't pretend the developer
        // declared nothing.
        throw FetchError.parseFailure("privacyTypes shelf not found")
    }

    // MARK: - HTML extraction

    /// Find `<script id="serialized-server-data" ...>BODY</script>`.
    /// Apple's markup wraps the JSON in CDATA-ish fashion sometimes;
    /// we accept any inner text and let `JSONSerialization` reject
    /// malformed bodies.
    private static func extractSerializedServerData(from html: String) throws -> String {
        // Use NSRegularExpression — Swift's Regex literal is iOS 16+
        // / macOS 13+ and we want this to compile on a wider range.
        let pattern = #"<script[^>]*id="serialized-server-data"[^>]*>([\s\S]*?)</script>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            throw FetchError.parseFailure("regex compile failed")
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = re.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2,
              let bodyRange = Range(match.range(at: 1), in: html) else {
            throw FetchError.parseFailure("no serialized-server-data script")
        }
        return String(html[bodyRange])
    }

    /// Apple's payload is sometimes a top-level array, sometimes
    /// `{ data: [...], userTokenHash: ... }`. Normalise to the array
    /// form so the rest of the parser walks one shape.
    private static func parseJSONRoot(_ body: String) throws -> [Any] {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw FetchError.parseFailure("invalid serialized-server-data JSON")
        }
        if let arr = root as? [Any] { return arr }
        if let obj = root as? [String: Any], let arr = obj["data"] as? [Any] {
            return arr
        }
        throw FetchError.parseFailure("unexpected JSON root shape")
    }

    /// Walk the page-data graph for the privacy-types shelf, then
    /// fall back to older shapes. Returns the array of "privacy
    /// type" items (each has `identifier`, `title`, `detail`, and
    /// `categories`).
    private static func privacyTypeItems(in rootData: [Any]) -> [[String: Any]]? {
        guard let first = rootData.first as? [String: Any],
              let inner = first["data"] as? [String: Any] else {
            return nil
        }

        // Path 1 — modern `shelfMapping.privacyTypes.items`.
        if let shelf = inner["shelfMapping"] as? [String: Any],
           let pt = shelf["privacyTypes"] as? [String: Any],
           let items = pt["items"] as? [[String: Any]],
           !items.isEmpty {
            return items
        }

        // Path 2 — `privacyHeader.seeAllAction.pageData.shelves[]`
        // filtered by `contentType == "privacyType"`. Items here
        // sometimes use a nested `purposes → categories` shape that
        // we flatten in `mapToPrivacyLabels`.
        if let shelf = inner["shelfMapping"] as? [String: Any],
           let header = shelf["privacyHeader"] as? [String: Any],
           let seeAll = header["seeAllAction"] as? [String: Any],
           let pageData = seeAll["pageData"] as? [String: Any],
           let shelves = pageData["shelves"] as? [[String: Any]] {
            let collected = shelves
                .filter { ($0["contentType"] as? String) == "privacyType" }
                .flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
            if !collected.isEmpty { return collected }
        }

        // Path 3 — generic `pageData.shelves[]`.
        if let pageData = inner["pageData"] as? [String: Any],
           let shelves = pageData["shelves"] as? [[String: Any]] {
            let collected = shelves
                .filter { ($0["contentType"] as? String) == "privacyType" }
                .flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
            if !collected.isEmpty { return collected }
        }

        return nil
    }

    /// Convert Apple's raw item dicts into our `PrivacyLabels`
    /// structure. Handles both the flat `categories[]` shape and the
    /// nested `purposes[].categories[]` shape — for the latter we
    /// dedupe categories by identifier so a "Used for Analytics"
    /// purpose containing "Identifiers" doesn't double-count
    /// against "Used for App Functionality" → "Identifiers".
    private static func mapToPrivacyLabels(items: [[String: Any]]) -> PrivacyLabels {
        var types: [PrivacyLabels.PrivacyType] = []

        for item in items {
            let identifier = (item["identifier"] as? String) ?? ""
            let title = (item["title"] as? String) ?? ""
            let detail = (item["detail"] as? String) ?? ""

            var categoryMap: [String: PrivacyLabels.DataCategory] = [:]

            // Flat shape.
            if let cats = item["categories"] as? [[String: Any]] {
                for cat in cats {
                    if let id = cat["identifier"] as? String {
                        categoryMap[id] = PrivacyLabels.DataCategory(
                            identifier: id,
                            title: (cat["title"] as? String) ?? id
                        )
                    }
                }
            }

            // Nested shape.
            if let purposes = item["purposes"] as? [[String: Any]] {
                for purpose in purposes {
                    if let cats = purpose["categories"] as? [[String: Any]] {
                        for cat in cats {
                            if let id = cat["identifier"] as? String,
                               categoryMap[id] == nil {
                                categoryMap[id] = PrivacyLabels.DataCategory(
                                    identifier: id,
                                    title: (cat["title"] as? String) ?? id
                                )
                            }
                        }
                    }
                }
            }

            // Sort categories alphabetically by title for stable
            // rendering — Apple's order isn't guaranteed across
            // localisations.
            let categories = categoryMap.values
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

            types.append(PrivacyLabels.PrivacyType(
                identifier: identifier,
                title: title,
                detail: detail,
                categories: categories
            ))
        }

        // Order types by Apple's canonical severity, falling back to
        // raw order for anything unfamiliar.
        let canonicalOrder = PrivacyLabels.TypeIdentifier.displayOrder.map(\.rawValue)
        types.sort { lhs, rhs in
            let l = canonicalOrder.firstIndex(of: lhs.identifier) ?? Int.max
            let r = canonicalOrder.firstIndex(of: rhs.identifier) ?? Int.max
            return l < r
        }

        return PrivacyLabels(types: types)
    }

    /// Apple's "No Details Provided" disclaimer copy. Two phrasings
    /// have been observed in the wild; a single regex catches both.
    private static func hasNoDetailsCopy(html: String) -> Bool {
        let patterns = [
            #"No\s+Details\s+Provided"#,
            #"required\s+to\s+provide\s+privacy\s+details\s+when\s+they\s+submit"#
        ]
        for p in patterns {
            if html.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    /// Best-effort scrape of the developer's "Privacy Policy" link.
    /// Mirrors iOSauditor's three-stage match: ARIA-labelled anchor
    /// first, then the `notPurchasedLinks` section, then a global
    /// fallback. We don't sanitize aggressively here because callers
    /// hand the URL to a `<Link>`-style view, not to `WKWebView`
    /// or a shell command.
    private static func extractPrivacyPolicyURL(html: String) -> String? {
        let aria1 = #"<a\s+[^>]*?aria-label="Developer[’']s Privacy Policy"[^]*?href="([^"]+)""#
        let aria2 = #"<a\s+[^]*?href="([^"]+)"[^]*?aria-label="Developer[’']s Privacy Policy""#
        let section = #"id="notPurchasedLinks"[\s\S]*?<a\s+[^>]*?href="([^"]+)"[^>]*?>\s*Privacy Policy\s*</a>"#
        let fallback = #"<a\s+[^>]*?href="([^"]+)"[^>]*?>\s*Privacy Policy\s*</a>"#

        for pattern in [aria1, aria2, section, fallback] {
            if let url = firstCaptureGroup(in: html, pattern: pattern) {
                return url
            }
        }
        return nil
    }

    private static func firstCaptureGroup(in html: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let m = re.firstMatch(in: html, options: [], range: range),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: html) else {
            return nil
        }
        return String(html[r])
    }

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
