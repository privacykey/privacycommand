import Foundation

/// Catalog of well-known third-party SDKs and the fingerprints we use to
/// detect them inside an inspected app.
///
/// **Why this matters.** Apple's Privacy Labels and DataPrivacy / Privacy
/// Manifests are only as honest as the developer chooses to be. By matching
/// the *artifacts* an SDK leaves behind in the bundle (a framework directory,
/// a sub-bundle ID, a known network destination, a giveaway symbol name), we
/// can produce an objective list of "this app contains the following
/// third-party SDKs" that doesn't depend on the developer telling the truth.
///
/// **Match strategy.** Each fingerprint provides up to four signal types,
/// any of which is independently sufficient for a positive ID:
///   1. `frameworkPatterns` — case-insensitive substring of a framework
///      directory name (e.g. `Firebase`, `Adjust`).
///   2. `bundleIDPatterns` — case-insensitive substring of any bundle ID
///      found in the bundle (frameworks, XPC services, login items, helpers).
///   3. `urlPatterns` — case-insensitive substring of a hard-coded URL or
///      domain extracted from the binary's strings.
///   4. `symbolPatterns` — case-sensitive substring of a binary symbol /
///      string. Most useful when the SDK doesn't ship as a discrete framework
///      (e.g. statically linked).
///
/// **What we deliberately don't do.** We don't claim a hit means the SDK is
/// *active* — only that the artifact is present. An app may bundle Firebase
/// but never call it. The fix is a runtime confirmation via the dynamic
/// monitor (we already see network destinations); the static layer is for
/// "what *could* run", not "what *did* run".
public enum SDKFingerprintDatabase {

    public static let all: [SDKFingerprint] = analytics
        + advertising
        + attribution
        + crashReporting
        + performance
        + customerSupport
        + auth
        + monetization
        + push
        + abTesting
        + logging
        + feedback

    // MARK: - Analytics ---------------------------------------------------

    public static let analytics: [SDKFingerprint] = [
        .init(id: "firebase-analytics", displayName: "Firebase Analytics", vendor: "Google",
              category: .analytics,
              description: "Google's app analytics SDK (formerly Google Analytics for Firebase). Tracks user events, sessions, demographics, and uploads them to Google's servers.",
              frameworkPatterns: ["FirebaseAnalytics", "GoogleAppMeasurement"],
              bundleIDPatterns: ["com.google.firebase", "com.google.appmeasurement"],
              symbolPatterns: ["FIRApp", "FIRAnalyticsConfiguration", "GADApplication"],
              urlPatterns: ["app-measurement.com", "firebaseio.com", "firebaseinstallations.googleapis.com"],
              kbArticleID: "sdk-firebase-analytics"),

        .init(id: "google-analytics", displayName: "Google Analytics (legacy)", vendor: "Google",
              category: .analytics,
              description: "Google's legacy Universal Analytics SDK. Generally superseded by Firebase Analytics; presence in a new app is unusual.",
              frameworkPatterns: ["GoogleAnalytics"],
              bundleIDPatterns: ["com.google.analytics"],
              symbolPatterns: ["GAITrackedViewController", "kGAIVersion"],
              urlPatterns: ["www.google-analytics.com", "ssl.google-analytics.com"],
              kbArticleID: "sdk-google-analytics"),

        .init(id: "mixpanel", displayName: "Mixpanel", vendor: "Mixpanel, Inc.",
              category: .analytics,
              description: "Product analytics platform. Tracks user funnels, retention, and custom events.",
              frameworkPatterns: ["Mixpanel"],
              bundleIDPatterns: ["com.mixpanel"],
              symbolPatterns: ["MixpanelInstance", "MPNetwork"],
              urlPatterns: ["api.mixpanel.com", "mixpanel.com/track"],
              kbArticleID: "sdk-mixpanel"),

        .init(id: "amplitude", displayName: "Amplitude", vendor: "Amplitude, Inc.",
              category: .analytics,
              description: "Product analytics. Used to measure feature usage, cohort behaviour, and run experiments.",
              frameworkPatterns: ["Amplitude"],
              bundleIDPatterns: ["com.amplitude"],
              symbolPatterns: ["AMPClient", "AMPTrackingOptions"],
              urlPatterns: ["api.amplitude.com", "api2.amplitude.com", "amplitude.com"],
              kbArticleID: "sdk-amplitude"),

        .init(id: "segment", displayName: "Segment", vendor: "Twilio Segment",
              category: .analytics,
              description: "Customer-data pipeline. The app sends events to Segment, which forwards them to dozens of downstream destinations (analytics, advertising, CRM, …).",
              frameworkPatterns: ["Segment", "Analytics"],
              bundleIDPatterns: ["com.segment"],
              symbolPatterns: ["SEGAnalytics", "SEGSegmentIntegrationFactory"],
              urlPatterns: ["api.segment.io", "cdn.segment.com"],
              kbArticleID: "sdk-segment"),

        .init(id: "heap", displayName: "Heap", vendor: "Heap, Inc.",
              category: .analytics,
              description: "Auto-capture analytics. Records every UI interaction without explicit instrumentation.",
              frameworkPatterns: ["Heap"],
              bundleIDPatterns: ["com.heapanalytics"],
              symbolPatterns: ["HeapAnalytics"],
              urlPatterns: ["heapanalytics.com"],
              kbArticleID: "sdk-heap"),

        .init(id: "posthog", displayName: "PostHog", vendor: "PostHog Inc.",
              category: .analytics,
              description: "Open-source product analytics. Self-hostable; otherwise sends events to PostHog Cloud.",
              frameworkPatterns: ["PostHog"],
              bundleIDPatterns: ["com.posthog"],
              symbolPatterns: ["PHGPostHog"],
              urlPatterns: ["app.posthog.com", "posthog.com"],
              kbArticleID: "sdk-posthog"),

        .init(id: "matomo", displayName: "Matomo", vendor: "InnoCraft",
              category: .analytics,
              description: "Privacy-friendly, self-hostable analytics (formerly Piwik).",
              frameworkPatterns: ["MatomoTracker", "Piwik"],
              bundleIDPatterns: ["org.matomo", "org.piwik"],
              symbolPatterns: ["MatomoTracker"],
              urlPatterns: ["matomo.org"],
              kbArticleID: "sdk-matomo"),
    ]

