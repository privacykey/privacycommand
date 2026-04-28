import Foundation

// MARK: - Public types

public struct KnowledgeArticle: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    /// One- or two-sentence headline that appears at the top of the popover.
    public let summary: String
    /// Optional longer explanation. Newlines are honored. Keep under ~600 chars
    /// so it reads well in a 360pt-wide popover without scrolling.
    public let detail: String?
    /// Apple docs / authoritative reference, if any.
    public let learnMoreURL: URL?

    public init(id: String, title: String, summary: String,
                detail: String? = nil, learnMoreURL: URL? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.detail = detail
        self.learnMoreURL = learnMoreURL
    }
}

// MARK: - Lookup

/// Stable IDs that the static analyzer and risk scorer attach to findings.
/// Adding a new article: bump the table below; references resolve by string.
public enum KnowledgeBase {

    public static func article(id: String) -> KnowledgeArticle? {
        articles[id]
    }

    /// Best-effort lookup that also checks risk-contributor / finding category
    /// names. Useful when the source already carries a `category` string.
    public static func articleForCategory(_ category: String) -> KnowledgeArticle? {
        articles[category] ?? articles[normalize(category)]
    }

    /// All articles, sorted by title — backbone for the in-app browser.
    public static var allArticles: [KnowledgeArticle] {
        _allArticles.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Article groups for the browser sidebar. Order is editorial (most-used
    /// concepts first), not alphabetical.
    public static var groupedArticles: [(category: String, articles: [KnowledgeArticle])] {
        let buckets = Dictionary(grouping: allArticles) { Self.categoryName(for: $0.id) }
        let order: [String] = [
            "Findings & policies",
            "Risk scoring",
            "Privacy keys",
            "Entitlements",
            "App Transport Security",
            "Provenance",
            "Update mechanisms",
            "Open resources",
            "Path categories",
            "Network: domain categories",
            "Third-party SDKs",
            "Secrets & credentials",
            "Bundle integrity",
            "Compliance & system state",
            "Anti-analysis",
            "Behavioural anomalies",
            "Watch mode",
            "Kill switch",
            "VM isolation",
            "Resource monitoring",
            "Live probes",
            "Disassembly patterns",
            "Tools",
            "Other"
        ]
        return order.compactMap { name in
            guard let arts = buckets[name], !arts.isEmpty else { return nil }
            return (name,
                    arts.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
    }

    /// Bucket an article id into a human-friendly category name. Stable enough
    /// that adding new articles "just works" — assign a recognisable id
    /// prefix and you land in the right group.
    private static func categoryName(for id: String) -> String {
        if id.hasPrefix("privacy-")    { return "Privacy keys" }
        if id.hasPrefix("path-")       { return "Path categories" }
        if id.hasPrefix("domain-")     { return "Network: domain categories" }
        if id.hasPrefix("resource-")   { return "Open resources" }
        if id.hasPrefix("ats")         { return "App Transport Security" }
        if id.hasPrefix("com.apple.")  { return "Entitlements" }

        let updateIDs: Set<String> = [
            "sparkle", "squirrel-mac", "electron-updater", "devmate",
            "mac-app-store-updates", "custom-inferred", "update-preview"
        ]
        if updateIDs.contains(id) { return "Update mechanisms" }

        let provenanceIDs: Set<String> = [
            "provenance", "kMDItemWhereFroms", "com-apple-quarantine", "sha256-verification"
        ]
        if provenanceIDs.contains(id) { return "Provenance" }

        if id == "risk-score" { return "Risk scoring" }

        let toolIDs: Set<String> = ["reverse-engineering", "open-resources",
                                    "external-inspectors"]
        if toolIDs.contains(id) { return "Tools" }

        if id.hasPrefix("asm-")        { return "Disassembly patterns" }
        if id.hasPrefix("sdk-")        { return "Third-party SDKs" }
        if id.hasPrefix("secret-")     { return "Secrets & credentials" }
        if id.hasPrefix("antianalysis-") { return "Anti-analysis" }
        if id.hasPrefix("rpath-") || id == "bundle-signing-audit"
            || id == "embedded-launch-plist" || id == "privacy-claims-mismatch" {
            return "Bundle integrity"
        }
        if id.hasPrefix("behavior-")   { return "Behavioural anomalies" }
        if id == "privacy-manifest"
            || id == "sandbox-container"
            || id == "btm-overview"
            || id == "notarization-deep-dive" {
            return "Compliance & system state"
        }
        if id == "watch-mode" { return "Watch mode" }
        if id == "live-probes"
            || id == "probe-pasteboard"
            || id == "probe-camera"
            || id == "probe-microphone"
            || id == "probe-screen-recording" {
            return "Live probes"
        }
        if id == "kill-switch" || id == "network-kill-switch" { return "Kill switch" }
        if id == "guest-agent" || id == "vm-isolation" { return "VM isolation" }
        if id == "resource-monitor" { return "Resource monitoring" }
        if id == "usb-monitor" { return "Resource monitoring" }
        if id == "out-of-scope-paths" { return "Bundle integrity" }
        if id == "exec-summary" { return "Findings & policies" }

        // Findings emitted by the static analyzer / risk scorer (signing,
        // hardened-runtime, library-validation, automation, etc.) live here.
        return "Findings & policies"
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    // MARK: - Article table

    private static let articles: [String: KnowledgeArticle] = {
        var m: [String: KnowledgeArticle] = [:]
        for art in _allArticles { m[art.id] = art }
        return m
    }()

    /// The flat backing list. Renamed with a leading underscore so the
    /// public computed `allArticles` (which sorts) doesn't shadow / collide
    /// with this raw storage.
    private static let _allArticles: [KnowledgeArticle] = [

        // ─── Signing posture ────────────────────────────────────────────────

        .init(
            id: "code-signing",
            title: "Code signature does not validate",
            summary: "macOS verified the bundle’s signature and found it tampered with, mismatched, or missing required attributes. The app may have been modified after it was signed.",
            detail: "Apple Developer ID-signed apps include a cryptographic signature over their executable, frameworks, and resources. The signature is checked at launch and during Gatekeeper assessment. A failure usually means: the bundle was modified after signing (a binary patch, a swapped resource, an incomplete copy from a network share), the signature was stripped, or the bundle uses ad-hoc signing without proper attribution.\n\nIf you got the app from outside the Mac App Store, re-download it from the official source and try again before trusting it for sensitive tasks.",
            learnMoreURL: URL(string: "https://developer.apple.com/documentation/security/seeing_if_a_signature_is_valid")
        ),

        .init(
            id: "hardened-runtime",
            title: "Hardened Runtime is OFF",
            summary: "The app isn’t using Apple’s Hardened Runtime, which restricts code injection, library swapping, and JIT-compiled execution.",
            detail: "Hardened Runtime is required for notarization on modern macOS. An app without it has a wider attack surface: arbitrary dynamic libraries can be loaded, executable memory can be allocated and run, and the app’s own memory can be written to from outside.\n\nMost modern third-party apps enable it. Apple-signed system apps don’t need to set the flag explicitly.",
            learnMoreURL: URL(string: "https://developer.apple.com/documentation/security/hardened_runtime")
        ),

        .init(
            id: "notarization",
            title: "Bundle is not notarized",
            summary: "The app is signed but Apple has not reviewed it. Gatekeeper applies extra friction when launching it.",
            detail: "Apple’s notarization service does an automated security scan and counter-signs the app. Most Developer-ID-distributed apps are notarized. An app that’s only Developer-ID signed (without notarization) was either signed before notarization was required, hasn’t been resubmitted, or comes from a small / older publisher.\n\nThis isn’t conclusive evidence of risk on its own, but combined with other findings it’s worth weighing.",
            learnMoreURL: URL(string: "https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution")
        ),

        // ─── Entitlement-derived findings ───────────────────────────────────

        .init(
            id: "library-validation",
            title: "Library validation is disabled",
            summary: "The app declared `com.apple.security.cs.disable-library-validation`, allowing it to load dynamic libraries that aren’t signed by the same team or by Apple.",
            detail: "Common in Electron and plugin-host apps. It widens the attack surface: a malicious dylib placed on disk could be loaded by the app even if it isn’t signed by the publisher. By itself it isn’t evidence of malice, but it weakens the app’s integrity guarantee.\n\nIf the app doesn’t obviously need a plugin model, treat this as a yellow flag.",
            learnMoreURL: URL(string: "https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_cs_disable-library-validation")
        ),

        .init(
            id: "dyld-env",
            title: "DYLD environment variables permitted",
            summary: "The app allows the dynamic linker to be controlled via env vars (e.g. DYLD_INSERT_LIBRARIES). Anyone able to set this app’s environment can inject code into it.",
            detail: "Combined with disabled library validation, this is the classic library-injection attack surface. Apps that ship plug-ins, run their own debuggers, or rely on instrumentation sometimes need it. Most apps don’t.",
            learnMoreURL: URL(string: "https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_cs_allow-dyld-environment-variables")
        ),

        .init(
            id: "automation",
            title: "Apple Events automation: ANY app",
            summary: "The app declared `com.apple.security.automation.apple-events = true`, meaning it can drive any other application via AppleScript / Automator without per-target restrictions.",
            detail: "Apple Events let one app send commands to another (e.g. ‘tell application Mail to send a message…’). Apps that legitimately need this — backup tools, automation utilities — should normally enumerate the target bundle IDs they’ll talk to via `com.apple.security.temporary-exception.apple-events`. The wildcard form is broader than most apps need and worth understanding.\n\nThe user still has to grant permission per-target the first time it’s used; this entitlement just lets the app ASK.",
            learnMoreURL: URL(string: "https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_automation_apple-events")
        ),

        .init(
            id: "endpoint-security",
            title: "Endpoint Security client",
            summary: "The app holds `com.apple.developer.endpoint-security.client`, a high-trust entitlement that lets it observe other processes’ syscalls.",
            detail: "Apple grants this entitlement only to vetted security vendors. Tools that legitimately have it: Anti-malware products, EDR agents, audit tools (this one is one of them, in its production tier).\n\nIf you didn’t install this expecting a security tool, double-check what it is.",
            learnMoreURL: URL(string: "https://developer.apple.com/documentation/endpointsecurity")
        ),

        // ─── Privacy-key declarations ───────────────────────────────────────

        .init(
            id: "privacy-key-empty",
            title: "Privacy key with empty purpose string",
            summary: "The app declared a privacy permission (camera, microphone, etc.) but left the explanation string blank. macOS will show a sparse / generic prompt the first time the app asks for the resource.",
            detail: "Apple requires non-empty purpose strings for current SDK versions; older builds can ship blank ones. It isn’t evidence of malice, but it does mean the developer didn’t bother to tell users why they’re asking.",
            learnMoreURL: URL(string: "https://developer.apple.com/documentation/bundleresources/information_property_list/protected_resources")
        ),

        // ─── Inferred-API findings ──────────────────────────────────────────

        .init(
            id: "undeclared-api",
            title: "Sensitive API used but not declared",
            summary: "The binary references a privacy-sensitive framework or API (Contacts, Calendar, ScreenCaptureKit, etc.) but the bundle’s Info.plist doesn’t declare a matching purpose string.",
            detail: "Either the developer forgot the declaration (in which case macOS will reject the request at runtime and the feature won’t work), or the binary statically links the framework but doesn’t actually call the protected APIs. Either way it’s worth knowing.\n\nThe analyzer infers from a curated list of framework symbols and binary string scans — heuristic, not proof."
        ),

        .init(
            id: "unjustified-permission",
            title: "Permission declared but not used",
            summary: "The app asks for a permission (e.g. camera, location) but the analyzer didn’t find any reference to the matching API in the binary.",
            detail: "Possible explanations: the API is reached via a sub-bundle (XPC service or helper) that the analyzer hasn’t recursed into, the developer left an old purpose string in place after refactoring, or the permission is actually unused.\n\nDoesn’t prove anything on its own — just an inconsistency to be aware of."
        ),

        // ─── Dynamic findings ───────────────────────────────────────────────

        .init(
            id: "surprising-file-access",
            title: "Surprising file access",
            summary: "During the monitored run, the app touched paths the rule classifier flagged as unusual for it — typically high-value secrets like keychains, cookies, or ~/.ssh.",
            detail: "Each event names the rule that fired (e.g. R001-keychains). Hover the row in the Files tab to see the rule rationale. False positives happen — many editors index home-directory contents — so context matters."
        ),

        .init(
            id: "sensitive-file-access",
            title: "Sensitive file access",
            summary: "The app touched paths from a privacy-sensitive category (Photos, Calendar, Mail) without a matching declared privacy key, OR touched a removable/network volume.",
            detail: "Sensitive isn’t the same as surprising — it just means the data category is privacy-relevant. If the app legitimately works with that data and you’ve granted it permission, this is expected."
        ),

        .init(
            id: "surprising-network",
            title: "Surprising network endpoint",
            summary: "The app contacted a remote host or port that the rule classifier flagged as unusual for it.",
            detail: "Most frequently this fires on apps with explicit ad/analytics destinations or unexpected geographic endpoints. Polling-based — short-lived flows can be missed."
        ),

        .init(
            id: "many-hosts",
            title: "Many distinct remote hosts",
            summary: "The app contacted a large number of different remote hosts during the monitored run — much more than a typical productivity app.",
            detail: "Browsers, mail clients, and update services legitimately fan out to many hosts. For a focused-purpose utility, lots of hosts can suggest embedded analytics, telemetry, or a CDN-heavy backend."
        ),

        // ─── Risk score concept ─────────────────────────────────────────────

        .init(
            id: "risk-score",
            title: "How the risk score works",
            summary: "A 0–100 number that combines static-analysis signals with dynamic findings. Higher = more privacy-concerning.",
            detail: "Static contributions cover signing, declarations, entitlements, and inferred API usage. Dynamic contributions add observed file and network events. Each contributor has an explicit impact value visible in the contributors list — there’s no opaque ML model.\n\n• 0–19 Low\n• 20–49 Medium\n• 50–79 High\n• 80–100 Critical\n\nTweaking the thresholds or contributor weights only requires editing `RiskScorer.swift`."
        ),

        // ─── Privacy purpose strings ────────────────────────────────────────

        .init(
            id: "privacy-camera",
            title: "Camera",
            summary: "The app can request access to the built-in or external camera, including streaming video frames.",
            detail: "The first time the app calls AVFoundation's camera APIs, macOS shows a permission prompt with the developer's purpose string. You can revoke access later in System Settings → Privacy & Security → Camera.\n\nOnce granted, an app can capture stills, record video, and read raw frame buffers without further prompting."
        ),
        .init(
            id: "privacy-microphone",
            title: "Microphone",
            summary: "The app can request access to the system microphone and read audio samples in real time.",
            detail: "Granted access lets the app record audio at any time the app is running. macOS shows a small orange dot in the menu bar while the mic is active. Revoke at System Settings → Privacy & Security → Microphone."
        ),
        .init(
            id: "privacy-contacts",
            title: "Contacts",
            summary: "The app can read and (with full access) modify the user's address book — names, emails, phone numbers, organizations, related people.",
            detail: "Backed by the Contacts framework. Apps can fetch the full contact graph, including sensitive linked relationships. Revoke at System Settings → Privacy & Security → Contacts."
        ),
        .init(
            id: "privacy-calendar",
            title: "Calendar",
            summary: "The app can read events and (with full access) create or modify them in any calendar the user has connected.",
            detail: "Calendar events often contain sensitive content — meeting locations, attendees, confidential project names. macOS now distinguishes write-only access (NSCalendarsWriteOnlyAccessUsageDescription) for apps that just create events. Revoke at System Settings → Privacy & Security → Calendars."
        ),
        .init(
            id: "privacy-reminders",
            title: "Reminders",
            summary: "The app can read and (with full access) modify the user's Reminders lists.",
            detail: "Reminders sync via iCloud across devices. Treat content with similar sensitivity to calendar events. Revoke at System Settings → Privacy & Security → Reminders."
        ),
        .init(
            id: "privacy-photoLibrary",
            title: "Photos",
            summary: "The app can read images, videos, and metadata (location, time, faces) from the user's Photo Library.",
            detail: "Photo libraries often include EXIF GPS coordinates. Apps with read access see the entire library — there's no per-photo gate. Revoke at System Settings → Privacy & Security → Photos."
        ),
        .init(
            id: "privacy-photoLibraryAdd",
            title: "Photos (add only)",
            summary: "The app can add images and videos to the Photo Library but not read existing ones. A narrower form of Photos access.",
            detail: "Common for camera apps that save captures. Read access requires NSPhotoLibraryUsageDescription instead."
        ),
        .init(
            id: "privacy-location",
            title: "Location",
            summary: "The app can request the device's location at any time (or only while it's active in the foreground).",
            detail: "Location resolution can range from city-level (~5 km) to GPS-precise (~3 m) depending on permission level and hardware. Apps see Bluetooth, Wi-Fi, and GPS — anything they can use to triangulate. Revoke at System Settings → Privacy & Security → Location Services."
        ),
        .init(
            id: "privacy-bluetoothAlways",
            title: "Bluetooth",
            summary: "The app can scan for nearby Bluetooth devices and connect to peripherals — heart-rate monitors, headphones, beacons.",
            detail: "Beacons can be used to triangulate fine-grained indoor location, so this is also a partial location-disclosure vector. Revoke at System Settings → Privacy & Security → Bluetooth."
        ),
        .init(
            id: "privacy-bluetooth",
            title: "Bluetooth (legacy)",
            summary: "The legacy peripheral-scanning permission. Modern apps should use NSBluetoothAlwaysUsageDescription instead.",
            detail: "Behavior is similar to the modern key but is being phased out. Seeing this on a current app suggests an older Info.plist that was never updated."
        ),
        .init(
            id: "privacy-homeKit",
            title: "HomeKit",
            summary: "The app can control and observe the user's HomeKit accessories — locks, lights, cameras, sensors.",
            detail: "HomeKit access is often more sensitive than people realize: it includes camera feeds and door lock state. Revoke at System Settings → Privacy & Security → HomeKit."
        ),
        .init(
            id: "privacy-motion",
            title: "Motion",
            summary: "The app can read accelerometer, gyroscope, and pedometer data.",
            detail: "Less common on Mac than iOS. On Macs without motion hardware, apps requesting this are usually iOS apps running in Catalyst mode."
        ),
        .init(
            id: "privacy-speechRecognition",
            title: "Speech Recognition",
            summary: "The app can send audio to Apple's on-device or cloud speech-to-text service.",
            detail: "On modern macOS, recognition usually runs locally. Some apps fall back to network for accents or long-form transcription. Revoke at System Settings → Privacy & Security → Speech Recognition."
        ),
        .init(
            id: "privacy-mediaLibrary",
            title: "Media library",
            summary: "The app can access the user's Apple Music library, including playlists and listening history.",
            detail: "Distinct from Photos. Lets apps build music players, scrobble plays, or analyze listening habits. Revoke at System Settings → Privacy & Security → Media & Apple Music."
        ),
        .init(
            id: "privacy-appleEvents",
            title: "Apple Events / Automation",
            summary: "The app can drive other Mac apps via AppleScript / Automator (e.g. ‘tell Mail to send a message…’).",
            detail: "Each target app gets its own one-time prompt. Apps with NSAppleEventsUsageDescription can ask; they still need the user's permission per target. Revoke per-target at System Settings → Privacy & Security → Automation."
        ),
        .init(
            id: "privacy-automation",
            title: "Automation (System Events / accessibility-style)",
            summary: "The app uses inferred automation features beyond standard AppleEvents — typically AXIsProcessTrusted or System Events scripting.",
            detail: "Often overlaps with the Accessibility permission, which is much more powerful (the app can read on-screen text, observe keystrokes, and click anywhere). Inspect the Accessibility section of System Settings if this fires."
        ),
        .init(
            id: "privacy-desktopFolder",
            title: "Desktop folder",
            summary: "The app needs explicit consent to read/write files on the user's Desktop.",
            detail: "macOS treats Desktop, Documents, and Downloads as protected folders. Apps prompt the first time. Revoke at System Settings → Privacy & Security → Files and Folders."
        ),
        .init(
            id: "privacy-documentsFolder",
            title: "Documents folder",
            summary: "The app needs explicit consent to read/write files in ~/Documents.",
            detail: "Distinct from per-file access via the standard open/save dialogs (which doesn't require this). Revoke at System Settings → Privacy & Security → Files and Folders."
        ),
        .init(
            id: "privacy-downloadsFolder",
            title: "Downloads folder",
            summary: "The app needs explicit consent to read/write files in ~/Downloads.",
            detail: "Common for archivers and link-grabbers. Revoke at System Settings → Privacy & Security → Files and Folders."
        ),
        .init(
            id: "privacy-removableVolumes",
            title: "Removable volumes",
            summary: "The app can read/write files on USB sticks, SD cards, and other ejectable volumes.",
            detail: "Apps that handle photo imports, archives, or device backups often need this. Revoke at System Settings → Privacy & Security → Files and Folders."
        ),
        .init(
            id: "privacy-networkVolumes",
            title: "Network volumes",
            summary: "The app can read/write files on mounted SMB/AFP/NFS network shares.",
            detail: "Worth noticing if the app shouldn't reasonably need to talk to file servers."
        ),
        .init(
            id: "privacy-fileProviderDomain",
            title: "File Provider",
            summary: "The app implements an iCloud Drive-like provider — files appear in Finder but live elsewhere (Dropbox, OneDrive, custom cloud).",
            detail: "Granting this lets the provider intercept file operations. Apps doing this should be well-known cloud storage providers."
        ),
        .init(
            id: "privacy-localNetwork",
            title: "Local network",
            summary: "The app can discover and talk to other devices on the same Wi-Fi or wired LAN — printers, Chromecasts, IoT devices.",
            detail: "Required for Bonjour/mDNS-based discovery. Lets the app fingerprint your local network. Revoke at System Settings → Privacy & Security → Local Network."
        ),
        .init(
            id: "privacy-userTrackingTransparency",
            title: "User Tracking",
            summary: "The app can request the user's IDFA (advertising identifier) for cross-app tracking.",
            detail: "iOS-style App Tracking Transparency. Macs with this prompt mostly come from Catalyst apps. The user can revoke at System Settings → Privacy & Security → Tracking."
        ),
        .init(
            id: "privacy-focusStatus",
            title: "Focus status",
            summary: "The app can read whether the user has Focus / Do Not Disturb enabled.",
            detail: "Used by chat apps to silently suppress notifications. Limited disclosure surface."
        ),
        .init(
            id: "privacy-faceID",
            title: "Face ID",
            summary: "On Macs with Face ID hardware (very rare today), the app can request face authentication.",
            detail: "Only the system biometric prompt fires; the app never sees the face data itself. Most Macs use Touch ID instead, which doesn't require a usage description."
        ),

        // ─── Entitlement keys ───────────────────────────────────────────────

        .init(
            id: "com.apple.security.app-sandbox",
            title: "App Sandbox",
            summary: "The app declares it runs in Apple's sandbox — a least-privilege container that restricts file, network, and IPC access by default.",
            detail: "Required for apps in the Mac App Store. Inside the sandbox, an app can only reach resources it explicitly requested via other entitlements (e.g. files.user-selected.read-write for open dialogs). A Developer-ID-distributed app may run unsandboxed, with broader access — that's neither evidence of malice nor of safety on its own.",
            learnMoreURL: URL(string: "https://developer.apple.com/documentation/security/app_sandbox")
        ),
        .init(
            id: "com.apple.security.application-groups",
            title: "App Groups",
            summary: "The app shares a sandboxed container directory with other apps from the same developer, identified by a group ID.",
            detail: "Used to share preferences, caches, or files between an app and its extensions (Today widget, Share extension, helper). Doesn't grant access to other developers' data."
        ),
        .init(
            id: "com.apple.security.network.client",
            title: "Network: outgoing connections",
            summary: "The sandboxed app can initiate outgoing network connections (HTTP, HTTPS, custom TCP/UDP).",
            detail: "Almost every modern app has this. Without it, a sandboxed app can't reach the internet. Doesn't restrict WHERE the app connects to."
        ),
        .init(
            id: "com.apple.security.network.server",
            title: "Network: incoming connections",
            summary: "The sandboxed app can accept incoming network connections — listening on a port, hosting a service.",
            detail: "Less common. Required for apps that run a local web server, broadcast Bonjour services, or accept incoming peer-to-peer connections."
        ),
        .init(
            id: "com.apple.security.cs.allow-jit",
            title: "Allow JIT compilation",
            summary: "The hardened-runtime app can map memory pages as executable — needed for JavaScript engines, Wasm runtimes, and some emulators.",
            detail: "Browsers, Electron apps, and Java VMs require this. Combined with disable-library-validation it widens the attack surface; alone it's a calculated trade-off for performance."
        ),
        .init(
            id: "com.apple.security.cs.allow-dyld-environment-variables",
            title: "Allow DYLD environment variables",
            summary: "The hardened-runtime app honors DYLD_* environment variables, which control the dynamic linker and let callers inject code.",
            detail: "Combined with disable-library-validation, this is the classic library-injection attack surface. Reasonable for plug-in hosts and instrumentation tools; rarely needed otherwise."
        ),
        .init(
            id: "com.apple.security.cs.disable-library-validation",
            title: "Disable library validation",
            summary: "The hardened-runtime app can load dynamic libraries that aren't signed by the same team or Apple — the standard third-party plug-in escape hatch.",
            detail: "Common in Electron apps (which load Node native modules) and audio/video apps with plug-in ecosystems. Widens the attack surface."
        ),
        .init(
            id: "com.apple.security.automation.apple-events",
            title: "Apple Events automation (any app)",
            summary: "The sandboxed app can send AppleEvents to any other app, subject to per-target user prompts.",
            detail: "See the matching Privacy article for the user-permission flow. The narrower form `temporary-exception.apple-events` enumerates target bundle IDs and is preferred."
        ),
        .init(
            id: "com.apple.developer.endpoint-security.client",
            title: "Endpoint Security client",
            summary: "Apple-granted entitlement that lets a system extension observe file, process, and network syscalls — the foundation of modern EDR/anti-malware tools.",
            detail: "Apple manually vets each application. If you weren't expecting a security tool, double-check what this app is."
        ),
        .init(
            id: "com.apple.developer.networking.networkextension",
            title: "Network Extension",
            summary: "Apple-granted entitlement for content filters, packet tunnels, and on-demand VPN providers.",
            detail: "Common for VPN clients and corporate filtering tools. Apple also vets these. The specific value (content-filter-provider, packet-tunnel-provider, etc.) tells you what kind of network extension."
        ),
        .init(
            id: "com.apple.security.files.user-selected.read-write",
            title: "User-selected files (read/write)",
            summary: "The sandboxed app can read and write files the user explicitly opens or drops onto it.",
            detail: "The standard entitlement for document-based apps. The app doesn't get free access to the user's files — only ones it's been handed."
        ),
        .init(
            id: "com.apple.security.files.user-selected.read-only",
            title: "User-selected files (read-only)",
            summary: "The sandboxed app can read files the user explicitly opens, but not write to them.",
            detail: "Used by viewer-style apps."
        ),
        .init(
            id: "com.apple.security.files.downloads.read-write",
            title: "Downloads folder access",
            summary: "Sandbox entitlement for ~/Downloads. Distinct from the Privacy permission (which is the user-facing prompt) — this is the sandbox's static declaration.",
            detail: "Apps need both: this entitlement to even have the path on its capability map, and the Privacy permission for the OS to allow it."
        ),
        .init(
            id: "com.apple.security.files.documents.read-write",
            title: "Documents folder access",
            summary: "Sandbox entitlement for ~/Documents.",
            detail: "Same dual-key pattern as Downloads."
        ),
        .init(
            id: "com.apple.security.files.desktop.read-write",
            title: "Desktop folder access",
            summary: "Sandbox entitlement for ~/Desktop.",
            detail: "Same dual-key pattern as Downloads."
        ),
        .init(
            id: "com.apple.security.print",
            title: "Printing",
            summary: "The sandboxed app can send jobs to printers.",
            detail: "Trivial entitlement; rarely a concern."
        ),
        .init(
            id: "com.apple.developer.system-extension.install",
            title: "Install system extensions",
            summary: "The app can register system extensions (network filters, endpoint security, file providers).",
            detail: "Lets the app add code that runs at a higher trust level than user-space apps. The extension itself needs further Apple-granted entitlements."
        ),

        // ─── Path categories ────────────────────────────────────────────────

        .init(
            id: "path-userLibraryKeychains",
            title: "~/Library/Keychains",
            summary: "macOS Keychain databases. Apps shouldn't read these files directly — the supported path is the Security framework.",
            detail: "An app touching Keychain files raw is unusual and worth investigating. Even read access could let the app exfiltrate the encrypted blob for offline brute-forcing."
        ),
        .init(
            id: "path-userLibraryCookies",
            title: "~/Library/Cookies",
            summary: "Browser cookie storage. Apps reading or writing here are typically attempting to import or steal browser sessions.",
            detail: "Modern browsers encrypt cookies, but the encryption key is also accessible to apps with full disk access. Treat as a high-signal flag."
        ),
        .init(
            id: "path-userLibrarySSH",
            title: "~/.ssh",
            summary: "SSH private keys, known_hosts, and config. Among the most sensitive folders on the system.",
            detail: "An app reading from ~/.ssh is almost certainly either a developer tool you trust (terminal emulator, IDE, deployment tool) or a credential-stealing process. Verify before granting access."
        ),
        .init(
            id: "path-userLibraryMail",
            title: "~/Library/Mail",
            summary: "Apple Mail's local data store — message bodies, attachments, drafts.",
            detail: "An app that isn't your mail client reading from here is reading your email. Common for archivers and migration tools; rare otherwise."
        ),
        .init(
            id: "path-userLibraryMessages",
            title: "~/Library/Messages",
            summary: "iMessage / SMS chat history database.",
            detail: "Includes attachments and unique device-pairing keys. Treat as highly sensitive."
        ),
        .init(
            id: "path-userLibraryCalendar",
            title: "~/Library/Calendars",
            summary: "Local calendar event store. Reading here bypasses the EventKit prompt.",
            detail: "An app should normally use the Calendar framework, which goes through the OS permission gate. Direct file access is unusual."
        ),
        .init(
            id: "path-userLibraryContacts",
            title: "~/Library/Application Support/AddressBook",
            summary: "Local contacts database. Like Calendar, the supported access path is the Contacts framework.",
            detail: "Direct file reads bypass the permission prompt and aren't logged the same way. Worth noticing."
        ),
        .init(
            id: "path-userLibraryPhotos",
            title: "Photos library",
            summary: "Apple Photos data — image files, metadata database, generated thumbnails.",
            detail: "The Photos framework is the supported entrypoint. Apps reading raw library files often do so for backup or migration purposes."
        ),
        .init(
            id: "path-userLibrarySafari",
            title: "~/Library/Safari",
            summary: "Safari's bookmarks, history, favicons, web app data.",
            detail: "Useful for sync tools and history exporters. A generic utility reading here is suspicious."
        ),
        .init(
            id: "path-userLibraryContainers",
            title: "~/Library/Containers",
            summary: "Per-app sandbox container directories. Each sandboxed app has its own subfolder here.",
            detail: "An app reading another app's container is unusual — sandboxed apps can't see this without explicit grants. Reading its OWN container is normal."
        ),
        .init(
            id: "path-userLibraryAppSupport",
            title: "~/Library/Application Support",
            summary: "Where apps typically store user-level data — preferences, caches, projects.",
            detail: "Apps writing in their own subfolder is expected. Apps reading other vendors' subfolders is worth investigating (could be a backup tool, could be data theft)."
        ),
        .init(
            id: "path-userLibraryCaches",
            title: "~/Library/Caches",
            summary: "App caches that can be safely deleted by the system. Most apps write here freely.",
            detail: "Generally low-signal."
        ),
        .init(
            id: "path-userLibraryPreferences",
            title: "~/Library/Preferences",
            summary: "Per-app preference plists. Apps usually use the defaults system rather than touching these directly.",
            detail: "Reading other apps' preferences can reveal interesting state but isn't necessarily malicious."
        ),
        .init(
            id: "path-userDocuments",
            title: "~/Documents",
            summary: "User's primary document folder. Sandboxed apps need explicit permission; non-sandboxed apps don't.",
            detail: "Writing here is normal for document-based apps. Bulk reads by an app that doesn't open documents are worth a look."
        ),
        .init(
            id: "path-userDesktop",
            title: "~/Desktop",
            summary: "User's desktop folder.",
            detail: "Similar treatment to Documents."
        ),
        .init(
            id: "path-userDownloads",
            title: "~/Downloads",
            summary: "User's downloads folder.",
            detail: "Common target for archivers, link-grabbers, browser history readers."
        ),
        .init(
            id: "path-removableVolume",
            title: "Removable volume",
            summary: "USB drives, SD cards, external SSDs — anything you can eject.",
            detail: "Apps writing here without obvious reason warrant attention. Common for photo importers, backup tools, malware spreading via USB."
        ),
        .init(
            id: "path-networkVolume",
            title: "Network volume",
            summary: "Mounted SMB / AFP / NFS shares.",
            detail: "An app reaching out to a file server is worth understanding — backups, IT-managed share, or potential exfiltration target."
        ),
        .init(
            id: "path-temporary",
            title: "Temporary directory",
            summary: "/tmp, ~/Library/Caches, or DARWIN_USER_TEMP_DIR.",
            detail: "Most apps write here freely for transient state. The OS cleans these up periodically."
        ),
        .init(
            id: "path-systemReadOnly",
            title: "System (read-only)",
            summary: "/System, /usr, /Library — read-mostly system folders.",
            detail: "Reads are normal. Writes attempted here are usually rejected by SIP and indicate the app is misbehaving."
        ),
        .init(
            id: "path-bundleInternal",
            title: "Inside the app's own bundle",
            summary: "The app reading or writing files inside its own .app folder.",
            detail: "Normal — apps unpack assets, read resources, sometimes update their own helpers. Never a privacy concern."
        ),

        // ─── Domain categories ──────────────────────────────────────────────

        .init(
            id: "domain-apple",
            title: "Apple",
            summary: "Apple-operated infrastructure: iCloud, App Store, push notifications, OCSP certificate-revocation checks.",
            detail: "Most apps talk to apple.com / icloud.com domains for OS-level reasons (push tokens, software update checks, certificate validation). Generally not a privacy red flag, but worth noting which subdomain in case it's a less-expected service."
        ),
        .init(
            id: "domain-google",
            title: "Google",
            summary: "Google-operated services: APIs, Maps, Firebase, GSuite, YouTube, Fonts.",
            detail: "Many apps depend on Firebase or Google Maps. The connection alone doesn't say much — what specific subdomain (e.g. firebaseio.com vs maps.googleapis.com) tells you more about what's happening.",
            learnMoreURL: nil
        ),
        .init(
            id: "domain-microsoft",
            title: "Microsoft",
            summary: "Microsoft-operated services: Azure, Office 365, OneDrive, Live ID, Bing.",
            detail: "Apps integrating with Microsoft 365 or hosted on Azure naturally land here. Not concerning unless the app shouldn't reasonably be talking to Microsoft."
        ),
        .init(
            id: "domain-meta",
            title: "Meta (Facebook / Instagram / WhatsApp)",
            summary: "Meta-operated services: Facebook Login, social embeds, WhatsApp messaging, Instagram graph.",
            detail: "Worth a closer look — Facebook also operates Pixel-style tracking that fires from many third-party apps. If a non-social app reaches Meta domains, it's likely either user-initiated (login) or telemetry."
        ),
        .init(
            id: "domain-amazon",
            title: "Amazon",
            summary: "Amazon-operated services. Most often AWS-hosted backends; occasionally Amazon retail / advertising.",
            detail: "amazonaws.com is generic AWS hosting — could be any company's backend. Doesn't imply Amazon involvement beyond infrastructure."
        ),

        .init(
            id: "domain-adTech",
            title: "Advertising / tracking",
            summary: "Networks designed to track users across sites and apps to serve targeted ads.",
            detail: "Examples: doubleclick.net, criteo.com, adnxs.com, scorecardresearch.com. These domains exist primarily to identify users and build profiles. Seeing one in a desktop app you paid for is unusual; in an ad-supported app it's expected."
        ),
        .init(
            id: "domain-analytics",
            title: "Product analytics",
            summary: "Services that record what users do inside apps — page views, button clicks, feature usage.",
            detail: "Examples: Mixpanel, Segment, Amplitude, Heap, Pendo, Hotjar, FullStory, LogRocket. These can be benign aggregate metrics or detailed session replays — Hotjar/FullStory/LogRocket can record screen content. The product's privacy policy should disclose use."
        ),
        .init(
            id: "domain-errorReporting",
            title: "Crash / error reporting",
            summary: "Services that capture exceptions, stack traces, and breadcrumbs from running apps.",
            detail: "Examples: Sentry, Rollbar, Bugsnag, Raygun, Honeybadger. Generally low-risk — they collect crash data, not user content — but they do see app logs and metadata. Most reputable services let users opt out."
        ),
        .init(
            id: "domain-telemetry",
            title: "Operational telemetry",
            summary: "Logging and monitoring services that ingest application logs at scale — DataDog, New Relic, Loggly, Splunk.",
            detail: "Closer to error reporting in privacy implications. The data depends entirely on what the developer chose to log."
        ),
        .init(
            id: "domain-cdn",
            title: "Content delivery network",
            summary: "Edge caching infrastructure: Cloudfront, Fastly, Akamai, jsDelivr.",
            detail: "Hosts assets — images, JS, CSS — close to the user. Doesn't say anything about who owns the data; it's the upstream that matters. CDN connections are background noise in most reports."
        ),
        .init(
            id: "domain-payment",
            title: "Payment processor",
            summary: "Apps reaching Stripe, PayPal, Braintree, Square, Klarna typically do so during checkout flows.",
            detail: "Direct connections to these domains usually fire when the user is paying. If you see them outside that context, worth understanding why."
        ),
        .init(
            id: "domain-socialAuth",
            title: "Identity / social auth",
            summary: "Single-sign-on and identity providers: Auth0, Okta, OneLogin, Duo.",
            detail: "Common in enterprise apps. The connection means the app is delegating authentication; it doesn't expose your password to the app itself."
        ),
        .init(
            id: "domain-devTools",
            title: "Developer tools",
            summary: "GitHub, GitLab, npm, PyPI, RubyGems — package registries and source-control hosting.",
            detail: "Expected for IDEs, terminal apps, and package managers. Unexpected for a music player."
        ),
        .init(
            id: "domain-unknown",
            title: "Unknown",
            summary: "The classifier doesn't have a pattern matching this host. That doesn't make it suspicious — most company-specific backend hosts aren't in the curated list.",
            detail: "Adding a domain takes one line in DomainClassifier.swift's `patterns` table."
        ),

        // ─── Provenance ─────────────────────────────────────────────────────

        .init(
            id: "provenance",
            title: "Provenance",
            summary: "Where this copy of the app came from, captured by macOS at download time.",
            detail: "Two extended attributes on the bundle hold the data: `com.apple.metadata:kMDItemWhereFroms` records the URLs the file was downloaded from (direct URL + referrer page), and `com.apple.quarantine` records who downloaded it (Safari, Chrome, etc.) and when.\n\nNeither is cryptographically authoritative — both can be stripped — but they're high-signal hints that almost always survive normal install flows."
        ),
        .init(
            id: "kMDItemWhereFroms",
            title: "Download URL (kMDItemWhereFroms)",
            summary: "Extended attribute set by macOS when a file is saved from a network source. Stores the URL chain: typically the direct download URL plus the page the user clicked from.",
            detail: "If you see two URLs, the first is usually the .dmg or .zip the file was inside, and the second is the page that linked to it. A mismatch with the publisher's official site is a yellow flag — though many developers use CDN-hosted releases which legitimately don't match the marketing domain.\n\nThe attribute is preserved when the user drags the .app out of a .dmg into /Applications. It's stripped if the user manually removes it (`xattr -d com.apple.metadata:kMDItemWhereFroms <file>`)."
        ),
        .init(
            id: "com-apple-quarantine",
            title: "Gatekeeper quarantine",
            summary: "Extended attribute that marks files downloaded from the network. macOS uses it to apply Gatekeeper policy on first launch.",
            detail: "Format: `flags;timestamp;agent;uuid`. The agent is the app that downloaded the file (e.g. Safari, Google Chrome, Telegram). The timestamp tells you when. After the first successful launch of an app the flags update to record the user's approval.\n\nMissing quarantine usually means: the file was created locally (not downloaded), it was un-quarantined manually, or it was extracted from an archive that didn't propagate the attribute. None are inherently bad — but a missing attribute on something the user thinks they downloaded is worth a second look."
        ),
        .init(
            id: "sha256-verification",
            title: "SHA-256 verification",
            summary: "Cryptographic checksum of the main executable. Compare against a hash published by the developer to confirm the binary matches their release.",
            detail: "privacycommand computes the SHA-256 of `Contents/MacOS/<executable>` only — not the whole bundle, not the original .dmg. If the developer publishes a hash of their dmg/zip download, compute that file's hash separately (`shasum -a 256 file.dmg`) before comparing.\n\nWhat this CAN catch: a tampered binary swapped post-install. What this CANNOT catch on its own: the developer's signing key was compromised and a malicious signed build was published with its own valid hash."
        ),

        // ─── ATS ────────────────────────────────────────────────────────────

        .init(
            id: "ats",
            title: "App Transport Security",
            summary: "macOS / iOS framework that enforces TLS 1.2+ with forward secrecy on outgoing HTTPS by default. Apps can declare exceptions in Info.plist's `NSAppTransportSecurity` dictionary.",
            detail: "ATS doesn't apply when the app uses raw `Socket` / `BSD socket` APIs — only the high-level networking APIs. Many apps with arbitrary-loads exceptions still ship just to support legacy or self-signed servers, not to be sneaky.",
            learnMoreURL: URL(string: "https://developer.apple.com/documentation/bundleresources/information_property_list/nsapptransportsecurity")
        ),
        .init(
            id: "ats-arbitrary-loads",
            title: "ATS: arbitrary loads allowed",
            summary: "`NSAllowsArbitraryLoads = true` disables ATS globally — the app can connect over plain HTTP to any host.",
            detail: "Apple has tightened App Store review of this flag over the years. Outside the App Store it's still common, especially in apps that ship with embedded web content or browse the open web. Combined with disabled library validation it broadens the attack surface noticeably."
        ),
        .init(
            id: "ats-arbitrary-media",
            title: "ATS: arbitrary loads — media",
            summary: "`NSAllowsArbitraryLoadsForMedia = true` lets the app load media (video / audio) over plain HTTP, while keeping ATS enforced for non-media traffic.",
            detail: "Common in video player apps that legitimately play HTTP-served streams from older sources."
        ),
        .init(
            id: "ats-arbitrary-web",
            title: "ATS: arbitrary loads — web content",
            summary: "`NSAllowsArbitraryLoadsInWebContent = true` lets WKWebView and similar embedded browsers load HTTP content while keeping ATS enforced for the app's own traffic.",
            detail: "Browsers, RSS readers, and embedded web-content apps need this. Strangers don't."
        ),
        .init(
            id: "ats-local-networking",
            title: "ATS: local networking",
            summary: "`NSAllowsLocalNetworking = true` exempts unqualified hostnames and .local. addresses from ATS.",
            detail: "Required for apps that talk to printers, AirPlay devices, IoT hubs, and other LAN services. Doesn't enable internet-wide HTTP."
        ),
        .init(
            id: "ats-exception-domains",
            title: "ATS exception domains",
            summary: "Per-domain ATS exceptions in `NSExceptionDomains`. Each entry can allow insecure HTTP, lower the minimum TLS version, or disable forward secrecy for that domain only.",
            detail: "Narrower than a global arbitrary-loads exception. Worth scanning to see if any exception covers a domain you wouldn't expect — for instance, an analytics endpoint with `NSExceptionAllowsInsecureHTTPLoads = YES` is a yellow flag."
        ),

        // ─── Updates ────────────────────────────────────────────────────────

        .init(
            id: "sparkle",
            title: "Sparkle",
            summary: "Sparkle is the de-facto third-party auto-update framework for macOS apps distributed outside the Mac App Store.",
            detail: "It works by fetching an XML appcast from the URL declared in `Info.plist → SUFeedURL`, comparing the latest item's version with the installed bundle, and (with the user's consent) downloading the new release.\n\nModern Sparkle 2.x verifies the new download with an EdDSA signature whose public key is embedded in the bundle's Info.plist (`SUPublicEDKey`). Older releases used DSA signatures.",
            learnMoreURL: URL(string: "https://sparkle-project.org")
        ),
        .init(
            id: "mac-app-store-updates",
            title: "Mac App Store updates",
            summary: "Apps distributed through the Mac App Store update via the Store, not via Sparkle. Their bundle includes a `_MASReceipt/receipt` file.",
            detail: "privacycommand can't intercept App Store update flows — they're driven by the user's signed-in Apple ID and the Store app. The detection here is purely informational."
        ),
        .init(
            id: "update-preview",
            title: "Update preview",
            summary: "When the auditor finds a Sparkle feed it can fetch the latest release into a temp folder, run static analysis on it, and show you a diff vs. the version you have installed — without ever installing or launching the new build.",
            detail: "The flow:\n  1. Fetch the appcast XML over HTTPS.\n  2. Show you the latest item — version, size, release notes — and ask before downloading.\n  3. Download the .dmg or .zip into a temp folder.\n  4. Mount the DMG with `hdiutil -nobrowse -readonly -noautoopen` (no Finder mount) or unzip with `ditto`.\n  5. Locate the .app inside and run the same static analyzer used on the current bundle.\n  6. Discard the download — the new app is never moved into /Applications and never launched.\n\nUseful for spotting new entitlements, new contacted domains, or weakened signing posture before you click the developer's Update button.\n\nOnly Sparkle feeds are supported for preview today — other mechanisms have unstable or non-XML feeds."
        ),

        .init(
            id: "squirrel-mac",
            title: "Squirrel.Mac",
            summary: "GitHub's update framework, originally built for Atom and now used by some Electron and AppKit apps. Distinct from electron-updater (which is the more common modern choice).",
            detail: "Squirrel uses an HTTP JSON feed defined at runtime by the host app — there's no Info.plist key the auditor can read deterministically. We can detect the framework's presence in `Contents/Frameworks/Squirrel.framework` and surface that, but we can't safely fetch or preview the update.",
            learnMoreURL: URL(string: "https://github.com/Squirrel/Squirrel.Mac")
        ),
        .init(
            id: "electron-updater",
            title: "electron-updater",
            summary: "Update framework shipped with electron-builder. Used by most Electron-based macOS apps including Slack, VS Code, Discord, Spotify.",
            detail: "Configuration lives in `Contents/Resources/app-update.yml` next to the bundled JS. The yaml declares a `provider` (github / generic / s3 / spaces) and either a direct `url` to a feed or `owner` / `repo` for GitHub releases.\n\nThe auditor parses the yaml and surfaces the provider and feed URL when present. Preview download isn't supported because the on-the-wire format is electron-specific (latest-mac.yml / latest.yml) rather than RSS.",
            learnMoreURL: URL(string: "https://www.electron.build/auto-update")
        ),
        .init(
            id: "devmate",
            title: "DevMate (legacy)",
            summary: "Sparkle wrapper from MacPaw that hosted appcasts at devmate.com. Service shut down in 2018.",
            detail: "Apps that haven't migrated still have DevMateKit.framework in Contents/Frameworks/ and an `SUFeedURL` pointing at devmate.com — but the feed no longer responds. Effectively unmaintained software unless the developer migrated to vanilla Sparkle."
        ),
        .init(
            id: "custom-inferred",
            title: "Custom (inferred) update mechanism",
            summary: "The auditor didn't find a known framework, but it found update-shaped helpers or URLs in the app's binary. The detection is heuristic — treat the result as a hint, not a guarantee.",
            detail: "Triggers when:\n  • A helper app, login item, or framework has a name containing 'update' / 'updater' / 'autoupdate', OR\n  • The main executable's strings include URLs containing patterns like 'appcast', '/releases', 'latest.json', 'version.xml', etc.\n\nThe URL we surface is the most plausible feed-like URL we found. Many apps that auto-update via custom mechanisms don't publish a stable XML feed, so preview download is intentionally not offered for this kind."
        ),

        // ─── Open resources / Sloth-style ───────────────────────────────────

        .init(
            id: "open-resources",
            title: "Open resources",
            summary: "A snapshot of every file descriptor the target's process tree currently has open. Re-polled at ~1 Hz while a monitored run is active.",
            detail: "Implemented by running `lsof -p <pids>` (without `-i`) and parsing every row, regardless of fd type. Useful for spotting:\n  • Files an app keeps mapped (fonts, databases, license files).\n  • Pipes between the app and its helpers.\n  • Unix domain sockets exposing in-process services.\n  • Memory-mapped POSIX shared memory.\n\nSimilar to Sloth, but scoped to the inspected app rather than every process on the Mac.",
            learnMoreURL: URL(string: "https://github.com/sveinbjornt/Sloth")
        ),

        // ─── Reverse-engineering tools ──────────────────────────────────────

        .init(
            id: "reverse-engineering",
            title: "Reverse-engineering tools",
            summary: "privacycommand doesn't disassemble binaries itself, but it can hand the app's main executable off to a disassembler / RE tool you have installed.",
            detail: "Detected automatically:\n  • Hopper Disassembler, Cutter, Binary Ninja, Hex Fiend (under /Applications)\n  • radare2 / rizin / objdump / otool / Ghidra's `ghidraRun` (Homebrew or MacPorts paths, plus /Library/Developer/CommandLineTools/usr/bin)\n\nClick a button to launch the tool with the path to `Contents/MacOS/<executable>`. CLI tools open in Terminal.app via osascript. The auditor never modifies the bundle.\n\nFuture work could pipe Ghidra's headless analysis output back into the auditor's findings — that's not yet wired up; treat this section as a launchpad for now."
        ),

        // ─── Open-resource kinds ────────────────────────────────────────────

        .init(
            id: "resource-regularFile",
            title: "Regular file (REG)",
            summary: "An ordinary file — text, binary, image, database, anything stored on disk.",
            detail: "Most file descriptors an app holds are regular files: its own bundle resources, user documents it has open, caches, log files, embedded SQLite databases. Look at the path to understand whether it's expected.\n\nUnusual signs: a content-creation app holding `~/.ssh/id_rsa`; a chat app reading `~/Library/Mail`."
        ),
        .init(
            id: "resource-directory",
            title: "Directory (DIR)",
            summary: "An open directory — usually because the app is iterating its contents or watching for changes.",
            detail: "Holding a directory open is normal for FSEvents watchers, ‘Open Recent' menus, and live-search indexers."
        ),
        .init(
            id: "resource-pipe",
            title: "Pipe",
            summary: "An anonymous pipe — a one-way buffer used for inter-process communication, typically between an app and a child process it spawned.",
            detail: "Apps that shell out (calling `Process` or `popen` in C) get pipes for stdin/stdout/stderr of their child. Seeing two or three PIPEs per spawned helper is normal. Lots of pipes can mean lots of subprocess activity."
        ),
        .init(
            id: "resource-fifo",
            title: "FIFO (named pipe)",
            summary: "A pipe that exists on disk as a special file. Two unrelated processes can communicate by opening it by path.",
            detail: "Less common than anonymous pipes. Sometimes used for log streaming or by older Unix-style tools. The NAME column shows the path on disk."
        ),
        .init(
            id: "resource-unixSocket",
            title: "Unix domain socket",
            summary: "A bidirectional in-process or local-process socket. Used heavily by macOS for XPC, distributed notifications, ATS, and helper-app communication.",
            detail: "Almost every macOS app has multiple Unix sockets open — they're the substrate of XPC services, agent processes, system frameworks, and Notification Center. The NAME column shows either a path (e.g. `/tmp/...`) or `->` followed by the peer process if known."
        ),
        .init(
            id: "resource-ipv4Socket",
            title: "IPv4 network socket",
            summary: "A TCP or UDP socket using IPv4. NAME shows `local:port -> remote:port` for connected sockets, or `*:port` for listeners.",
            detail: "Same data the Network tab surfaces, but here you see all sockets including listeners and just-opened-not-yet-connected ones."
        ),
        .init(
            id: "resource-ipv6Socket",
            title: "IPv6 network socket",
            summary: "A TCP or UDP socket using IPv6. Modern apps use IPv6 alongside IPv4 transparently via the `getaddrinfo` resolver.",
            detail: "Behaviour mirrors IPv4. Whether you see IPv6 depends on your network — many home networks are IPv4-only and apps fall back."
        ),
        .init(
            id: "resource-characterDevice",
            title: "Character device (CHR)",
            summary: "An unbuffered I/O device — terminals, pseudo-tty endpoints, /dev/null, /dev/random, audio/video raw streams.",
            detail: "An app holding `/dev/null` is just suppressing output (very normal). Holding a `pty*` is normal for Terminal.app and SSH clients. Holding `/dev/random` / `/dev/urandom` is normal for crypto.\n\nSomething weird like an app holding the raw `/dev/disk*` would be unusual."
        ),
        .init(
            id: "resource-blockDevice",
            title: "Block device (BLK)",
            summary: "A buffered storage device — physical disks, partitions, disk images.",
            detail: "Rare for normal apps to open directly. Disk imaging utilities, partition editors, and Time Machine helpers do."
        ),
        .init(
            id: "resource-kqueue",
            title: "Kqueue",
            summary: "macOS / BSD's high-level event-notification mechanism. Apps register a kqueue with the kernel to be told when files change, sockets become readable, processes exit, etc.",
            detail: "Holding one or two kqueues is universal — every app using libdispatch or NSRunLoop has one under the hood. Lots of kqueues can hint at a heavy event-driven runtime."
        ),
        .init(
            id: "resource-event",
            title: "Event",
            summary: "Mach-port-backed event channels used by `os_log`, dispatch sources, and various kernel notifications.",
            detail: "Rarely interesting on its own — they're internal plumbing. Some Apple frameworks open many of these as part of their normal operation."
        ),
        .init(
            id: "resource-psxsem",
            title: "POSIX semaphore",
            summary: "A counted lock the app uses to coordinate access to a shared resource between processes or threads.",
            detail: "Common in apps that ship a daemon plus a UI — they use a named semaphore to ensure only one helper runs at a time."
        ),
        .init(
            id: "resource-psxshm",
            title: "POSIX shared memory",
            summary: "A region of memory mapped into multiple processes, used to share large buffers without copying.",
            detail: "Browsers, video editors, and any app with a multi-process architecture (especially Electron) often use shared memory for frame buffers and large message payloads. Shows up as `/<name>` in NAME."
        ),
        .init(
            id: "resource-other",
            title: "Other",
            summary: "An lsof TYPE we don't have a specific case for.",
            detail: "The raw type string is shown in the table. Common ‘other' values: NDRV (network driver), VNODE, SYSTM, INET (legacy)."
        ),

        .init(
            id: "resource-fd",
            title: "FD column",
            summary: "lsof's `FD` column — usually a number for explicit file descriptors, or a tag like `cwd`, `txt`, `mem`, `rtd`.",
            detail: "Common tags:\n  • `cwd` — the process's current working directory.\n  • `rtd` — its root directory (always `/` unless chrooted).\n  • `txt` — the executable text image of the process itself.\n  • `mem` — a memory-mapped file (libraries, fonts, databases mapped into RAM).\n  • Numbers (with `r`, `w`, `u` suffix) are open `read(2)`-able / `write(2)`-able file descriptors."
        ),

        // ─── Disassembly patterns ──────────────────────────────────────────

        .init(
            id: "asm-forensic-summary",
            title: "Forensic disassembly summary",
            summary: "An automated reading of the binary's disassembly that translates raw assembly into plain English by counting external API calls and embedded strings.",
            detail: "Reading raw `mov`/`add`/`bl` instructions is meaningless to most people. What matters is **what the binary asks the operating system to do** — and that's almost entirely visible at the boundary where it calls into shared libraries. Auditor extracts those external-call symbols (e.g. `_dlopen`, `_SecItemCopyMatching`, `_system`), categorises them by purpose (file I/O, networking, keychain, shell, etc.), and looks for combinations that match well-known patterns (stub launcher, malloc replacement, C++ exception machinery, keylogger smell, …).\n\nThis is **evidence, not proof**. A symbol being present means the code references it — not that it was actually called at runtime. Use the live monitored run to confirm behaviour."
        ),
        .init(
            id: "asm-stub-launcher",
            title: "Stub launcher binary",
            summary: "A small executable whose entire job is to load another framework via `dlopen`, look up an entry point with `dlsym`, and jump to it.",
            detail: "Common in browsers (Chrome / Edge / Brave), Electron apps, and any app that ships multiple sub-binaries that share one big native framework. The advantage is on-disk de-duplication and a faster cold-start — but it makes the auditable surface larger because the *real* code lives in a separate dylib that's only loaded at runtime. Static analysis of the stub itself almost always looks empty; you have to follow the `dlopen` to the actual framework.",
            learnMoreURL: URL(string: "https://man7.org/linux/man-pages/man3/dlopen.3.html")
        ),
        .init(
            id: "asm-partition-alloc",
            title: "PartitionAlloc-style malloc replacement",
            summary: "The binary walks every malloc zone via `_malloc_get_all_zones` and registers its own — a hardening / performance pattern shared by Chromium's PartitionAlloc, Firefox's mozjemalloc, and a few similar projects.",
            detail: "Replacing malloc gives the app:\n  • better cache locality and fragmentation\n  • optional safety hardening (guarded zones, freelist randomisation)\n  • coarse instrumentation hooks for telemetry\n\nIt is **not** by itself a red flag. The question to ask is whether the rest of the binary's behaviour matches what you'd expect from a browser-class app — because that's the typical reason to do this."
        ),
        .init(
            id: "asm-malloc-interception",
            title: "Custom malloc zone",
            summary: "The binary registers its own malloc zone with `_malloc_zone_register`, redirecting heap allocations through code it controls.",
            detail: "Legitimate uses include performance allocators (PartitionAlloc, mozjemalloc) and sanitizers (ASan, MSan). Less legitimate uses include hooking allocations for anti-debug tricks or telemetry. Cross-reference with the binary's stated purpose."
        ),
        .init(
            id: "asm-malloc",
            title: "malloc / free family",
            summary: "Standard C heap allocators. Calls to these are universal — every non-trivial native binary uses them.",
            detail: "Auditor surfaces these in the call table for completeness, but a high `malloc` count by itself is uninteresting. Pay attention only when paired with `_malloc_zone_register` (custom allocator) or `__cxa_throw` (allocator inside the C++ exception path)."
        ),
        .init(
            id: "asm-cpp-exceptions",
            title: "C++ exception machinery",
            summary: "Symbols like `__cxa_throw`, `__cxa_begin_catch`, and `_Unwind_RaiseException` are the C++ ABI runtime's `try`/`throw`/`catch` plumbing.",
            detail: "Their presence simply means the binary was compiled from C++ with exceptions enabled — which is the default for most native macOS and cross-platform apps. It is **not** a signal that the app is crashing or malfunctioning.\n\nAuditor still surfaces them because the unwind machinery is sometimes the most prominent thing in a stripped binary's symbol stub list, and users who don't recognise it can mistake it for something pathological.",
            learnMoreURL: URL(string: "https://itanium-cxx-abi.github.io/cxx-abi/abi-eh.html")
        ),
        .init(
            id: "asm-keychain",
            title: "Keychain access (Sec…Keychain APIs)",
            summary: "`SecItemCopyMatching` / `SecItemAdd` / `SecItemUpdate` / `SecItemDelete` are the modern Security-framework APIs for reading and writing keychain items.",
            detail: "Expected in:\n  • password managers and browsers\n  • email and chat clients\n  • any app that signs in to a remote service\n\nWorth scrutinising in apps that have no obvious reason to need stored credentials. Cross-reference with the entitlements (`com.apple.application-identifier` and `keychain-access-groups`) to see which keychain items the app is even allowed to touch."
        ),
        .init(
            id: "asm-shell",
            title: "system(3) / popen(3) — shell-command execution",
            summary: "Calling `system()` or `popen()` asks `/bin/sh` to interpret a string as a shell command.",
            detail: "Common in installers, dev tools, and build systems. Concerning in random user-facing apps because:\n  • the command is often built by concatenating runtime data, which is a classic command-injection vector\n  • shell execution bypasses sandboxing of the calling code\n  • an attacker who can influence the input can run arbitrary commands\n\nIf you see this in an app that has no obvious developer-tool purpose, look for the **string literals** that go with it — the actual command is often visible verbatim in the binary."
        ),
        .init(
            id: "asm-dlopen",
            title: "dlopen / dlsym — runtime library loading",
            summary: "`dlopen(3)` loads a shared library by path; `dlsym(3)` looks up a symbol inside it. Together they let a binary defer loading code until runtime.",
            detail: "Legitimate uses:\n  • plug-in architectures (Photoshop, VST hosts)\n  • stub launchers in multi-binary apps\n  • optional framework loading (Apple Silicon vs Intel paths)\n\nLess legitimate uses include loading dylibs from user-writable locations or hardcoded download paths — which lets an attacker substitute their own code. Look at the **string literals** near the call site to see *what* is being loaded.",
            learnMoreURL: URL(string: "https://man7.org/linux/man-pages/man3/dlopen.3.html")
        ),

        // ─── Updates ───────────────────────────────────────────────────────

        .init(id: "updates-overview", title: "How privacycommand updates itself",
              summary: "Updates are signed and ship through two parallel channels: a direct download (DMG with Sparkle 2 doing the in-app update) and a Homebrew Cask (where `brew upgrade` is the canonical path). The auditor never auto-checks unless you opt in via Settings → Updates; a manual 'Check for updates' button is always available.",
              detail: "**Direct downloads.** When you install from the DMG attached to a GitHub Release, Sparkle 2 polls https://privacykey.github.io/privacycommand/appcast.xml on the schedule you choose. Each entry in the feed is signed with an Ed25519 key whose public half is baked into the running app — Sparkle refuses to apply an update it can't verify. Background checks are off by default; you opt in via Settings → Updates.\n\n**Homebrew Cask.** When the bundle was installed via `brew install --cask privacycommand`, the running app detects the Caskroom path at launch and:\n  • disables Sparkle's automatic checks (so the app and `brew` aren't fighting over the on-disk version),\n  • greys out the auto-check toggle,\n  • shows a banner with the exact `brew upgrade --cask <name>` command.\n\nManual 'Check for updates' still works — knowing a new version exists is useful regardless of who's applying it.\n\n**What gets sent.** When auto-checks are on or you click the manual button, Sparkle issues a single GET against the appcast URL. Anonymous (no cookies, no fingerprint), and the only payload back is the signed XML feed — no telemetry, no install counts. If you decline the update, no further requests are made until the next scheduled tick.\n\n**Where the version lives.** `CFBundleShortVersionString` in Info.plist is the source of truth. The release pipeline refuses to publish if the git tag and the plist version disagree, so you can read either and trust them to match.\n\n**Where updates come from.** GitHub Releases attached to https://github.com/privacykey/privacycommand. The appcast feed is hosted on the project's `gh-pages` branch, served by GitHub Pages. See `docs/RELEASES.md` for the full release flow."),

        .init(id: "homebrew-managed-update", title: "Updates via Homebrew Cask",
              summary: "When privacycommand was installed via Homebrew, in-app updates are deliberately disabled — Homebrew's package manager owns the on-disk version, and Sparkle silently overwriting the bundle would break that contract.",
              detail: "The auditor detects the Caskroom path on launch (matching `/opt/homebrew/Caskroom/...` for Apple Silicon and `/usr/local/Caskroom/...` for Intel, plus any `HOMEBREW_CASKROOM` override). When matched, Settings → Updates substitutes a `brew upgrade --cask <name>` banner for the auto-update toggle.\n\n`brew update && brew upgrade --cask privacycommand` will pick up new versions. The cask's `livecheck` block points at the same appcast Sparkle uses, so cask users are never further behind than DMG users.\n\nIf you want to switch to in-app updates, `brew uninstall --cask privacycommand` followed by downloading the DMG from the GitHub Release page does the trick. The auditor will detect the new install path on next launch and re-enable Sparkle automatically."),

        // ─── App Store privacy labels ──────────────────────────────────────

        .init(id: "privacy-labels-overview", title: "Mac App Store privacy labels",
              summary: "The structured 'what data does this app collect?' declaration the developer was forced to fill in to ship the app through the Mac App Store. Auditor detects whether the bundle was installed from the App Store, looks the app up by its bundle ID, and fetches its privacy nutrition labels from apps.apple.com so you can compare what the developer claims against what the binary actually contains.",
              detail: "**How detection works.** A `Contents/_MASReceipt/receipt` file inside the bundle is the canonical proof that macOS installed the app from the Mac App Store — Apple writes the file at install time and a non-App-Store build of the same app won't have one. Auditor checks for the file's existence and reads the bundle's `CFBundleIdentifier` from `Info.plist`, no signature validation needed (Apple already validated it at install).\n\n**How the labels are fetched.** Two short network calls, both to public Apple endpoints:\n  • `https://itunes.apple.com/lookup?bundleId=<id>&entity=macSoftware` — Apple's stable, key-free lookup endpoint. Returns the numeric Apple ID, store name, seller, version, price, and product-page URL. Doesn't include privacy labels.\n  • `https://apps.apple.com/.../id<n>` — the actual product-page HTML. Apple ships the page's data graph inline as a `<script id=\"serialized-server-data\">` JSON blob, including the privacy types and categories the developer declared. Auditor walks that JSON.\n\nNo other data leaves your machine. The bundle ID is the only identifier transmitted — never the binary, the entitlements, or any user data.\n\n**The four buckets.** Apple groups declarations into:\n  1. **Data Used to Track You** — linked to advertising identifiers or sent to third parties for cross-site tracking. The most severe bucket.\n  2. **Data Linked to You** — collected and tied to your identity (account, device ID, name).\n  3. **Data Not Linked to You** — collected but stripped of identifying ties.\n  4. **Data Not Collected** — the explicit \"we don't take this\".\n\n**What to do with the data.** Cross-reference with the SDK fingerprints (Static tab → Telemetry & third-party SDKs) and the binary's hard-coded domains. A label that says \"Data Not Collected\" combined with an embedded analytics SDK is a strong indicator of a misrepresentation — Apple can pull an app for that, and it's the kind of finding worth raising with the vendor.\n\n**When labels are missing.** Three common reasons:\n  • Developer hasn't filled them in yet — Apple shows the \"No Details Provided\" disclaimer and gives the developer until their next submission to comply. We render Apple's actual copy in this case.\n  • App was pulled from the storefront — the lookup returns 0 results.\n  • Apple rate-limited us — they enforce a rolling-minute cap on these endpoints. Wait a minute and analyse the bundle again."),

        .init(id: "mas-receipt", title: "Mac App Store receipt",
              summary: "A `_MASReceipt/receipt` file inside the bundle's `Contents/` directory. Apple writes this CMS-signed PKCS#7 envelope at install time as proof of purchase; its presence is the canonical indicator that the app was distributed through the Mac App Store rather than as a Developer ID download.",
              detail: "Auditor doesn't validate the receipt's signature — Apple already did so at install. We read the file's existence + size as a sanity check, and lift the bundle ID from `Info.plist` for the App Store lookup that follows.\n\nIf you copy a `.app` bundle from one Mac to another, the receipt is part of the bundle and travels with it. macOS will refuse to launch a copied receipt-bearing bundle on a different Apple ID without revalidation, so the receipt's mere presence doesn't mean the *running user* purchased the app — only that *someone* did, on the machine that originally installed it.\n\nSee Apple's \"Receipt Validation Programming Guide\" for the receipt format itself; we surface it as a binary signal, not a parsed structure."),

        // ─── Telemetry overview ─────────────────────────────────────────────

        .init(id: "telemetry-overview", title: "Embedded telemetry",
              summary: "How many analytics, advertising, and attribution SDKs the bundle ships — the platforms whose entire purpose is to observe user behaviour and ship it off-device. Highlighted on the Dashboard so the headline answer to 'is this app spying on me?' is one glance away.",
              detail: "Auditor splits third-party SDKs into two tiers:\n\n  • **Tracking SDKs** — analytics (Firebase Analytics, Mixpanel, Amplitude, Segment, Heap, PostHog…), ad networks (AdMob, Meta Audience Network, AppLovin, Unity Ads, ironSource), and install-attribution platforms (AppsFlyer, Adjust, Branch, Kochava, Singular). These exist to measure or monetise users' behaviour. Their presence is the strongest static-analysis signal that an app is built for surveillance.\n\n  • **Supporting SDKs** — crash reporters (Crashlytics, Sentry, Bugsnag), customer-support widgets (Intercom, Zendesk), authentication (Auth0, Okta), payments (Stripe, RevenueCat), push (FCM, OneSignal, Airship), feature-flag systems (LaunchDarkly, Optimizely), and loggers. These send data off-device too, but with weaker privacy implications: a crash report or a payment doesn't profile you.\n\nThe Dashboard card counts only the *tracking* tier and uses a heat-graded colour: green (zero), yellow (1), orange (2–3), red (4+). The full list lives in the Static tab's 'Telemetry & third-party SDKs' section, where the supporting SDKs are also enumerated.\n\n**What the count doesn't tell you:**\n  • Whether each SDK is actually *active*. An app can ship Firebase Analytics and never call it. Cross-reference with the dynamic monitor's network destinations to confirm runtime traffic.\n  • Hand-rolled tracking code without an SDK fingerprint. Some apps build their own telemetry — those slip through this scanner. Look at the hard-coded domains list and the dynamic monitor's network hits if you suspect it.\n  • What each SDK *transmits*. The breakdown stops at category. The KB article for each individual SDK lists default events, identifiers, and network destinations."),

        // ─── Third-party SDKs ───────────────────────────────────────────────
        // The `sdk-trackers` article is the umbrella explainer; per-SDK
        // articles add vendor-specific colour but reuse the same framing.

        .init(
            id: "sdk-trackers",
            title: "Tracker-class SDKs",
            summary: "Analytics, advertising, attribution, A/B-testing, push, and engagement SDKs that send user-derived data off the device. We call this set 'tracker-class' because they all transmit identifiers or behaviour to third-party servers, even when the developer doesn't realise.",
            detail: "Apple's Privacy Labels and Privacy Manifests are supposed to make this list visible — but they only describe what the developer *says* the app does, and they aren't audited. By matching the artefacts an SDK leaves behind in the bundle (a framework directory, a sub-bundle ID, a hard-coded URL, a giveaway symbol name), Auditor produces an objective list independent of the developer's claims.\n\nIMPORTANT: a hit means the SDK is *present*, not necessarily *active*. Use the live monitored run to confirm whether the SDK actually phones home. Conversely, an SDK that's been statically linked from source may not match any framework / bundle-ID fingerprint — so absence of hits doesn't prove absence of trackers."
        ),

        // Analytics ----------------------------------------------------------
        .init(id: "sdk-firebase-analytics", title: "Firebase Analytics",
              summary: "Google's app analytics SDK. Tracks user events, sessions, demographics, and uploads them to Google's servers.",
              detail: "Originally Google Analytics for Firebase. Default events captured include `first_open`, `session_start`, `screen_view`, and any custom events the developer instruments. Identifiers transmitted include the Firebase install ID and (subject to App Tracking Transparency) IDFA. Network destinations: `app-measurement.com`, `firebaseinstallations.googleapis.com`.",
              learnMoreURL: URL(string: "https://firebase.google.com/docs/analytics")),
        .init(id: "sdk-google-analytics", title: "Google Analytics (legacy)",
              summary: "Google's legacy Universal Analytics SDK; superseded by Firebase Analytics in 2023.",
              detail: "Presence in a recently-built app is unusual — it's been deprecated for several years."),
        .init(id: "sdk-mixpanel", title: "Mixpanel",
              summary: "Product-analytics platform. Tracks user funnels, retention, and custom events.",
              learnMoreURL: URL(string: "https://docs.mixpanel.com/")),
        .init(id: "sdk-amplitude", title: "Amplitude",
              summary: "Product analytics — feature usage, cohort analysis, experimentation.",
              learnMoreURL: URL(string: "https://www.docs.developers.amplitude.com/")),
        .init(id: "sdk-segment", title: "Segment",
              summary: "Customer-data pipeline. The app sends events to Segment, which forwards them to dozens of downstream destinations (analytics, advertising, CRM).",
              detail: "Segment's value is fan-out — one SDK integration replaces many. The flip side is that you can't see which downstream tools actually receive each event without inspecting the Segment dashboard."),
        .init(id: "sdk-heap", title: "Heap",
              summary: "Auto-capture analytics. Records every UI interaction without explicit instrumentation."),
        .init(id: "sdk-posthog", title: "PostHog",
              summary: "Open-source product analytics. Self-hostable; otherwise sends events to PostHog Cloud."),
        .init(id: "sdk-matomo", title: "Matomo",
              summary: "Privacy-friendly, self-hostable analytics (formerly Piwik)."),

        // Advertising --------------------------------------------------------
        .init(id: "sdk-admob", title: "Google AdMob",
              summary: "Google's mobile advertising network. Ad impressions, clicks, and ad-targeting identifiers go to Google.",
              learnMoreURL: URL(string: "https://developers.google.com/admob/ios")),
        .init(id: "sdk-meta-audience-network", title: "Meta Audience Network",
              summary: "Meta's mobile ad network. Brings Facebook/Instagram targeting data to ads served inside third-party apps."),
        .init(id: "sdk-applovin", title: "AppLovin MAX",
              summary: "Mobile ad mediation platform. Routes ad requests to multiple ad networks."),
        .init(id: "sdk-unity-ads", title: "Unity Ads",
              summary: "Unity's video-ad network for game monetization."),
        .init(id: "sdk-ironsource", title: "ironSource",
              summary: "Mobile ad mediation and monetization SDK."),

        // Attribution --------------------------------------------------------
        .init(id: "sdk-appsflyer", title: "AppsFlyer",
              summary: "Mobile-marketing attribution. Tracks which ad campaign / referrer led to an install or purchase."),
        .init(id: "sdk-adjust", title: "Adjust",
              summary: "Mobile attribution and lifecycle analytics."),
        .init(id: "sdk-branch", title: "Branch",
              summary: "Deep linking and mobile attribution. Reconstructs cross-app user journeys."),
        .init(id: "sdk-kochava", title: "Kochava",
              summary: "Mobile attribution and audience-building."),
        .init(id: "sdk-singular", title: "Singular",
              summary: "Marketing analytics and attribution platform."),

        // Crash reporting ----------------------------------------------------
        .init(id: "sdk-crashlytics", title: "Firebase Crashlytics",
              summary: "Crash and error reporting from Google. Symbolicates crashes and groups them by signature.",
              detail: "Generally low privacy concern by itself — payloads are stack traces, OS version, and device class. Becomes more invasive when paired with Firebase Analytics on the same project."),
        .init(id: "sdk-sentry", title: "Sentry",
              summary: "Application error monitoring and performance tracing.",
              learnMoreURL: URL(string: "https://docs.sentry.io/platforms/apple/")),
        .init(id: "sdk-bugsnag", title: "Bugsnag",
              summary: "Error monitoring SDK from SmartBear."),
        .init(id: "sdk-appcenter", title: "Visual Studio App Center",
              summary: "Microsoft's mobile DevOps stack — crashes, analytics, and beta distribution."),
        .init(id: "sdk-raygun", title: "Raygun",
              summary: "Error and performance monitoring."),

        // Performance --------------------------------------------------------
        .init(id: "sdk-datadog-rum", title: "Datadog RUM",
              summary: "Real-user monitoring — performance traces, errors, and session replays sent to Datadog."),
        .init(id: "sdk-newrelic", title: "New Relic Mobile",
              summary: "Mobile application performance monitoring (APM)."),
        .init(id: "sdk-instabug", title: "Instabug",
              summary: "In-app bug reporting, performance monitoring, and surveys."),

        // Customer support ---------------------------------------------------
        .init(id: "sdk-intercom", title: "Intercom",
              summary: "In-app customer-support and messaging widget."),
        .init(id: "sdk-zendesk", title: "Zendesk",
              summary: "Customer-support and help-centre SDK."),
        .init(id: "sdk-helpshift", title: "Helpshift",
              summary: "In-app help / support SDK."),

        // Auth ---------------------------------------------------------------
        .init(id: "sdk-auth0", title: "Auth0 (Okta)",
              summary: "OAuth / OpenID-Connect authentication-as-a-service."),
        .init(id: "sdk-firebase-auth", title: "Firebase Authentication",
              summary: "Firebase's user-authentication SDK (email, OAuth providers, phone)."),
        .init(id: "sdk-okta", title: "Okta",
              summary: "Enterprise SSO / OIDC SDK."),

        // Monetization -------------------------------------------------------
        .init(id: "sdk-revenuecat", title: "RevenueCat",
              summary: "Subscriptions and in-app-purchase backend.",
              detail: "Receipts and subscription state sync to RevenueCat's servers; user identifiers may be sent depending on configuration."),
        .init(id: "sdk-stripe", title: "Stripe",
              summary: "Payments SDK. Card and Apple Pay processing via Stripe's API."),
        .init(id: "sdk-braintree", title: "Braintree",
              summary: "PayPal-owned payments SDK."),

        // Push ---------------------------------------------------------------
        .init(id: "sdk-fcm", title: "Firebase Cloud Messaging",
              summary: "Google's push-notification service. Apple delivers the actual notification, but the FCM token is also sent to Google."),
        .init(id: "sdk-onesignal", title: "OneSignal",
              summary: "Push and in-app notification platform."),
        .init(id: "sdk-airship", title: "Airship",
              summary: "Customer-engagement platform — push, in-app messaging, automation. Was 'Urban Airship'."),
        .init(id: "sdk-iterable", title: "Iterable",
              summary: "Cross-channel marketing automation (push, email, SMS, in-app)."),

        // A/B testing --------------------------------------------------------
        .init(id: "sdk-optimizely", title: "Optimizely",
              summary: "Feature-flagging and experimentation platform."),
        .init(id: "sdk-launchdarkly", title: "LaunchDarkly",
              summary: "Feature-flag platform. Decides feature visibility per user via remote rules."),
        .init(id: "sdk-firebase-remote-config", title: "Firebase Remote Config",
              summary: "Server-driven configuration and A/B-testing for apps."),

        // Logging ------------------------------------------------------------
        .init(id: "sdk-cocoalumberjack", title: "CocoaLumberjack",
              summary: "Logging framework for Cocoa apps. Local file logging — does not by itself transmit data.",
              detail: "Worth flagging only because logs sometimes get attached to bug reports that *do* transmit. The library itself is benign."),

        // Feedback -----------------------------------------------------------
        .init(id: "sdk-sprig", title: "Sprig (UserLeap)",
              summary: "In-app surveys and user-research."),
        .init(id: "sdk-braze", title: "Braze",
              summary: "Customer-engagement platform — push, in-app, email, content cards. Previously known as 'Appboy'."),

        // ─── Secrets & credentials ──────────────────────────────────────────

        .init(id: "secret-findings", title: "Hard-coded credentials",
              summary: "API keys, tokens, or private keys baked into the binary at build time. The single highest-impact static-analysis finding — anyone with the binary has the key.",
              detail: "Auditor scans the binary's printable strings for the canonical shapes of well-known credential types (AWS access keys, GitHub PATs, Stripe / Slack / Discord tokens, Google API keys, SendGrid, Twilio, Mailchimp, PEM private keys, JWTs).\n\nA hit means the developer probably embedded a credential they intended to keep server-side. Even if the credential is scoped read-only, embedding it in a shipping binary lets every user — and every attacker who acquires the binary — use that quota / abuse that scope.\n\nThe UI shows a *masked* form by default to keep screenshots safe."),
        .init(id: "secret-aws-key", title: "AWS access key",
              summary: "An AWS access-key ID embedded in the binary. The matching secret may not be present, but even the ID alone leaks account information.",
              learnMoreURL: URL(string: "https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html")),
        .init(id: "secret-github-token", title: "GitHub personal access token",
              summary: "A GitHub PAT with the modern `ghp_` / `ghs_` / `gho_` prefix. Treat as production credential.",
              learnMoreURL: URL(string: "https://docs.github.com/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens")),
        .init(id: "secret-stripe-key", title: "Stripe live secret key",
              summary: "An `sk_live_…` or `rk_live_…` Stripe key. These authenticate as the merchant — anyone holding it can charge cards on the merchant's account."),
        .init(id: "secret-slack-token", title: "Slack token",
              summary: "An `xoxa-…`, `xoxb-…`, `xoxp-…`, etc. Slack token. Authenticates as a bot, app, or user. Should never be shipped client-side."),
        .init(id: "secret-slack-webhook", title: "Slack incoming webhook URL",
              summary: "A `hooks.slack.com/services/...` URL. Anyone with this URL can post to the configured Slack channel."),
        .init(id: "secret-discord-webhook", title: "Discord webhook URL",
              summary: "A `discord.com/api/webhooks/...` URL. Same model as Slack — possession of the URL grants posting rights."),
        .init(id: "secret-google-api-key", title: "Google API key",
              summary: "An `AIza…` Google API key. Common in Firebase apps and is technically intended to be client-public — but should be IP-restricted server-side. Worth flagging because few apps actually do that.",
              learnMoreURL: URL(string: "https://cloud.google.com/docs/authentication/api-keys")),
        .init(id: "secret-sendgrid-key", title: "SendGrid API key",
              summary: "A `SG.…` SendGrid key. Authorises sending email through the bundle owner's account."),
        .init(id: "secret-twilio", title: "Twilio account SID",
              summary: "A Twilio `AC…` account SID. Often paired with an auth token — both should be server-side only."),
        .init(id: "secret-mailchimp", title: "Mailchimp API key",
              summary: "Mailchimp keys end in `-us<datacenter>`. Possession lets the holder enumerate / modify mailing lists."),
        .init(id: "secret-private-key", title: "PEM private key",
              summary: "An RSA / EC / OpenSSH / DSA / PGP private key embedded in the binary. Private keys belong on a server, not in a client.",
              detail: "Sometimes legitimate (a public-key pinning certificate stored as PEM is fine), but private-key markers (`BEGIN RSA PRIVATE KEY`, `BEGIN EC PRIVATE KEY`, etc.) are different — they should never appear in a distributed binary."),
        .init(id: "secret-jwt", title: "JSON Web Token",
              summary: "A JWT (`eyJ…` three-part token) embedded in the binary. Whether this matters depends on what the token authorises.",
              detail: "If it's a static, never-expiring service-account JWT, that's a serious leak. If it's a sample / test token, it's harmless. Auditor verifies the header decodes as a valid JWT before flagging — but cannot tell apart real tokens from fixtures, so investigate before alarming."),

        // ─── Bundle integrity ───────────────────────────────────────────────

        .init(id: "bundle-signing-audit", title: "Whole-bundle code-signing audit",
              summary: "Every Mach-O inside the bundle (frameworks, helpers, XPC services, login items, plug-ins) is checked for its Team ID and signing flags. Apple's Gatekeeper only validates the outer signature — Auditor walks the lot.",
              detail: "What we flag:\n\n  • **Mismatched Team IDs.** Inner Mach-Os signed by a Team ID different from the main app are a strong indicator of repackaging or supply-chain compromise. Legitimate bundles can include Apple-platform libraries — those are listed but excluded from the mismatch check.\n  • **Unsigned components.** Mach-Os without any signature aren't subject to library validation; an attacker who can replace the file gets immediate code execution at the next launch.\n  • **Ad-hoc signed components.** Fine for local development but unusual in shipped software."),
        .init(id: "rpath-hijacking", title: "Dylib hijacking via LC_RPATH",
              summary: "When dyld resolves an `@rpath/Foo.dylib` install name, it walks every directory in the binary's `LC_RPATH` list. If any of those directories is user-writable, an attacker can drop a malicious dylib there and have it loaded ahead of the legitimate one.",
              detail: "Auditor reports each rpath entry, the path it resolves to, and whether that path is currently user-writable on this machine. Hijackable entries (writable, or rooted at `/Users/...` / `$HOME`) get a red badge.\n\nMitigations the developer should have applied:\n  • Avoid `@rpath` in favour of `@executable_path/Frameworks/Foo.framework/...` for in-bundle dylibs.\n  • Sign with the **Hardened Runtime** + library-validation enabled, which refuses to load any dylib not signed by the same Team ID as the main app.\n  • Use **`-rpath`** sparingly; one entry per known-good location is plenty.",
              learnMoreURL: URL(string: "https://developer.apple.com/documentation/security/hardened_runtime")),
        .init(id: "embedded-launch-plist", title: "Embedded launch agent / daemon",
              summary: "A `LaunchAgents` (per-user) or `LaunchDaemons` (system-wide) plist shipped inside the bundle. The app intends to install this as a long-running background service.",
              detail: "Look at:\n  • **Label** — the launchd job name. Must match the file name.\n  • **Program / ProgramArguments** — what gets executed. Watch for paths under `~/Library/Application Support/` that aren't part of the bundle.\n  • **RunAtLoad** — true means it starts on every login (agent) or every boot (daemon).\n  • **KeepAlive** — true means launchd will restart it if it exits.\n  • **MachServices** — XPC endpoints registered by the job.",
              learnMoreURL: URL(string: "https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html")),
        .init(id: "privacy-claims-mismatch", title: "Privacy claims vs actual usage",
              summary: "Where the bundle's declared `NSUsageDescription` keys / entitlements don't line up with what the binary's symbols suggest it actually does.",
              detail: "Two failure modes:\n\n  • **Declared but unused.** The developer asks for camera/contacts/etc. but the binary contains no code path that touches those APIs. Could be a leftover from a removed feature, copy-pasted boilerplate, or — occasionally — a deliberate dishonesty (asking for broad permissions to use later).\n  • **Used but undeclared.** The binary references a privacy API but no matching declaration exists. The first call will crash with a TCC violation; the symbol may be present in a never-executed code path, or in a private API used to bypass the prompt.\n\nNeither is automatically a problem — but both are worth understanding before granting the app permissions."),

        // ─── Anti-analysis ─────────────────────────────────────────────────

        .init(id: "antianalysis-overview", title: "Anti-analysis signals",
              summary: "Apps that try to hide what they're doing from a debugger or static-analysis tool deserve more scrutiny — even when each individual signal has innocent explanations.",
              detail: "Auditor reports on five common anti-analysis techniques: `ptrace(PT_DENY_ATTACH)`, sysctl-based debugger detection, encrypted Mach-O segments, stripped symbol tables, and references to `DYLD_INSERT_LIBRARIES`.\n\nNone of these by itself is conclusive — DRM-protected apps and games legitimately use them. But the *combination* of multiple anti-analysis signals on an app that has no reason for them (a typical productivity app, say) is a strong adverse indicator."),
        .init(id: "antianalysis-ptrace", title: "ptrace(PT_DENY_ATTACH)",
              summary: "macOS's canonical anti-debug call. A process invokes `ptrace(PT_DENY_ATTACH, 0, 0, 0)` on itself and from then on any attempt to attach a debugger fails with EPERM.",
              detail: "Common in: DRM-protected media players, games with anti-cheat, banking apps. Concerning when present in apps with no obvious reason to refuse inspection."),
        .init(id: "antianalysis-sysctl", title: "sysctl-based debugger detection",
              summary: "Calling `sysctl(KERN_PROC, KERN_PROC_PID, …)` and inspecting the returned `kp_proc.p_flag` for the `P_TRACED` bit — the second-most-common anti-debug technique on macOS."),
        .init(id: "antianalysis-encrypted", title: "Encrypted Mach-O segment",
              summary: "An LC_ENCRYPTION_INFO[_64] load command with `cryptid != 0`. The segment is encrypted on disk and decrypted by dyld at launch.",
              detail: "Standard for Mac App Store apps shipped through FairPlay DRM. Outside the App Store this is unusual and points at a custom DRM scheme — disassembly tools won't see the real code without dumping memory from a running instance."),
        .init(id: "antianalysis-stripped", title: "Stripped symbol table",
              summary: "Heuristic: SYMTAB load command points at a string table smaller than 4 KB. Stripping local symbols is a normal release-build optimisation; we surface it because it makes other anti-analysis signals harder to investigate."),
        .init(id: "antianalysis-dyld-insert", title: "DYLD_INSERT_LIBRARIES literal",
              summary: "The binary's strings reference the `DYLD_INSERT_LIBRARIES` environment variable — used to inject a dylib into a process at launch.",
              detail: "Legitimate uses include debuggers, profilers, and testing harnesses. Also the standard injection vector for malware (mostly historic — Hardened Runtime + library validation neutralise it on modern macOS)."),

        // ─── Behavioural anomalies ─────────────────────────────────────────

        .init(id: "behavior-overview", title: "Behavioural anomalies",
              summary: "Patterns we look for in a monitored run's events: periodic beacons, activity bursts, and destinations the bundle didn't declare statically.",
              detail: "Each anomaly is a heuristic — none is *proof* of malice. They're prompts to look more carefully at specific events the user might otherwise scroll past in a list of thousands."),
        .init(id: "behavior-periodic-beacon", title: "Periodic beacon",
              summary: "Connections to the same destination at a regular cadence (within ±10% jitter). Heartbeats, telemetry pings, license checks — or, occasionally, command-and-control.",
              detail: "We require at least 4 connections, an inter-arrival mean of at least 5 seconds, and standard-deviation under 10% of the mean. Higher cadence and lower jitter both indicate stronger periodicity. Most legitimate apps have **at most** one or two beacons (a telemetry endpoint and maybe an update check). A handful of distinct beacons in one run is unusual."),
        .init(id: "behavior-burst", title: "Activity burst",
              summary: "More than 50 events touching one path or destination inside a 2-second sliding window — significantly higher than typical app behaviour.",
              detail: "Examples we'd expect:\n  • Bulk reads of `~/Library/Cookies/` — credential harvesting.\n  • Rapid-fire writes to a single file — log spinning.\n  • Many connections to one host in a couple of seconds — exfil upload, brute-forcing.\n\nNot every burst is malicious — apps starting up sometimes legitimately read tens of resources at once. The signal is *unusual* burstiness, especially against sensitive paths."),
        .init(id: "behavior-undeclared-host", title: "Undeclared destination",
              summary: "A network endpoint the app contacted at runtime that didn't appear in any hard-coded URL/domain or ATS exception declared in the bundle.",
              detail: "Often perfectly benign — CDN edge nodes, third-party SDK endpoints reached transitively, dynamically-discovered hosts. Worth surfacing because it tells you the bundle's static surface doesn't match its actual network behaviour, which sometimes matters for compliance reviews."),

        // ─── Compliance & system state ─────────────────────────────────────

        .init(id: "privacy-manifest", title: "Privacy manifest (PrivacyInfo.xcprivacy)",
              summary: "Apple's developer-stated record of what data an app collects, what tracking domains it uses, and which 'required-reason' APIs it accesses. Mandatory for App Store apps since May 2024.",
              detail: "The manifest declares four things:\n\n  • **NSPrivacyTracking** — does the app perform tracking (under Apple's broad definition)?\n  • **NSPrivacyTrackingDomains** — which domains the app uses for tracking. Apple blocks these via App Tracking Transparency unless the user opts in.\n  • **NSPrivacyCollectedDataTypes** — what kinds of personal data are collected, whether they're linked to the user, whether they're used for tracking, and for what purposes.\n  • **NSPrivacyAccessedAPITypes** — which 'required-reason' APIs the app calls. Apple's required-reason API categories include file timestamps, system boot time, disk space, active keyboards, and user defaults. Each requires the developer to declare a documented reason code.\n\nAuditor cross-references the API claims against the binary's symbol references, flagging both **declared but unused** (lazy or copy-paste) and **used but undeclared** (potential App Store rejection or attempted compliance dodge).",
              learnMoreURL: URL(string: "https://developer.apple.com/documentation/bundleresources/privacy_manifest_files")),

        .init(id: "sandbox-container", title: "App Sandbox container",
              summary: "Every sandboxed app gets a private directory at `~/Library/Containers/<bundle-id>/Data/`. Walking it shows what data the app actually keeps on the user's Mac.",
              detail: "Each container has a standard layout:\n  • **Documents** — user-created content. The 'real' data the app holds.\n  • **Library/Caches** — disposable, can always be deleted; will be re-fetched.\n  • **Library/Application Support** — app-managed data files (databases, cached resources).\n  • **Library/Preferences** — per-user defaults plist.\n  • **tmp** — temporary files, cleared periodically by macOS.\n\nUseful for reasoning about disk usage, finding what to back up, and for the auditor's purposes seeing what the app has *actually* persisted (vs claimed to keep). Apps without containers either aren't sandboxed or aren't installed under this user.",
              learnMoreURL: URL(string: "https://developer.apple.com/documentation/security/app_sandbox/about_app_sandbox")),

        .init(id: "btm-overview", title: "Background Task Management (BTM)",
              summary: "macOS 13+ tracks every login item, launch agent, and helper that's registered to start automatically. Auditor reads the BTM database via `sfltool dumpbtm` and shows the records associated with the inspected app.",
              detail: "If you've ever installed an app and seen 'Foo would like to add a Login Item' — that's BTM. Apps can register login items, launch agents (per-user), launch daemons (system-wide), helpers, and app extensions. Each record has:\n  • **Disposition** — enabled / disabled / allowed / denied / visible / hidden / notified.\n  • **Identifier** — the bundle ID (or label, for launchd jobs).\n  • **URL** — the path to the registered binary or plist.\n\nBTM enabled-but-not-allowed records are jobs the user has disabled in System Settings; the app may still believe they should run. BTM disabled records are dormant. Records you **didn't** know existed are sometimes the most interesting find.\n\n**About the admin prompt.** Apple tightened `sfltool dumpbtm` on macOS 14+ so an unprivileged invocation triggers an Authorization Services prompt for an admin password. Auditor avoids that pop-up two ways:\n  • **Privileged helper installed** — the helper (Settings → Helper) runs `sfltool` as root, so the BTM section populates automatically when you click the Static tab.\n  • **No helper** — the BTM section shows an opt-in 'Run BTM audit' button instead. Clicking it shells out to `sfltool` directly, which produces the macOS authorization prompt; you approve it once per request. Auditor never auto-fires that prompt.",
              learnMoreURL: URL(string: "https://support.apple.com/guide/mac-help/manage-login-items-and-extensions-mtusr003/mac")),

        .init(id: "external-inspectors", title: "External bundle inspectors",
              summary: "Auditor detects two third-party tools — Apparency and Suspicious Package, both by Mothers Ruin Software — and offers buttons that open the inspected bundle in them.",
              detail: "**Apparency** is a focused bundle-inspection app: it reads Info.plist, embedded entitlements, signing posture, helper layout, sandbox profile, and version history in a clean GUI. Useful as a sanity-check companion to Auditor's static report.\n\n**Suspicious Package** opens .pkg installers (and bundles that contain them) and lists every payload script, install action, and embedded receipt. Most useful when what was dragged onto Auditor is actually a .pkg installer rather than a runnable .app.\n\nBoth tools are read-only — they won't modify the bundle. We hand off via `NSWorkspace.open(bundleURL, withApplicationAt: appURL)`.",
              learnMoreURL: URL(string: "https://www.mothersruin.com/software/Apparency/")),

        .init(id: "exec-summary", title: "Executive summary",
              summary: "Top-of-dashboard synthesis: a plain-English narrative, the app's profile (signing, sandbox, distribution, tracker count, etc.), and the highest-severity concerns. The one card to read first.",
              detail: "What the exec summary aggregates:\n\n  • **Narrative.** Sentences pulled from the static report's signing posture, distribution provenance, and notable counts (third-party SDKs, hard-coded credentials, anti-analysis signals, hijackable rpaths). The biggest single risk-score contributor is appended as the 'where to look first' pointer.\n\n  • **App profile chips.** Compact badges that summarise sandbox state, Hardened Runtime, notarization, tracker SDK count, secrets count, anti-analysis signals, hijackable rpaths, embedded launch agents, and presence of a privacy manifest. Colours: green = expected/healthy, yellow/orange = worth a look, red = concerning.\n\n  • **Top concerns.** The five highest-severity findings from `StaticReport.warnings`, prioritised error → warn → info, with their KB links inline. Skip past these to the rest of the dashboard if they're empty; come back here whenever a new bundle is loaded."),

        .init(id: "out-of-scope-paths", title: "Out-of-scope file access",
              summary: "Paths the inspected app touched that aren't part of its normal scope — other apps' containers, other users' homes, sensitive dotfiles like ~/.ssh / ~/.aws / ~/.gnupg. Highlighted in orange in the Files tab.",
              detail: "What counts as **in scope**:\n  • The bundle's own files and resources.\n  • The app's sandbox container at `~/Library/Containers/<bundle-id>/`.\n  • The app's keyed Application Support, Caches, Logs, Preferences (`~/Library/Application Support/<bundle-id>/` etc.).\n  • System read-only roots (`/System`, `/usr/lib`, `/Library/Frameworks`, framework caches).\n  • Standard temp roots (`/tmp`, `/private/var/folders/`).\n\nWhat counts as **out of scope**:\n  • Other apps' containers / Application Support / Caches / Preferences.\n  • Sensitive home dotfiles (`.ssh`, `.aws`, `.gnupg`, `.config/gh`, `.config/op`, `.kube`, `.netrc`, `.pgpass`).\n  • Other user homes.\n  • Anything under `/Applications` or `/Library` that isn't the bundle's own scoped location.\n\n**Why this is a heuristic.** Apps legitimately access user-owned files when the user explicitly grants access — opening a Word doc from `~/Documents` is normal. We can't tell from a single file event whether the access was user-initiated. The Files tab shows the data; you decide whether the access fits the app's purpose.\n\nA scope check is *cheaper* and *broader* than the static risk classifier's `Risk.surprising`: every event is checked against bundle URL + bundle ID at render time, which catches paths the rule-based classifier missed."),

        .init(id: "usb-monitor", title: "USB device monitor",
              summary: "Polls `system_profiler SPUSBDataType -json` every 5 seconds while a run is active. Reports devices currently connected and any connect / disconnect changes during the run.",
              detail: "**What we see.** A snapshot of every USB device the system reports — name, manufacturer, vendor ID, product ID, serial number. Diffing across polls produces connect / disconnect events.\n\n**What we don't see.** Per-process attribution. macOS's IOKit can tell you which process holds a user-client connection to a specific device, but the public APIs require entitlements that aren't available outside Apple. If you need to know whether the inspected app *specifically* is talking to the keyboard / camera / hardware key, treat the dashboard's USB list as ambient context: \"these are the devices the app could reach\". Combine with the bundle's `com.apple.security.device.usb` entitlement (visible in the Static tab) and the app's behaviour — apps that have no reason to talk to USB and don't declare the entitlement won't be using it regardless.\n\n**Notable cases.**\n  • A new USB stick appearing during a run while the inspected app is frontmost — possible auto-mount + index trigger.\n  • A YubiKey / hardware token appearing — sign-in flow probably starting.\n  • A USB-Ethernet adapter — network configuration change.\n  • A connected iPhone (Continuity / iTunes-style) — probably the device, not the app, that triggered the change."),

        .init(id: "resource-monitor", title: "Resource use monitor",
              summary: "CPU / RAM / disk-I/O telemetry sampled at 1 Hz across the inspected app's process tree. Includes CPU spike detection against a 60-second rolling baseline.",
              detail: "**What's sampled.** For every PID in the tracked process tree we call `proc_pid_rusage(_, RUSAGE_INFO_V0, _)` and read four fields:\n  • `ri_user_time` + `ri_system_time` — CPU nanoseconds since process start.\n  • `ri_resident_size` — physical RAM occupied right now.\n  • `ri_diskio_bytesread` / `ri_diskio_byteswritten` — bytes the kernel has read/written for this process.\n\nWe compute deltas vs. the previous tick. CPU% is `(Δuser + Δsystem) / Δwall × 100`, where 100 % == one fully-saturated logical core (an app on four cores can read up to ~400 %).\n\n**Spike detection.** We keep a 60-sample rolling history of CPU%. A sample is flagged as a spike when it satisfies *both*:\n  1. CPU% > 25 (absolute floor — keeps idle noise out of the alerts).\n  2. CPU% > 2× the rolling average.\n\nWatch mode emits a change for each spike, so you'll see the menu-bar badge tick up if an app starts churning when it shouldn't.\n\n**What this is good for:**\n  • Catching apps that start a heavy background job when no UI is open (post-trial-expiry phone-homes, embedded miners, indexers).\n  • Confirming that the app you're watching has settled into its steady state versus still indexing / loading.\n  • Spotting unexpected disk I/O bursts (potential exfil / data dump).\n\n**Caveats.**\n  • `proc_pid_rusage` reports cumulative counters; we estimate the rate by sampling — short-lived bursts between two ticks may be smeared into the next sample.\n  • Resident-size is a snapshot; momentary peaks between ticks aren't visible.\n  • The first ~5 samples have no meaningful baseline; the spike detector is conservative until enough history accumulates."),

        // ─── Kill switch ───────────────────────────────────────────────────

        .init(id: "vm-isolation", title: "VM isolation (running apps in a guest)",
              summary: "When this is wired up, monitored runs happen inside a macOS guest VM rather than on your host. The inspected app runs in a separate kernel; if it does something destructive, only the VM is affected.",
              detail: "**Status: scaffold.** The wire protocol between the host and a guest agent is in place, the agent compiles, and the host can connect, hand-shake, and round-trip commands. Three pieces are still TODO before runs actually go through the VM:\n  1. Linking the existing monitors (`ProcessTracker`, `NetworkMonitor`, `ResourceMonitor`, `LiveProbeMonitor`, `DeviceUsageProbe`) into the guest agent so `launchAndMonitor` actually launches a bundle and streams events.\n  2. A bundle-transfer mechanism (shared folder via `VZSharedDirectory`, or guest-side scp from the host) so dragged-in apps reach the VM.\n  3. A host-side `VirtualMachineCoordinator` that uses `Virtualization.framework` to boot a stored guest image, wait for the agent to come online, and tear the VM down on disconnect.\n\nThe VM mode is Apple Silicon only and requires a 15+ GB macOS guest image you build once. See `docs/GUEST_AGENT.md` in the project tree for the full setup."),

        .init(id: "guest-agent", title: "Guest agent (privacycommand-guest)",
              summary: "A small daemon that runs inside the guest VM. The host opens a TCP connection to it, ships commands, consumes the observation stream.",
              detail: "Lives in `Sources/privacycommandGuestAgent` and ships as the `privacycommand-guest` executable. Both sides speak the `privacycommandGuestProtocol` types — `GuestEnvelope`, `GuestCommand`, `GuestObservation` — serialised as JSON, length-prefixed on the wire (4-byte big-endian UInt32 + payload).\n\n**Default port** is `49374`. Override with `--port`. The agent is single-tenant — a second host connection boots the first.\n\n**Observations the agent emits today** (one per type for the wire test): `agentReady`, `acknowledge`, `logMessage`, `processEvent`, `networkEvent`, `fileEvent`, `resourceSample`, `liveProbe`, `targetExited`, `agentError`. The actual capture pipelines for processes / network / files are stubbed — see the TODOs in the agent's `handleEnvelope`."),

        .init(id: "network-kill-switch", title: "Network kill switch (pf-based)",
              summary: "A real per-destination network block, installed by the privileged helper. The app keeps running so you can observe how it handles network failures — connection timeouts, retries, error dialogs, the works.",
              detail: "**How it works.** When you toggle Block Network on, Auditor pulls every IP the inspected app has been seen contacting during the run, hands the list to the helper over XPC, and the helper writes a `pf` anchor that drops outbound traffic to those addresses. Toggling off flushes the anchor and restores the original `/etc/pf.conf`.\n\n**Why this isn't perfect.** macOS's `pf` can't filter by PID — only by user / port / address / interface. We can't blackhole 'all of Slack's traffic'; we can only blackhole 'all traffic to the IPs Slack has reached so far'. That has two practical consequences:\n  • The block is **system-wide for those IPs**. If another app on your machine talks to the same destination, it'll be blocked too.\n  • New destinations the inspected app reaches **aren't automatically added** to the blocklist. Toggle off and on again to refresh after the app starts talking to new endpoints.\n\nFor process-level blocking with no collateral damage, use **Pause** instead — that uses SIGSTOP and freezes the entire process tree (no network, no anything). Block Network is the right tool when you need the app to *keep running* and observe how it copes."),

        .init(id: "kill-switch", title: "Kill switch (process pause)",
              summary: "Sends SIGSTOP to every PID in the inspected app's process tree. The app freezes — it can't send or receive network, can't write files, can't run any code. Click again to SIGCONT and resume.",
              detail: "**Why we implement it as a process pause rather than a network-only block.** A genuine per-app network firewall on macOS requires either Apple-granted entitlements (Network Extension content filter / Endpoint Security) or root-level pf rules — and pf can't filter by PID natively. Without those, freezing the process is the closest equivalent: a stopped process emits zero packets.\n\n**What this is good for:**\n  • Observing what state the app holds in memory at the moment you froze it (attach a debugger, take a memory dump).\n  • Confirming whether some background timer / heartbeat is the source of activity you're seeing — pause the app, watch the network monitor go silent.\n  • Stopping a runaway log spammer without killing it (your existing Stop run button SIGKILLs the tree).\n\n**What this is NOT good for:**\n  • Watching how the app degrades when only its network breaks. The app can't react because it can't run any code. For that you'd want true network-level blocking — see the Future task for a pfctl-based version routed through the privileged helper.\n\n**How it interacts with Stop run.** If you click Stop while paused, the auditor sends SIGCONT first (so SIGTERM can actually be processed by the app's run loop), then proceeds with the normal terminate-tree teardown."),

        // ─── Live probes ───────────────────────────────────────────────────

        .init(id: "live-probes", title: "Live probes — audit log",
              summary: "Pasteboard / camera / microphone / screen-recording access events captured during a monitored run. Each event is timestamped and attributed to the inspected app whenever we can.",
              detail: "Two complementary mechanisms run side-by-side while a monitored run is active:\n\n  • **Pasteboard polling** of `NSPasteboard.general.changeCount` at 500 ms. When the count ticks up we attribute the change to the inspected app if it was frontmost at the tick *or within the last 2 seconds* (the grace handles brief auditor-frontmost windows between user copy and our next poll). Reads are not observable from outside the kernel — only writes register.\n\n  • **`/usr/bin/log stream`** tailed against the `com.apple.controlcenter` subsystem. macOS's control-centre daemon logs every camera / microphone / screen-recording start and stop with the responsible app's name and PID. Auditor matches the logged process name against the inspected bundle's name and emits the appropriate event kind. This is far more reliable across macOS 13–15 than `AVCaptureDevice.isInUseByAnotherApplication` polling, which is inconsistent when querying *other* processes' usage.\n\nThe audit log is persisted with the run report, so it survives app restarts and can be exported as JSON / HTML / PDF alongside the rest of the findings."),

        .init(id: "probe-pasteboard", title: "Pasteboard write",
              summary: "The clipboard's contents changed while the inspected app was frontmost. The app probably wrote something to the clipboard.",
              detail: "We can detect that the pasteboard *changed*, but not what was written or by what code path. The 'Detail' column shows the pasteboard types involved (`public.utf8-plain-text`, `public.url`, etc.) so you can tell whether it was a string copy, a file copy, an image, etc.\n\nWe can't detect *reads* from outside the kernel. If you need read auditing, the only path on macOS today is the OS-level `pboard` log subsystem (which uses private TCC plumbing) — which Auditor doesn't tap into."),

        .init(id: "probe-camera", title: "Camera access",
              summary: "The system-default camera went into use while the inspected app was frontmost. The app probably started a video capture.",
              detail: "Detected via `AVCaptureDevice.isInUseByAnotherApplication` polling. Reading this property is free and doesn't require entitlements; only *capturing* video does.\n\nFalse positives: a different app could legitimately start the camera at the same moment the inspected app is frontmost. To confirm, cross-reference with the inspected app's `NSCameraUsageDescription` declaration in the static report and any `AVCaptureDevice` symbol references in the binary."),

        .init(id: "probe-microphone", title: "Microphone access",
              summary: "The system-default microphone went into use while the inspected app was frontmost. The app probably started recording or listening.",
              detail: "Same mechanism as the camera probe. Same limitations — Apple doesn't expose 'which process specifically holds the device' as a public API; we infer attribution from frontmost-app correlation.\n\nLegitimate uses include voice/video calling, voice notes, dictation, transcription, accessibility tools. Concerning when the app has no obvious reason to need the mic."),

        .init(id: "probe-screen-recording", title: "Screen recording / sharing",
              summary: "macOS's controlcenter daemon logged that the inspected app started capturing the screen. Detected via the `com.apple.controlcenter` log subsystem.",
              detail: "Triggered by anything that uses `ScreenCaptureKit`, `CGDisplayStream`, or the older `CGWindowListCreateImage` / `CGDisplayCreateImage` APIs. Common in:\n  • Video-conferencing apps (Zoom, Teams, Slack huddles, Google Meet)\n  • Screen recorders (QuickTime, Loom, OBS, ScreenFlow)\n  • Remote-support tools (TeamViewer, AnyDesk, Apple Remote Desktop)\n  • Screenshot utilities and clipboard managers that capture screen regions\n\nLess common but worth flagging: a productivity app that has no obvious reason to be capturing the screen, or a non-conferencing app that briefly captures while in the background."),

        .init(id: "watch-mode", title: "Watch mode",
              summary: "Long-running surveillance that keeps the monitored run alive in the menu bar. The icon shows an unread-change badge so you only need to look when something happens.",
              detail: "Watch mode is the same dynamic monitor as a regular run — process tracking, network destinations, file events, behavioural anomaly detection — but with three differences:\n\n  • Closing the main window doesn't stop the run. The menu-bar icon stays put.\n  • A change detector diffs each tick of the event stream against the previous state and posts a `WatchModeChange` for: a new destination contacted, a new behavioural anomaly, or any event flagged as 'surprising' by the risk classifier.\n  • Each new change increments the menu-bar badge. Opening the popover marks them all as read.\n\nUseful for catching things that only happen after the app has been idle for a while: license-server pings, telemetry batches, scheduled update checks, post-trial-expiry phone-homes."),

        .init(id: "notarization-deep-dive", title: "Notarization deep dive",
              summary: "Beyond the basic 'is it notarized' yes/no: whether the notarization ticket is **stapled** to the bundle, the verbose Gatekeeper assessment, and the executable's SHA-256 for external reputation lookup.",
              detail: "**Stapling.** When Apple notarizes a bundle, the developer can attach (\"staple\") the resulting ticket to the bundle so Gatekeeper can verify offline. If the ticket isn't stapled, Gatekeeper has to contact Apple's servers — which may fail offline, on captive networks, or if Apple's servers are slow.\n\n**Stapler verdicts:**\n  • **OK** — ticket present and validates.\n  • **No ticket** — bundle is signed but no ticket is stapled. Gatekeeper falls back to online lookup.\n  • **Failed** — ticket exists but doesn't validate.\n\n**Gatekeeper assessment** (`spctl --assess -vvv`) is the source of truth for whether macOS would currently allow this bundle to launch. Output cites the Gatekeeper origin (Notarized Developer ID / Developer ID / Apple System / etc.).\n\n**SHA-256** is exposed for the user to copy and paste into VirusTotal, Apple's Notary Service, or an internal threat-intel feed. We deliberately don't ship VirusTotal API integration — it requires a key — but we link straight to the lookup URL."),

        // ─── Feature flags & trials ────────────────────────────────────────

        .init(id: "flags-overview", title: "Feature flags & trials",
              summary: "Switches the binary checks at runtime to enable or disable features, gate paid functionality, run A/B experiments, or expose developer-only behaviour. Auditor scans the binary's printable strings for the canonical names of these switches and groups them by purpose.",
              detail: "Four categories are surfaced separately:\n\n  • **Trial & licensing** — the names of booleans and counters the app uses to decide whether you've paid. `isTrial`, `isPro`, `trial_days_remaining`, `subscription_status`, `license_key`. Knowing these names lets you understand how the app *thinks* about your entitlement; flipping them in memory is a separate (and usually licence-violating) exercise.\n  • **Feature flags** — references to flag-management SDKs (LaunchDarkly, Optimizely, Firebase Remote Config, PostHog, Statsig, Unleash) plus generic patterns like `featureFlag`, `kFeatureSomething`, `feature_toggle`.\n  • **A/B experiments** — `experiment_name`, `variant_id`, `treatment_group`, `abTest`. Useful to know what experiments you might be enrolled in.\n  • **Debug & development** — `DEBUG_MODE`, `isDebugBuild`, `internal_only`, `staff_mode`. If a release build still references these, the developer probably forgot to strip them — sometimes the toggles are reachable from the running app via plist edits or environment variables.\n\nThis scanner is regex-based over the same printable-string stream `BinaryStringScanner` walks. We deliberately err on the side of caution — better to miss a few unfamiliar patterns than light up every `enable_*` symbol from the standard library."),

        .init(id: "flag-trial-state", title: "Trial / Pro / Premium state flag",
              summary: "A boolean (`isTrial`, `isPro`, `IsPremium`, `hasTrial`, `IsRegistered`…) the app checks before unlocking paid functionality. Auditor reports the *name* of the flag — the runtime *value* depends on the user's purchase state and isn't visible from static analysis alone.",
              detail: "Knowing the flag name is useful for three reasons:\n  1. It tells you what the app considers a \"paid\" or \"unlocked\" state — the vocabulary alone reveals the licensing model.\n  2. It points you at the code path you'd hit while reverse-engineering the licence check (DisassemblyAnalyzer can usually highlight the function that sets it).\n  3. If the flag is ever read from a writable file (plist, prefs, keychain stub), an attacker can flip it without modifying signed code.\n\nLegitimate apps absolutely do this — there's nothing inherently suspect about it. The flag is just a useful index into how the app gates its paid features."),

        .init(id: "flag-trial-expiry", title: "Trial expiry / day counter",
              summary: "The name of a counter or timestamp the app uses to track how much trial is left. `trial_days_remaining`, `trialEnd`, `trial_expiration`, `days_left`.",
              detail: "Static analysis can't tell you the *value* of the counter — that lives in user defaults, the keychain, or a server. But the *presence* of these names tells you the app has a time-limited trial and roughly how it counts down.\n\nReverse engineers care about whether the counter is anchored to:\n  • **First-launch wallclock** (resettable by reinstall + clock manipulation),\n  • **Server-issued timestamp** (much harder to fool),\n  • **System uptime / boot count** (fragile, occasionally seen).\n\nWe surface the name so a follow-up disassembly pass has somewhere to start."),

        .init(id: "flag-subscription", title: "Subscription state",
              summary: "A reference to a subscription state machine — `subscription_status`, `subscription_tier`, `subscription_expir…`, `subscription_renewal`. Common in App Store + RevenueCat-backed apps.",
              detail: "The names usually map onto the StoreKit 2 / RevenueCat field set: `active`, `inGracePeriod`, `expired`, `inBillingRetry`, `paused`. If you see one of these strings in a binary, that's a strong hint about which receipts the app validates and which states unlock which features."),

        .init(id: "flag-license-key", title: "License / activation key (name)",
              summary: "References to `license_key`, `activation_code`, `registration_token`, etc. We're picking up the *name* of the storage slot, not the key itself — actual key values are handled by SecretsScanner.",
              detail: "If the *value* of a licence key is hard-coded into the binary, that's a SecretsScanner finding (and a serious one — possession of the key bypasses payment). The flag scanner instead surfaces the *name* of the variable, which is helpful when the value is fetched at runtime: it tells you what to grep for in keychain dumps, prefs files, or network traffic."),

        .init(id: "flag-pro-premium", title: "Pro / Premium feature gate",
              summary: "Names like `pro_feature`, `premium_mode`, `paid_tier_enabled`, `proUser`. Each is a place in the code where a feature is unlocked based on the user's plan.",
              detail: "Cross-reference these with the trial-state and subscription flags above to build a picture of the app's monetisation model: which features are free, which require a paid plan, and whether the gate is checked on every use or once at startup."),

        .init(id: "flag-launchdarkly", title: "LaunchDarkly feature flags",
              summary: "References to `LDClient`, `LDFlagKey`, `LDValue`, `ld_user`, or the `launchdarkly` literal. The app integrates LaunchDarkly's feature-flag SDK and pulls flag evaluations from `https://app.launchdarkly.com/` (or a relay proxy).",
              detail: "LaunchDarkly is one of the most common enterprise feature-flag platforms. The SDK call pattern is `client.boolVariation(\"flag-key\", user, default)` — every flag the app evaluates is named in the binary. Scrolling the SDK's stream traffic during a monitored run usually exposes the flag set.\n\nPrivacy note: LaunchDarkly receives a *user context* on every evaluation. The SDK lets the developer choose what to send (often an opaque ID, but sometimes email / device class / locale).",
              learnMoreURL: URL(string: "https://docs.launchdarkly.com/sdk/client-side/ios")),

        .init(id: "flag-optimizely", title: "Optimizely",
              summary: "References to `OptimizelyClient`, `optly`, or the `optimizely` literal. The app uses Optimizely's experimentation / feature-flag platform.",
              detail: "Optimizely traffic flows to `*.optimizely.com` and `cdn.optimizely.com` (datafile fetch). The SDK exposes both feature flags and A/B-experiment APIs from a single client.",
              learnMoreURL: URL(string: "https://docs.developers.optimizely.com/")),

        .init(id: "flag-firebase-remote-config", title: "Firebase Remote Config",
              summary: "References to `FIRRemoteConfig`, `firebase_remote_config`, or `getRemoteConfig`. The app pulls flag and configuration values from Firebase.",
              detail: "Firebase Remote Config is Google's free flag/config service, often paired with Firebase Analytics in the same app. Fetched from `firebaseremoteconfig.googleapis.com`.\n\nA single Remote Config payload can carry dozens of flags, A/B-test variants, and JSON-blob configurations — much harder to enumerate than individual `boolVariation` calls.",
              learnMoreURL: URL(string: "https://firebase.google.com/docs/remote-config")),

        .init(id: "flag-posthog", title: "PostHog feature flags",
              summary: "References to `PHGPostHog`, `isFeatureEnabled`, `getFeatureFlag`, or the `posthog` literal. PostHog is open-source product analytics + feature flags.",
              detail: "PostHog can be self-hosted or used via PostHog Cloud (`*.posthog.com`). The same SDK handles event tracking and feature-flag evaluation, so its presence often means the app is also sending product-analytics events.",
              learnMoreURL: URL(string: "https://posthog.com/docs/feature-flags")),

        .init(id: "flag-statsig", title: "Statsig",
              summary: "References to `StatsigClient`, `checkGate`, `getExperiment`, `getDynamicConfig`, or the `statsig` literal. Statsig combines feature flags, experiments, and dynamic config in one SDK.",
              detail: "`checkGate(\"my-flag\")` returns a boolean; `getExperiment(\"exp\")` returns a treatment; `getDynamicConfig(\"cfg\")` returns a JSON payload. Traffic goes to `*.statsigapi.net`.",
              learnMoreURL: URL(string: "https://docs.statsig.com/client/iosClientSDK")),

        .init(id: "flag-unleash", title: "Unleash",
              summary: "References to `UnleashClient`, `isEnabled`, `unleash_toggle`, `unleash_api`, or `unleash_context`. Unleash is an open-source feature-toggle platform.",
              detail: "Unleash is commonly self-hosted; SaaS is also available at `*.getunleash.io`. The client polls a relay for toggle definitions and evaluates them locally.",
              learnMoreURL: URL(string: "https://docs.getunleash.io/")),

        .init(id: "flag-generic", title: "Feature flag (generic / custom)",
              summary: "The binary references generic feature-flag vocabulary — `feature_flag`, `featureFlag`, `feature_toggle`, `kFeatureSomething` — without a specific third-party SDK fingerprint. Probably a hand-rolled flag system or a local plist-backed switch.",
              detail: "Hand-rolled flag systems are common in macOS apps, especially older ones. They're often plist-backed (look for keys in `defaults read <bundle-id>`) or compiled in as build configurations.\n\nWhen reverse-engineering, these are the easiest flags to flip: a `defaults write <bundle-id> EnableThing -bool YES` or a build-config edit can unlock features that aren't reachable from the UI. Whether that's permitted by the EULA is the user's problem, not ours."),

        .init(id: "flag-experiment", title: "A/B experiment",
              summary: "References to experiment-system vocabulary: `experiment_id`, `experiment_name`, `variant_id`, `variant_group`, `treatment_group`, `abTest`. The app probably runs A/B tests on its users.",
              detail: "Knowing you're in an experiment matters when behaviour you observe might not match what other users see. If the binary references a specific variant name, that's a hint at what the experiment is testing.\n\nExperiment frameworks are usually paired with a flag SDK (LaunchDarkly, Optimizely, Statsig, PostHog) — the experiment is just a flag whose value is chosen by a hashing function instead of a manual decision."),

        .init(id: "flag-debug", title: "Debug / development flag",
              summary: "References to `DEBUG_MODE`, `isDebugBuild`, `debug_enabled`, `kDebug…`. Switches the developer used during development that may or may not be reachable in the shipped build.",
              detail: "A release build that still contains debug-flag strings doesn't necessarily *honour* them — the dead code may have been compiled out, leaving only the literal in the strings table. But sometimes the path is live, and a `defaults write <bundle-id> DebugEnabled -bool YES` (or an equivalent environment variable) flips additional logging or developer menus on.\n\nWhen the app is something where this matters (forensic tools, hardened apps, security-sensitive utilities), audit which paths the strings come from before assuming they're harmless."),

        .init(id: "flag-internal-only", title: "Internal-only / staff-only flag",
              summary: "References to `internal_only`, `staff_only`, `employee_build`, `internal_user`. The app distinguishes between internal employees and external users.",
              detail: "These flags usually gate three things:\n  1. Pre-release features that haven't shipped externally yet,\n  2. Verbose telemetry / debug menus that production users don't see,\n  3. Server endpoints that only the developer's own staff are allowed to hit.\n\nIf you're auditing a vendor's production app and find a live `staff_only` flag with a backdoor unlock path, that's worth raising with them — it's a privilege-escalation vector even if it was unintentional.")
    ]
}
