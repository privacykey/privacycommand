import Foundation

/// Builds a `PermissionReconciliation` by crossing what an app **requested**
/// (declared usage keys + declaring entitlements), what macOS **granted** it
/// (TCC), and what a monitored run saw it **use** (live probes).
///
/// Pure and deterministic — the inputs are already-derived values, so the whole
/// thing is unit-tested with a truth table and never needs a live database or a
/// running app.
public enum PermissionReconciler {

    /// Categories privacycommand can actually observe being used at runtime. The
    /// live-probe monitor only covers camera, microphone, and screen recording
    /// (plus pasteboard, which isn't a privacy category); everything else is
    /// `.notObservable`.
    static let observableCategories: Set<PrivacyCategory> = [.camera, .microphone, .screenCapture]

    /// Map the categories a set of live-probe events touched onto privacy
    /// categories. Pasteboard writes have no privacy category and drop out.
    public static func observedCategories(from probes: [LiveProbeEvent]) -> Set<PrivacyCategory> {
        Set(probes.compactMap { probeCategory($0.kind.category) })
    }

    static func probeCategory(_ category: LiveProbeEvent.Kind.Category) -> PrivacyCategory? {
        switch category {
        case .camera:          return .camera
        case .microphone:      return .microphone
        case .screenRecording: return .screenCapture
        case .pasteboard:      return nil
        }
    }

    /// Reconcile the three axes for one app.
    ///
    /// - Parameters:
    ///   - grants: TCC grants **already filtered to this app** (via
    ///     `Array<TCCGrant>.matching(bundleID:executablePath:bundlePath:)`).
    ///   - tccReadable: whether TCC could be read; when false the granted column
    ///     is unknown and grant-absence verdicts are suppressed.
    ///   - observedUsage: categories seen used in the monitored run (empty if no run).
    public static func reconcile(
        declaredKeys: [PrivacyKey],
        entitlements: Entitlements,
        inferredCapabilities: [InferredCapability],
        grants: [TCCGrant],
        tccReadable: Bool,
        observedUsage: Set<PrivacyCategory>,
        now: Date = Date()
    ) -> PermissionReconciliation {

        let systemAccessGrants = grants.filter(\.isSystemAccess)
            .sorted { $0.serviceLabel < $1.serviceLabel }

        // Every category with *any* signal becomes a matrix row, minus the
        // system-access ones (shown separately) and `.unknown`.
        var candidates = Set<PrivacyCategory>()
        candidates.formUnion(declaredKeys.map(\.category))
        candidates.formUnion(inferredCapabilities.map(\.category))
        candidates.formUnion(grants.compactMap(\.category))
        candidates.formUnion(observedUsage)
        for cat in [PrivacyCategory.appleEvents, .automation, .localNetwork]
        where StaticAnalyzer.categoryDeclaredViaEntitlement(cat, entitlements: entitlements) {
            candidates.insert(cat)
        }
        candidates = candidates.filter { !$0.isSystemAccess && $0 != .unknown }

        let rows = candidates.map { cat -> PermissionReconciliation.Row in
            // Requested: usage key(s) and/or a declaring entitlement.
            var evidence: [String] = []
            for key in declaredKeys where key.category == cat {
                evidence.append("Declares \(key.rawKey)")
            }
            if StaticAnalyzer.categoryDeclaredViaEntitlement(cat, entitlements: entitlements) {
                switch cat {
                case .appleEvents, .automation: evidence.append("Has Apple Events entitlement")
                case .localNetwork:             evidence.append("Has network client/server entitlement")
                default:                        break
                }
            }
            let requested = !evidence.isEmpty

            // Present-in-binary: a real capability hit (not a declared-but-unseen entry).
            let presentInBinary = inferredCapabilities.contains {
                $0.category == cat && !$0.declaredButNotJustified
            }

            let categoryGrants = grants.filter { $0.category == cat }
            let grant = effectiveDecision(categoryGrants.map(\.decision))

            let usage: PermissionReconciliation.Usage
            if observedUsage.contains(cat) {
                usage = .observed
            } else if observableCategories.contains(cat) {
                usage = .notObserved
            } else {
                usage = .notObservable
            }

            return PermissionReconciliation.Row(
                category: cat,
                requested: requested,
                requestedEvidence: evidence,
                presentInBinary: presentInBinary,
                grant: grant,
                grants: categoryGrants.sorted { $0.scope.rawValue < $1.scope.rawValue },
                used: usage,
                verdict: verdict(requested: requested, presentInBinary: presentInBinary,
                                 grant: grant, used: usage, tccReadable: tccReadable))
        }
        .sorted { lhs, rhs in
            // Most-notable first, then alphabetical for stability.
            if lhs.verdict.severity != rhs.verdict.severity {
                return lhs.verdict.severity == .warn
            }
            return lhs.category.displayName < rhs.category.displayName
        }

        return PermissionReconciliation(rows: rows,
                                        systemAccessGrants: systemAccessGrants,
                                        tccReadable: tccReadable,
                                        generatedAt: now)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Collapse multiple grants for one category (e.g. a user- and a
    /// system-scope row) to the most permissive decision.
    static func effectiveDecision(_ decisions: [TCCDecision]) -> TCCDecision? {
        if decisions.isEmpty { return nil }
        if decisions.contains(.allowed) { return .allowed }
        if decisions.contains(.limited) { return .limited }
        if decisions.contains(.denied) { return .denied }
        return .unknown
    }

    static func verdict(requested: Bool, presentInBinary: Bool, grant: TCCDecision?,
                        used: PermissionReconciliation.Usage,
                        tccReadable: Bool) -> PermissionReconciliation.Verdict {
        if grant?.isAllowed == true {
            if !requested { return .grantedNotRequested }
            if used == .observed { return .grantedAndUsed }
            return .granted
        }
        if grant == .denied && requested { return .requestedDenied }
        // No effective grant. Distinguish "no record" from "couldn't read TCC".
        if grant == nil && !tccReadable { return .grantUnknown }
        if requested { return .requestedNotGranted }
        if presentInBinary { return .usedInBinaryNotRequested }
        return .none
    }
}