    // MARK: - Advertising -------------------------------------------------

    public static let advertising: [SDKFingerprint] = [
        .init(id: "admob", displayName: "Google AdMob", vendor: "Google",
              category: .advertising,
              description: "Google's mobile advertising network. Ad impressions, clicks, and ad-targeting identifiers are sent to Google.",
              frameworkPatterns: ["GoogleMobileAds"],
              bundleIDPatterns: ["com.google.mobileads", "com.google.GoogleMobileAds"],
              symbolPatterns: ["GADApplication", "GADRequest"],
              urlPatterns: ["googleads.g.doubleclick.net", "googlesyndication.com", "pagead2.googlesyndication.com"],
              kbArticleID: "sdk-admob"),

        .init(id: "facebook-audience-network", displayName: "Meta Audience Network", vendor: "Meta",
              category: .advertising,
              description: "Meta's mobile ad network. Brings Facebook/Instagram targeting data to advertisements served inside third-party apps.",
              frameworkPatterns: ["FBAudienceNetwork"],
              bundleIDPatterns: ["com.facebook.audiencenetwork"],
              symbolPatterns: ["FBAdView", "FBInterstitialAd"],
              urlPatterns: ["graph.facebook.com", "an.facebook.com"],
              kbArticleID: "sdk-meta-audience-network"),

        .init(id: "applovin", displayName: "AppLovin MAX", vendor: "AppLovin",
              category: .advertising,
              description: "Mobile ad mediation platform. Routes ad requests to multiple ad networks.",
              frameworkPatterns: ["AppLovin", "AppLovinSDK"],
              bundleIDPatterns: ["com.applovin"],
              symbolPatterns: ["ALSdk", "MAInterstitialAd"],
              urlPatterns: ["applovin.com", "ms.applovin.com"],
              kbArticleID: "sdk-applovin"),

        .init(id: "unity-ads", displayName: "Unity Ads", vendor: "Unity",
              category: .advertising,
              description: "Unity's video-ad network for game monetization.",
              frameworkPatterns: ["UnityAds"],
              bundleIDPatterns: ["com.unity3d.ads"],
              symbolPatterns: ["UnityAdsClient"],
              urlPatterns: ["unityads.unity3d.com"],
              kbArticleID: "sdk-unity-ads"),

        .init(id: "ironsource", displayName: "ironSource", vendor: "Unity / ironSource",
              category: .advertising,
              description: "Mobile ad mediation and monetization SDK.",
              frameworkPatterns: ["IronSource"],
              bundleIDPatterns: ["com.ironsource"],
              symbolPatterns: ["IronSource"],
              urlPatterns: ["ironsrc.com", "is-tlb.com", "supersonicads.com"],
              kbArticleID: "sdk-ironsource"),
    ]

