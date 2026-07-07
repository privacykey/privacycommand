import XCTest
#if SWIFT_PACKAGE
@testable import privacycommandCore
#else
@testable import privacycommand
#endif

/// Truth-table tests for `PermissionReconciler.reconcile` — the requested ×
/// granted × used cross-check. Pure inputs, no database, no running app.
final class PermissionReconcilerTests: XCTestCase {

    // MARK: - Builders

    private func ents(appleEvents: AppleEventsEntitlement? = nil,
                      networkClient: Bool = false) -> Entitlements {
        Entitlements(raw: [:], isSandboxed: false, appGroups: [], appleEvents: appleEvents,
                     networkClient: networkClient, networkServer: false, allowsJIT: false,
                     allowsDyldEnvironmentVariables: false, disablesLibraryValidation: false,
                     endpointSecurityClient: false, networkExtension: [])
    }
    private func key(_ raw: String, _ cat: PrivacyCategory) -> PrivacyKey {
        PrivacyKey(rawKey: raw, category: cat, humanLabel: cat.displayName, purposeString: "reason")
    }
    private func inferred(_ cat: PrivacyCategory, declaredButNotJustified: Bool = false) -> InferredCapability {
        InferredCapability(category: cat, confidence: .high,
                           evidence: ["Binary references \(cat.rawValue)"],
                           declaredButNotJustified: declaredButNotJustified,
                           inferredButNotDeclared: !declaredButNotJustified)
    }
    private func grant(_ cat: PrivacyCategory?, service: String, _ decision: TCCDecision,
                       systemAccess: Bool = false) -> TCCGrant {
        TCCGrant(service: service, category: cat, serviceLabel: service, isSystemAccess: systemAccess,
                 client: "com.example.app", clientType: .bundleID, decision: decision,
                 lastModified: nil, scope: .user)
    }
    private func reconcile(keys: [PrivacyKey] = [], ents: Entitlements? = nil,
                           inferred: [InferredCapability] = [], grants: [TCCGrant] = [],
                           tccReadable: Bool = true,
                           used: Set<PrivacyCategory> = []) -> PermissionReconciliation {
        PermissionReconciler.reconcile(
            declaredKeys: keys, entitlements: ents ?? self.ents(),
            inferredCapabilities: inferred, grants: grants,
            tccReadable: tccReadable, observedUsage: used)
    }
    private func row(_ r: PermissionReconciliation, _ cat: PrivacyCategory) -> PermissionReconciliation.Row? {
        r.rows.first { $0.category == cat }
    }

    // MARK: - Verdict truth table

    func testGrantedAndUsed() {
        let r = reconcile(keys: [key("NSCameraUsageDescription", .camera)],
                          grants: [grant(.camera, service: "kTCCServiceCamera", .allowed)],
                          used: [.camera])
        XCTAssertEqual(row(r, .camera)?.verdict, .grantedAndUsed)
        XCTAssertEqual(row(r, .camera)?.used, .observed)
    }

    func testGrantedRequestedButNotObserved() {
        let r = reconcile(keys: [key("NSCameraUsageDescription", .camera)],
                          grants: [grant(.camera, service: "kTCCServiceCamera", .allowed)])
        XCTAssertEqual(row(r, .camera)?.verdict, .granted)
        XCTAssertEqual(row(r, .camera)?.used, .notObserved, "camera is observable but wasn't seen")
    }

    func testGrantedNotRequested() {
        // Holds a camera grant but never declared a usage key — the surprising case.
        let r = reconcile(grants: [grant(.camera, service: "kTCCServiceCamera", .allowed)])
        let cam = row(r, .camera)
        XCTAssertEqual(cam?.verdict, .grantedNotRequested)
        XCTAssertFalse(cam?.requested ?? true)
        XCTAssertEqual(cam?.verdict.severity, .warn)
    }

    func testRequestedDenied() {
        let r = reconcile(keys: [key("NSMicrophoneUsageDescription", .microphone)],
                          grants: [grant(.microphone, service: "kTCCServiceMicrophone", .denied)])
        XCTAssertEqual(row(r, .microphone)?.verdict, .requestedDenied)
    }