    // MARK: - Attribution -------------------------------------------------

    public static let attribution: [SDKFingerprint] = [
        .init(id: "appsflyer", displayName: "AppsFlyer", vendor: "AppsFlyer Ltd.",
              category: .attribution,
              description: "Mobile-marketing attribution. Tracks which ad campaign / referrer led to an install or purchase.",
              frameworkPatterns: ["AppsFlyerLib"],
              bundleIDPatterns: ["com.appsflyer"],
              symbolPatterns: ["AppsFlyerLib", "AppsFlyerTracker"],
              urlPatterns: ["app.appsflyer.com", "events.appsflyer.com"],
              kbArticleID: "sdk-appsflyer"),

        .init(id: "adjust", displayName: "Adjust", vendor: "Adjust GmbH",
              category: .attribution,
              description: "Mobile attribution and analytics. Tracks ad attribution, deep links, and lifecycle events.",
              frameworkPatterns: ["Adjust", "AdjustSdk"],
              bundleIDPatterns: ["com.adjust"],
              symbolPatterns: ["ADJConfig", "Adjust ADJ"],
              urlPatterns: ["app.adjust.com", "adjust.com"],
              kbArticleID: "sdk-adjust"),

        .init(id: "branch", displayName: "Branch", vendor: "Branch Metrics, Inc.",
              category: .attribution,
              description: "Deep linking and mobile attribution. Tracks which referrer drove a session and reconstructs cross-app journeys.",
              frameworkPatterns: ["Branch"],
              bundleIDPatterns: ["io.branch", "com.branchmetrics"],
              symbolPatterns: ["BNCConfig", "BranchUniversalObject"],
              urlPatterns: ["api.branch.io", "bnc.lt"],
              kbArticleID: "sdk-branch"),

        .init(id: "kochava", displayName: "Kochava", vendor: "Kochava, Inc.",
              category: .attribution,
              description: "Mobile attribution and audience-building.",
              frameworkPatterns: ["Kochava"],
              bundleIDPatterns: ["com.kochava"],
              symbolPatterns: ["KochavaTracker"],
              urlPatterns: ["kochava.com", "control.kochava.com"],
              kbArticleID: "sdk-kochava"),

        .init(id: "singular", displayName: "Singular", vendor: "Singular Labs",
              category: .attribution,
              description: "Marketing analytics and attribution.",
              frameworkPatterns: ["Singular", "SingularSDK"],
              bundleIDPatterns: ["com.singular"],
              symbolPatterns: ["Singular SDK"],
              urlPatterns: ["singular.net", "sdk-api-v1.singular.net"],
              kbArticleID: "sdk-singular"),
    ]

    // MARK: - Crash reporting --------------------------------------------

    public static let crashReporting: [SDKFingerprint] = [
        .init(id: "crashlytics", displayName: "Firebase Crashlytics", vendor: "Google",
              category: .crashReporting,
              description: "Crash and error reporting from Google. Symbolicates crashes and groups them by signature.",
              frameworkPatterns: ["FirebaseCrashlytics", "Crashlytics"],
              bundleIDPatterns: ["com.crashlytics", "com.google.firebase.crashlytics"],
              symbolPatterns: ["FIRCrashlytics", "CLSReport"],
              urlPatterns: ["crashlyticsreports-pa.googleapis.com", "firebase-settings.crashlytics.com"],
              kbArticleID: "sdk-crashlytics"),

        .init(id: "sentry", displayName: "Sentry", vendor: "Functional Software, Inc.",
              category: .crashReporting,
              description: "Application error monitoring and performance tracing.",
              frameworkPatterns: ["Sentry"],
              bundleIDPatterns: ["io.sentry"],
              symbolPatterns: ["SentryClient", "SentryHub"],
              urlPatterns: ["sentry.io", "ingest.sentry.io"],
              kbArticleID: "sdk-sentry"),

        .init(id: "bugsnag", displayName: "Bugsnag", vendor: "SmartBear",
              category: .crashReporting,
              description: "Error monitoring SDK.",
              frameworkPatterns: ["Bugsnag"],
              bundleIDPatterns: ["com.bugsnag"],
              symbolPatterns: ["BugsnagClient"],
              urlPatterns: ["notify.bugsnag.com", "sessions.bugsnag.com"],
              kbArticleID: "sdk-bugsnag"),

        .init(id: "appcenter", displayName: "Visual Studio App Center", vendor: "Microsoft",
              category: .crashReporting,
              description: "Microsoft's mobile DevOps stack — crash reporting, analytics, and distribution.",
              frameworkPatterns: ["AppCenter", "AppCenterCrashes", "AppCenterAnalytics"],
              bundleIDPatterns: ["com.microsoft.appcenter"],
              symbolPatterns: ["MSACAppCenter", "MSACCrashes"],
              urlPatterns: ["in.appcenter.ms"],
              kbArticleID: "sdk-appcenter"),

        .init(id: "raygun", displayName: "Raygun", vendor: "Raygun Limited",
              category: .crashReporting,
              description: "Error and performance monitoring.",
              frameworkPatterns: ["Raygun4Apple", "Raygun"],
              bundleIDPatterns: ["com.raygun"],
              symbolPatterns: ["RaygunClient"],
              urlPatterns: ["api.raygun.com"],
              kbArticleID: "sdk-raygun"),
    ]

    // MARK: - Performance / RUM ------------------------------------------

    public static let performance: [SDKFingerprint] = [
        .init(id: "datadog-rum", displayName: "Datadog RUM", vendor: "Datadog",
              category: .performance,
              description: "Real user monitoring — performance, errors, and session replays sent to Datadog.",
              frameworkPatterns: ["Datadog", "DatadogRUM"],
              bundleIDPatterns: ["com.datadoghq"],
              symbolPatterns: ["DDLogs", "DDRUMMonitor"],
              urlPatterns: ["datadoghq.com", "logs.browser-intake-datadoghq.com"],
              kbArticleID: "sdk-datadog-rum"),

        .init(id: "newrelic", displayName: "New Relic Mobile", vendor: "New Relic, Inc.",
              category: .performance,
              description: "Mobile application performance monitoring (APM).",
              frameworkPatterns: ["NewRelicAgent", "NewRelic"],
              bundleIDPatterns: ["com.newrelic"],
              symbolPatterns: ["NewRelic startWith"],
              urlPatterns: ["mobile-collector.newrelic.com"],
              kbArticleID: "sdk-newrelic"),

        .init(id: "instabug", displayName: "Instabug", vendor: "Instabug, Inc.",
              category: .performance,
              description: "In-app bug reporting, performance monitoring, and surveys.",
              frameworkPatterns: ["Instabug"],
              bundleIDPatterns: ["com.instabug"],
              symbolPatterns: ["IBGAPM", "Instabug startWith"],
              urlPatterns: ["instabug.com", "api.instabug.com"],
              kbArticleID: "sdk-instabug"),
    ]

    // MARK: - Customer support / chat ------------------------------------