    func testRequestedNotGranted() {
        let r = reconcile(keys: [key("NSContactsUsageDescription", .contacts)])
        XCTAssertEqual(row(r, .contacts)?.verdict, .requestedNotGranted)
    }

    func testUsedInBinaryNotRequested() {
        // Binary references the API, no usage key, no grant — undeclared capability.
        let r = reconcile(inferred: [inferred(.contacts)])
        XCTAssertEqual(row(r, .contacts)?.verdict, .usedInBinaryNotRequested)
        XCTAssertTrue(row(r, .contacts)?.presentInBinary ?? false)
    }

    func testGrantUnknownWhenTCCUnreadable() {
        let r = reconcile(keys: [key("NSCameraUsageDescription", .camera)], tccReadable: false)
        XCTAssertEqual(row(r, .camera)?.verdict, .grantUnknown,
                       "must not claim 'not granted' when we couldn't read TCC")
    }

    // MARK: - Requested axis

    func testEntitlementDerivedRequestedAppleEvents() {
        let r = reconcile(ents: ents(appleEvents: .anyApp))
        let ae = row(r, .appleEvents)
        XCTAssertNotNil(ae, "an Apple Events entitlement seeds an appleEvents row")
        XCTAssertTrue(ae?.requested ?? false)
        XCTAssertEqual(ae?.verdict, .requestedNotGranted)
        XCTAssertNotNil(row(r, .automation), "Apple Events also seeds an automation row")
    }

    func testDeclaredButNotJustifiedIsNotPresentInBinary() {
        let r = reconcile(keys: [key("NSCameraUsageDescription", .camera)],
                          inferred: [inferred(.camera, declaredButNotJustified: true)])
        XCTAssertFalse(row(r, .camera)?.presentInBinary ?? true,
                       "a declared-but-unseen capability is not evidence of binary use")
    }

    // MARK: - System access & observability

    func testSystemAccessSeparatedFromMatrix() {
        let r = reconcile(grants: [
            grant(.fullDiskAccess, service: "kTCCServiceSystemPolicyAllFiles", .allowed, systemAccess: true),
            grant(.camera, service: "kTCCServiceCamera", .allowed),
        ])
        XCTAssertTrue(r.rows.allSatisfy { $0.category != .fullDiskAccess },
                      "FDA is a system-access grant, not a matrix row")
        XCTAssertEqual(r.systemAccessGrants.map(\.category), [.fullDiskAccess])
        XCTAssertNotNil(row(r, .camera))
    }

    func testUsedObservability() {
        let r = reconcile(keys: [key("NSMicrophoneUsageDescription", .microphone),
                                 key("NSContactsUsageDescription", .contacts)])
        XCTAssertEqual(row(r, .microphone)?.used, .notObserved, "mic is observable")
        XCTAssertEqual(row(r, .contacts)?.used, .notObservable, "contacts can't be observed at runtime")
    }

    func testUnreadableTCCSurfacedOnResult() {
        let r = reconcile(keys: [key("NSCameraUsageDescription", .camera)], tccReadable: false)
        XCTAssertFalse(r.tccReadable)
    }

    // MARK: - Probe → category mapping

    func testObservedCategoriesFromProbes() {
        let probes = [
            LiveProbeEvent(kind: .cameraStart, pid: 1, processName: "x"),
            LiveProbeEvent(kind: .screenRecordingStart, pid: 1, processName: "x"),
            LiveProbeEvent(kind: .pasteboardWrite, pid: 1, processName: "x"),
        ]
        let cats = PermissionReconciler.observedCategories(from: probes)
        XCTAssertEqual(cats, [.camera, .screenCapture], "pasteboard has no privacy category")
    }

    func testEffectiveDecisionPrefersAllowed() {
        XCTAssertEqual(PermissionReconciler.effectiveDecision([.denied, .allowed]), .allowed)
        XCTAssertEqual(PermissionReconciler.effectiveDecision([.denied, .limited]), .limited)
        XCTAssertEqual(PermissionReconciler.effectiveDecision([]), nil)
    }
}