    public static let customerSupport: [SDKFingerprint] = [
        .init(id: "intercom", displayName: "Intercom", vendor: "Intercom, Inc.",
              category: .customerSupport,
              description: "In-app customer-support and messaging widget.",
              frameworkPatterns: ["Intercom"],
              bundleIDPatterns: ["com.intercom"],
              symbolPatterns: ["ICMConversation", "Intercom setApiKey"],
              urlPatterns: ["api.intercom.io", "api-iam.intercom.io"],
              kbArticleID: "sdk-intercom"),

        .init(id: "zendesk", displayName: "Zendesk", vendor: "Zendesk, Inc.",
              category: .customerSupport,
              description: "Customer support / help-centre SDK.",
              frameworkPatterns: ["ZendeskCoreSDK", "ZendeskSDK", "ZendeskChat"],
              bundleIDPatterns: ["com.zendesk"],
              symbolPatterns: ["ZendeskCoreSDK", "ZDKConfig"],
              urlPatterns: ["zendesk.com", "zd-img.com"],
              kbArticleID: "sdk-zendesk"),

        .init(id: "helpshift", displayName: "Helpshift", vendor: "Helpshift, Inc.",
              category: .customerSupport,
              description: "In-app help / support SDK.",
              frameworkPatterns: ["Helpshift"],
              bundleIDPatterns: ["com.helpshift"],
              symbolPatterns: ["HelpshiftConfig"],
              urlPatterns: ["helpshift.com", "api.helpshift.com"],
              kbArticleID: "sdk-helpshift"),
    ]

    // MARK: - Authentication ---------------------------------------------

    public static let auth: [SDKFingerprint] = [
        .init(id: "auth0", displayName: "Auth0", vendor: "Okta, Inc.",
              category: .authentication,
              description: "OAuth / OpenID-Connect authentication-as-a-service.",
              frameworkPatterns: ["Auth0"],
              bundleIDPatterns: ["com.auth0"],
              symbolPatterns: ["A0Auth0"],
              urlPatterns: ["auth0.com"],
              kbArticleID: "sdk-auth0"),

        .init(id: "firebase-auth", displayName: "Firebase Authentication", vendor: "Google",
              category: .authentication,
              description: "Firebase's user-authentication SDK (email, OAuth providers, phone).",
              frameworkPatterns: ["FirebaseAuth"],
              bundleIDPatterns: ["com.google.firebase.auth"],
              symbolPatterns: ["FIRAuth"],
              urlPatterns: ["securetoken.googleapis.com", "identitytoolkit.googleapis.com"],
              kbArticleID: "sdk-firebase-auth"),

        .init(id: "okta", displayName: "Okta", vendor: "Okta, Inc.",
              category: .authentication,
              description: "Enterprise SSO / OIDC SDK.",
              frameworkPatterns: ["OktaOidc", "OktaAuthSdk"],
              bundleIDPatterns: ["com.okta"],
              symbolPatterns: ["OktaAuthSdk"],
              urlPatterns: ["okta.com", "oktapreview.com"],
              kbArticleID: "sdk-okta"),
    ]

    // MARK: - Monetization & purchases -----------------------------------

    public static let monetization: [SDKFingerprint] = [
        .init(id: "revenuecat", displayName: "RevenueCat", vendor: "RevenueCat, Inc.",
              category: .monetization,
              description: "Subscriptions and in-app-purchase backend.",
              frameworkPatterns: ["RevenueCat", "Purchases"],
              bundleIDPatterns: ["com.revenuecat"],
              symbolPatterns: ["RCPurchases"],
              urlPatterns: ["api.revenuecat.com"],
              kbArticleID: "sdk-revenuecat"),

        .init(id: "stripe", displayName: "Stripe", vendor: "Stripe, Inc.",
              category: .monetization,
              description: "Payments SDK. Card and Apple Pay processing via Stripe's API.",
              frameworkPatterns: ["Stripe", "StripePaymentSheet", "StripePayments"],
              bundleIDPatterns: ["com.stripe"],
              symbolPatterns: ["STPAPIClient", "STPPaymentSheet"],
              urlPatterns: ["api.stripe.com", "stripe.com"],
              kbArticleID: "sdk-stripe"),

        .init(id: "braintree", displayName: "Braintree", vendor: "PayPal",
              category: .monetization,
              description: "PayPal-owned payments SDK.",
              frameworkPatterns: ["Braintree"],
              bundleIDPatterns: ["com.braintreepayments"],
              symbolPatterns: ["BTAPIClient"],
              urlPatterns: ["braintree-api.com", "braintreegateway.com"],
              kbArticleID: "sdk-braintree"),
    ]

    // MARK: - Push notifications -----------------------------------------

    public static let push: [SDKFingerprint] = [
        .init(id: "firebase-messaging", displayName: "Firebase Cloud Messaging", vendor: "Google",
              category: .pushNotifications,
              description: "Google's push-notification service.",
              frameworkPatterns: ["FirebaseMessaging"],
              bundleIDPatterns: ["com.google.firebase.messaging"],
              symbolPatterns: ["FIRMessaging"],
              urlPatterns: ["fcm.googleapis.com", "fcmtoken.googleapis.com"],
              kbArticleID: "sdk-fcm"),

        .init(id: "onesignal", displayName: "OneSignal", vendor: "OneSignal",
              category: .pushNotifications,
              description: "Push and in-app notification platform.",
              frameworkPatterns: ["OneSignal"],
              bundleIDPatterns: ["com.onesignal"],
              symbolPatterns: ["OneSignalClient"],
              urlPatterns: ["onesignal.com"],
              kbArticleID: "sdk-onesignal"),

        .init(id: "urban-airship", displayName: "Airship", vendor: "Airship (formerly Urban Airship)",
              category: .pushNotifications,
              description: "Customer-engagement platform — push, in-app messaging, automation.",
              frameworkPatterns: ["AirshipKit", "AirshipCore"],
              bundleIDPatterns: ["com.urbanairship", "com.airship"],
              symbolPatterns: ["UAirship"],
              urlPatterns: ["urbanairship.com", "airship.com"],
              kbArticleID: "sdk-airship"),

        .init(id: "iterable", displayName: "Iterable", vendor: "Iterable, Inc.",
              category: .pushNotifications,
              description: "Cross-channel marketing automation (push, email, SMS, in-app).",
              frameworkPatterns: ["IterableSDK", "Iterable-iOS-SDK"],
              bundleIDPatterns: ["com.iterable"],
              symbolPatterns: ["IterableAPI"],
              urlPatterns: ["api.iterable.com"],
              kbArticleID: "sdk-iterable"),
    ]

    // MARK: - A/B testing & experimentation ------------------------------

    public static let abTesting: [SDKFingerprint] = [
        .init(id: "optimizely", displayName: "Optimizely", vendor: "Optimizely, Inc.",
              category: .abTesting,
              description: "Feature-flagging and experimentation platform.",
              frameworkPatterns: ["Optimizely"],
              bundleIDPatterns: ["com.optimizely"],
              symbolPatterns: ["OptimizelyClient"],
              urlPatterns: ["optimizely.com", "logx.optimizely.com"],
              kbArticleID: "sdk-optimizely"),

        .init(id: "launchdarkly", displayName: "LaunchDarkly", vendor: "LaunchDarkly, Inc.",
              category: .abTesting,
              description: "Feature-flag platform.",
              frameworkPatterns: ["LaunchDarkly"],
              bundleIDPatterns: ["com.launchdarkly"],
              symbolPatterns: ["LDClient"],
              urlPatterns: ["launchdarkly.com", "app.launchdarkly.com"],
              kbArticleID: "sdk-launchdarkly"),

        .init(id: "firebase-remote-config", displayName: "Firebase Remote Config", vendor: "Google",
              category: .abTesting,
              description: "Server-driven configuration and A/B-testing for apps.",
              frameworkPatterns: ["FirebaseRemoteConfig"],
              bundleIDPatterns: ["com.google.firebase.remoteconfig"],
              symbolPatterns: ["FIRRemoteConfig"],
              urlPatterns: ["firebaseremoteconfig.googleapis.com"],
              kbArticleID: "sdk-firebase-remote-config"),
    ]

    // MARK: - Logging ----------------------------------------------------

    public static let logging: [SDKFingerprint] = [
        .init(id: "cocoalumberjack", displayName: "CocoaLumberjack", vendor: "Open source",
              category: .logging,
              description: "Logging framework for Cocoa apps. Local file logging — does not by itself transmit data.",
              frameworkPatterns: ["CocoaLumberjack"],
              bundleIDPatterns: ["com.deusty.lumberjack"],
              symbolPatterns: ["DDLog", "DDLogger"],
              urlPatterns: [],
              kbArticleID: "sdk-cocoalumberjack"),
    ]

    // MARK: - Feedback / surveys -----------------------------------------

    public static let feedback: [SDKFingerprint] = [
        .init(id: "userleap", displayName: "Sprig (UserLeap)", vendor: "Sprig",
              category: .feedback,
              description: "In-app surveys and user-research.",
              frameworkPatterns: ["UserLeap", "Sprig"],
              bundleIDPatterns: ["com.userleap", "com.sprig"],
              symbolPatterns: ["UserLeap", "SprigSDK"],
              urlPatterns: ["userleap.com", "api.sprig.com"],
              kbArticleID: "sdk-sprig"),

        .init(id: "appboy-braze", displayName: "Braze", vendor: "Braze, Inc.",
              category: .feedback,
              description: "Customer-engagement platform — push, in-app, email, content cards. Was 'Appboy'.",
              frameworkPatterns: ["Appboy_iOS_SDK", "BrazeKit", "BrazeUI"],
              bundleIDPatterns: ["com.appboy", "com.braze"],
              symbolPatterns: ["ABKAppboy", "BRZAppboy"],
              urlPatterns: ["appboy.com", "braze.com", "iad-01.braze.com", "iad-02.braze.com"],
              kbArticleID: "sdk-braze"),
    ]
}

// MARK: - Public types

public struct SDKFingerprint: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let displayName: String
    public let vendor: String
    public let category: SDKCategory
    public let description: String
    public let frameworkPatterns: [String]
    public let bundleIDPatterns: [String]
    public let symbolPatterns: [String]
    public let urlPatterns: [String]
    public let kbArticleID: String?

    public init(id: String, displayName: String, vendor: String, category: SDKCategory,
                description: String,
                frameworkPatterns: [String] = [],
                bundleIDPatterns: [String] = [],
                symbolPatterns: [String] = [],
                urlPatterns: [String] = [],
                kbArticleID: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.vendor = vendor
        self.category = category
        self.description = description
        self.frameworkPatterns = frameworkPatterns
        self.bundleIDPatterns = bundleIDPatterns
        self.symbolPatterns = symbolPatterns
        self.urlPatterns = urlPatterns
        self.kbArticleID = kbArticleID
    }
}

public enum SDKCategory: String, Sendable, Hashable, Codable, CaseIterable {
    case analytics         = "Analytics"
    case advertising       = "Advertising"
    case attribution       = "Attribution / install tracking"
    case crashReporting    = "Crash reporting"
    case performance       = "Performance monitoring"
    case customerSupport   = "Customer support / chat"
    case authentication    = "Authentication / SSO"
    case monetization      = "Monetization & payments"
    case pushNotifications = "Push notifications"
    case abTesting         = "A/B testing & feature flags"
    case logging           = "Logging"
    case feedback          = "User feedback / engagement"

    /// SF Symbol that pairs with the category in the UI.
    public var icon: String {
        switch self {
        case .analytics:         return "chart.bar.xaxis"
        case .advertising:       return "megaphone"
        case .attribution:       return "link.circle"
        case .crashReporting:    return "exclamationmark.bubble"
        case .performance:       return "speedometer"
        case .customerSupport:   return "bubble.left.and.bubble.right"
        case .authentication:    return "person.badge.key"
        case .monetization:      return "creditcard"
        case .pushNotifications: return "bell.badge"
        case .abTesting:         return "flag.2.crossed"
        case .logging:           return "doc.text"
        case .feedback:          return "text.bubble"
        }
    }

    /// True for the categories whose entire purpose is to observe and
    /// transmit user behaviour: product analytics, ad networks, and
    /// install-attribution platforms. Crash reporters, support widgets,
    /// auth, payments, push and feature flags are *not* counted as
    /// telemetry — they carry weaker privacy implications and live in
    /// the "supporting SDKs" tier.
    ///
    /// Used by the Dashboard's TelemetrySummaryCard and by SDKHitsView's
    /// "tracking SDKs" colour group.
    public var isTelemetry: Bool {
        switch self {
        case .analytics, .advertising, .attribution: return true
        default: return false
        }
    }
}

public extension SDKHit {
    /// Convenience so callers can write `hit.isTelemetry` instead of
    /// reaching into the fingerprint.
    var isTelemetry: Bool { fingerprint.category.isTelemetry }
}
