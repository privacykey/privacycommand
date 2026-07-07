import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Darwin
#if SWIFT_PACKAGE
import privacycommandCore
#endif

@MainActor
final class AnalysisCoordinator: ObservableObject {

    @Published var bundle: AppBundle?
    @Published var staticReport: StaticReport?
    /// When the inspected app was mounted from a DMG, this holds the
    /// mount details so the user can eject the disk image when done
    /// inspecting. Cleared on `select(url:)` of a different bundle.
    @Published var mountedDMG: DMGMounter.Mount?
    @Published var events: [DynamicEvent] = []
    @Published var isMonitoring = false
    /// True while a Tier-2 connection trace (relaunch-under-interposer) runs.
    @Published var isTracing = false
    /// True while a fresh `analyze(bundleAt:)` pass is running. The
    /// bundle URL of the in-flight analysis is exposed so the UI can
    /// show "Analyzing Foo.app…" rather than a generic spinner.
    @Published var isAnalyzing = false
    @Published var analyzingURL: URL?
    /// Process-level kill switch — when true, every tracked PID has been
    /// sent SIGSTOP. The app can't send/receive network, can't write
    /// files, can't run any code at all until the switch flips off and
    /// SIGCONT is sent.
    @Published var isPaused = false
    /// Network-level kill switch — when true, the privileged helper has
    /// installed a pf anchor blocking outbound traffic to the IP set
    /// the inspected app has been seen contacting. The app keeps
    /// running and you can observe how it handles network failures.
    @Published var isNetworkBlocked = false
    @Published var lastError: String?
    @Published var fidelityNotes: [String] = []
    @Published var startedAt: Date?
    @Published var endedAt: Date?
    @Published var recentRuns: [RunReportMeta] = []
    /// The id of the currently-open report, if any. Stable across saves so
    /// repeated saves overwrite the same directory.
    @Published private(set) var currentRunID: UUID = UUID()

    // Lazy-analyzed nested bundles (XPC services, helpers, login items).
    // Cleared when a new top-level bundle is loaded. Not persisted to JSON —
    // recomputed on demand on each session.
    @Published var subBundleAnalyses: [URL: StaticReport] = [:]
    @Published var subBundleErrors: [URL: String] = [:]
    @Published var subBundleAnalyzing: Set<URL> = []

    // MARK: - VM run

    /// Reachability of the in-VM guest agent, as last probed. Drives the
    /// connection badge and gates the "Run in VM" controls.
    enum VMConnectionState: Equatable {
        case idle
        case checking
        case connected(hostName: String, macOSVersion: String, guestVersion: Int)
        case versionMismatch(guestVersion: Int, hostVersion: Int)
        case unreachable(String)
    }

    /// The VM's IP / hostname and the guest agent's port. Persisted so the
    /// user doesn't re-enter the VM address every launch.
    @Published var vmHost: String =
        UserDefaults.standard.string(forKey: AnalysisCoordinator.vmHostKey) ?? "" {
        didSet { UserDefaults.standard.set(vmHost, forKey: AnalysisCoordinator.vmHostKey) }
    }
    @Published var vmPort: Int =
        (UserDefaults.standard.object(forKey: AnalysisCoordinator.vmPortKey) as? Int) ?? 49374 {
        didSet { UserDefaults.standard.set(vmPort, forKey: AnalysisCoordinator.vmPortKey) }
    }
    @Published var vmConnection: VMConnectionState = .idle
    /// True while the *current* monitored run is happening inside the VM
    /// rather than on the host. Lets `stopMonitoredRun` take the VM path.
    @Published private(set) var isVMRun = false

    /// Whole-app decompilation offloaded to the guest VM (Phase 3) — distinct
    /// from a monitored VM run; it drives a Ghidra dump inside the guest and
    /// collects the streamed classes into `vmDecompileResult`.
    @Published var vmDecompiling = false
    @Published var vmDecompileResult: DecompilationIndex?
    @Published var vmDecompileError: String?

    private static let vmHostKey = "privacycommand.vm.host"
    private static let vmPortKey = "privacycommand.vm.port"

    private var vmSession: VMGuestSession?
    private var vmStreamTask: Task<Void, Never>?

    private let analyzer = StaticAnalyzer()
    private var monitor: DynamicMonitor?
    private var streamTask: Task<Void, Never>?
    private var helperEventTask: Task<Void, Never>?
    private var resourceMonitor: ResourceMonitor?
    private var resourceTask: Task<Void, Never>?
    private var liveProbeMonitor: LiveProbeMonitor?
    private var liveProbeTask: Task<Void, Never>?
    private var resourceUsageMonitor: SystemResourceMonitor?
    private var resourceUsageTask: Task<Void, Never>?
    private var usbMonitor: USBDeviceMonitor?
    private var usbTask: Task<Void, Never>?

    /// Latest snapshot of open file descriptors (Sloth-style view). Replaced
    /// on every ResourceMonitor poll. Empty when not in a monitored run.
    @Published var openResources: [OpenResource] = []
    /// Chronological audit log of pasteboard / camera / mic events.
    /// Cleared at the start of each run; persisted into the saved
    /// `RunReport` when the run ends.
    @Published var liveProbeEvents: [LiveProbeEvent] = []
    /// Rolling list of CPU/RAM/disk samples for the inspected app's
    /// PID tree. Capped at 600 entries (10 minutes at 1 Hz) to keep
    /// memory bounded for long watch-mode runs.
    @Published var resourceSamples: [SystemResourceMonitor.Sample] = []
    private let maxResourceSamples = 600
    /// USB-device connect / disconnect events emitted during the run.
    @Published var usbChanges: [USBDeviceMonitor.Change] = []
    /// Snapshot of currently-connected USB devices, refreshed every poll.
    @Published var connectedUSBDevices: [USBDeviceMonitor.Device] = []
    /// Index into `events` for each event id, so we can upsert in O(1) when
    /// network monitors re-emit the same connection.
    private var eventIndices: [UUID: Int] = [:]

    /// Set by `privacycommandApp` after both ObservableObjects exist, so
    /// the coordinator can drive the helper when starting a run.
    weak var helperInstaller: HelperInstaller?

    // MARK: - Public actions

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Accept .app bundles directly OR a DMG we'll mount + walk for
        // the first .app inside. We deliberately do NOT accept .zip —
        // expanding zips on the user's behalf would either modify their
        // filesystem or require a temp dir we'd then have to clean up;
        // the simpler answer is "extract first, then drop the .app".
        panel.allowedContentTypes = [UTType.application, UTType.diskImage]
        panel.message = "Drop a .app bundle or a .dmg disk image. ZIP archives aren't supported — extract them first."
        if panel.runModal() == .OK, let url = panel.url {
            select(url: url)
        }
    }

    /// Kicks off a static-analysis pass on the chosen path. Routes
    /// based on extension:
    ///   • `.app` → analyse directly.
    ///   • `.dmg` (and other UTI-disk-image variants) → mount it
    ///     read-only, find the first .app bundle inside, analyse that.
    ///     A "Mounted from <name>.dmg — Eject" affordance appears in
    ///     the header until the user dismisses it.
    ///   • `.zip` → reject with a friendly error. We don't expand zips
    ///     on the user's behalf because that would either touch their
    ///     filesystem or leave a temp-dir we'd have to garbage-collect.
    ///
    /// Heavy work (Mach-O parsing, codesign shell-outs, recursive
    /// bundle walking, SDK matching, secrets scanning, etc.) runs on a
    /// `Task.detached` so the main thread stays responsive — the UI
    /// observes `isAnalyzing` for the modal spinner.
    func select(url: URL) {
        guard !isAnalyzing else { return }

        // Reject .zip up-front with a clear message.
        if url.pathExtension.lowercased() == "zip" {
            self.lastError = "ZIP archives aren't supported. Extract the .zip first, then drop the resulting .app bundle here."
            return
        }

        // If the user dropped a DMG, mount it and analyse the first
        // .app inside. We chain through `select(url:)` recursively for
        // the resolved .app so the rest of the flow is unchanged.
        if Self.isDiskImage(url) {
            isAnalyzing = true
            analyzingURL = url
            lastError = nil
            Task {
                do {
                    // Eject any previously-mounted DMG so we don't
                    // accumulate volumes if the user inspects several
                    // disk images in a row.
                    if let prev = self.mountedDMG {
                        try? await DMGMounter.detach(prev)
                        self.mountedDMG = nil
                    }
                    let mount = try await DMGMounter.mount(dmg: url)
                    guard let app = DMGMounter.firstAppBundle(
                        in: mount.primaryMountPoint) else {
                        try? await DMGMounter.detach(mount)
                        self.lastError = "Mounted \(url.lastPathComponent) but didn't find a .app bundle inside it."
                        self.isAnalyzing = false
                        self.analyzingURL = nil
                        return
                    }
                    self.mountedDMG = mount
                    self.isAnalyzing = false   // re-enter via .app branch
                    self.analyzingURL = nil
                    self.select(url: app)
                } catch {
                    self.lastError = "Couldn't mount \(url.lastPathComponent): \(error.localizedDescription)"
                    self.isAnalyzing = false
                    self.analyzingURL = nil
                }
            }
            return
        }

        // Plain .app branch.
        isAnalyzing = true
        analyzingURL = url
        lastError = nil

        Task {
            // Run analysis off-main. We instantiate a fresh `StaticAnalyzer`
            // inside the detached task rather than capturing `self.analyzer`
            // — the analyzer is a stateless value type, and avoiding the
            // capture sidesteps Sendable-checking for class-isolated state.
            let result: Result<StaticReport, Error> = await Task.detached(priority: .userInitiated) {
                let auditorVersion = RunReport.currentAuditorVersion
                // Reuse the report from a prior scan of this exact build (e.g. a
                // "Scan all apps" pass) instead of re-running the identical,
                // expensive static analysis. A miss — or a changed app — falls
                // through to a fresh scan, whose result seeds the cache.
                if let cached = StaticReportCache.shared.load(
                    for: url, auditorVersion: auditorVersion) {
                    return .success(cached)
                }
                do {
                    let report = try StaticAnalyzer().analyze(bundleAt: url)
                    StaticReportCache.shared.store(
                        report, for: url, auditorVersion: auditorVersion)
                    return .success(report)
                } catch { return .failure(error) }
            }.value

            // Back on MainActor (this Task inherits the @MainActor isolation
            // from the surrounding class). Apply the result.
            switch result {
            case .success(let report):
                self.bundle = report.bundle
                self.staticReport = report
                self.events = []
                self.eventIndices = [:]
                // Drop the previous app's live resource samples and open
                // files/sockets so the Resource-use card and Resources tab
                // start empty for the newly-opened app instead of carrying the
                // last app's data over.
                self.resourceSamples = []
                self.openResources = []
                self.subBundleAnalyses = [:]
                self.subBundleErrors = [:]
                self.subBundleAnalyzing = []
                self.fidelityNotes = ["Static analysis only — no monitored run yet."]
                self.startedAt = Date()
                self.endedAt = Date()
                self.currentRunID = UUID()
                persistCurrentReport()
                // If we just analysed a Mac App Store app, kick off a
                // background fetch of its iTunes Lookup metadata and
                // privacy nutrition labels. The fetch updates
                // `staticReport` in place when it lands and re-saves;
                // failures stay quiet apart from the inline error
                // shown on the Dashboard's PrivacyLabelsCard.
                if report.appStoreInfo.isMASApp,
                   let bundleID = report.appStoreInfo.bundleID {
                    self.isFetchingAppStoreInfo = true
                    self.fetchAppStoreInfo(bundleID: bundleID,
                                           reportRunID: self.currentRunID)
                }
            case .failure(let error):
                // Lead with a plain-English reason (e.g. permissions, missing
                // metadata) and keep the raw message as detail.
                let kind = ScanFailureKind.classify(error)
                self.lastError = "\(kind.explanation)\n\n\(error.localizedDescription)"
            }
            self.isAnalyzing = false
            self.analyzingURL = nil
        }
    }

    // MARK: - App Store privacy labels

    /// True while the iTunes Lookup + privacy-label HTML fetch is in
    /// flight. The Dashboard's `PrivacyLabelsCard` reads this to show
    /// a spinner instead of an empty state right after a MAS bundle
    /// is selected.
    @Published var isFetchingAppStoreInfo: Bool = false

    /// Run the lookup → product-page fetch sequence and merge the
    /// result back into `staticReport`. We tag each fetch with the
    /// run ID it was kicked off for; if the user switches to a
    /// different bundle while a fetch is in flight, we drop the late
    /// result rather than overwriting the new report.
    ///
    /// `Task { … }` inherits the surrounding `@MainActor` isolation,
    /// so the bookkeeping at start and finish runs on the main actor
    /// without an explicit hop. The two `await` calls are
    /// `nonisolated` (URLSession), so the network work suspends the
    /// main actor cleanly without blocking the UI. Keeping
    /// everything in one isolation domain is also what avoids the
    /// Swift-6 sendable-capture errors we'd hit if we used
    /// `Task.detached` and tried to ferry mutable state across a
    /// `MainActor.run` boundary.
    private func fetchAppStoreInfo(bundleID: String, reportRunID: UUID) {
        Task { [weak self] in
            // ── Stage 1: iTunes Lookup. If this fails we can still
            //     show "MAS app" without metadata — surface the
            //     error so the card explains why labels are missing.
            let lookup: Result<AppStoreLookup.Result, Error>
            do {
                let r = try await AppStoreLookup.lookup(bundleID: bundleID)
                lookup = .success(r)
            } catch {
                lookup = .failure(error)
            }

            // ── Stage 2: privacy-label HTML fetch. Only run if
            //     Lookup gave us a product-page URL. Bind into one
            //     immutable tuple (`let`) so the apply step doesn't
            //     hit Swift-6's "captured var in concurrent code"
            //     warning.
            let labelOutcome: (result: AppStorePrivacyLabelFetcher.Result?, error: Error?) = await {
                guard case .success(let r) = lookup, !r.trackViewURL.isEmpty else {
                    return (nil, nil)
                }
                do {
                    let r = try await AppStorePrivacyLabelFetcher.fetch(
                        productPageURL: r.trackViewURL)
                    return (r, nil)
                } catch {
                    return (nil, error)
                }
            }()

            // ── Apply on the MainActor.
            guard let self else { return }
            guard self.currentRunID == reportRunID,
                  let report = self.staticReport,
                  report.appStoreInfo.isMASApp else {
                // Either the bundle changed under us or the report
                // is gone — drop this result rather than overwrite,
                // but clear the spinner since this fetch is done.
                self.isFetchingAppStoreInfo = false
                return
            }

            // Compose the updated AppStoreInfo. Lookup metadata
            // (if any) merges with whatever the privacy fetch
            // produced.
            let priorBundleID = report.appStoreInfo.bundleID
            let lookupValue = (try? lookup.get())

            let detailsStatus: AppStoreInfo.PrivacyDetailsStatus
            if let r = labelOutcome.result {
                detailsStatus = r.detailsStatus
            } else if let e = labelOutcome.error as? AppStorePrivacyLabelFetcher.FetchError,
                      case .noDetailsProvided = e {
                detailsStatus = .noDetailsProvided
            } else {
                detailsStatus = .unknown
            }

            let humanError: String?
            if let e = labelOutcome.error {
                humanError = Self.describe(fetchError: e)
            } else if case .failure(let e) = lookup {
                humanError = Self.describe(lookupError: e)
            } else {
                humanError = nil
            }

            let updated = AppStoreInfo(
                isMASApp: true,
                bundleID: priorBundleID,
                trackID: lookupValue?.trackID,
                trackViewURL: lookupValue?.trackViewURL,
                storeName: lookupValue?.storeName,
                sellerName: lookupValue?.sellerName,
                priceFormatted: lookupValue?.priceFormatted,
                genreName: lookupValue?.genreName,
                storeVersion: lookupValue?.storeVersion,
                storeVersionReleaseDate: lookupValue?.storeVersionReleaseDate,
                privacyLabels: labelOutcome.result?.labels,
                privacyDetailsStatus: detailsStatus,
                privacyPolicyURL: labelOutcome.result?.privacyPolicyURL,
                error: humanError
            )

            let merged = StaticReport(
                bundle: report.bundle,
                declaredPrivacyKeys: report.declaredPrivacyKeys,
                entitlements: report.entitlements,
                codeSigning: report.codeSigning,
                notarization: report.notarization,
                urlSchemes: report.urlSchemes,
                documentTypes: report.documentTypes,
                loginItems: report.loginItems,
                xpcServices: report.xpcServices,
                helpers: report.helpers,
                frameworks: report.frameworks,
                inferredCapabilities: report.inferredCapabilities,
                hardcodedURLs: report.hardcodedURLs,
                hardcodedDomains: report.hardcodedDomains,
                hardcodedPaths: report.hardcodedPaths,
                warnings: report.warnings,
                atsConfig: report.atsConfig,
                provenance: report.provenance,
                updateMechanism: report.updateMechanism,
                sdkHits: report.sdkHits,
                secrets: report.secrets,
                bundleSigning: report.bundleSigning,
                antiAnalysis: report.antiAnalysis,
                rpathAudit: report.rpathAudit,
                embeddedAssets: report.embeddedAssets,
                privacyManifest: report.privacyManifest,
                notarizationDeepDive: report.notarizationDeepDive,
                flagFindings: report.flagFindings,
                appStoreInfo: updated,
                analyzedAt: report.analyzedAt
            )
            self.staticReport = merged
            self.isFetchingAppStoreInfo = false
            self.persistCurrentReport()
        }
    }

    /// Render an `AppStoreLookup.LookupError` into a single short
    /// sentence the Dashboard can show inline.
    private static func describe(lookupError error: Error) -> String {
        if let e = error as? AppStoreLookup.LookupError {
            switch e {
            case .invalidBundleID:    return "Bundle ID couldn't be encoded for App Store lookup."
            case .rateLimited:        return "Apple rate-limited the App Store lookup. Try again in a minute."
            case .http(let s):        return "App Store lookup returned HTTP \(s)."
            case .malformedResponse:  return "App Store lookup returned an unexpected payload."
            case .notFound:           return "Bundle ID not found on the US App Store."
            case .network(let m):     return "App Store lookup network error: \(m)"
            }
        }
        return error.localizedDescription
    }

    /// Ditto for `AppStorePrivacyLabelFetcher.FetchError`.
    private static func describe(fetchError error: Error) -> String {
        if let e = error as? AppStorePrivacyLabelFetcher.FetchError {
            switch e {
            case .invalidURL:         return "App Store URL didn't validate as apps.apple.com."
            case .rateLimited:        return "Apple rate-limited the privacy-label fetch. Try again in a minute."
            case .http(let s):        return "App Store page returned HTTP \(s)."
            case .noDetailsProvided:  return "Developer hasn't provided privacy details for this app."
            case .parseFailure(let m): return "Couldn't parse privacy labels — Apple's page layout may have changed (\(m))."
            case .network(let m):     return "Privacy-label fetch network error: \(m)"
            }
        }
        return error.localizedDescription
    }

    /// Eject the currently-mounted DMG (if any). Safe to call even if
    /// nothing is mounted. After ejection the static report is still
    /// readable, but starting a monitored run will fail — the
    /// executable file is gone.
    func ejectMountedDMG() async {
        guard let mount = mountedDMG else { return }
        try? await DMGMounter.detach(mount)
        self.mountedDMG = nil
    }

    /// Disk-image extensions hdiutil knows how to mount. Conservative
    /// list — we don't want to accidentally try to mount a .iso the
    /// user dropped expecting we'd treat it as raw data.
    private static func isDiskImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "dmg" || ext == "sparseimage" || ext == "sparsebundle"
    }

    /// **Tier 2 runtime attribution.** Relaunch the analysed app's main binary
    /// under the `ConnectionTracer` interposer, capture a userspace backtrace at
    /// each `connect()`, and feed the results into the timeline as network
    /// events carrying their call stack — the "which function opened this
    /// connection" answer. Only meaningful for non-hardened-runtime binaries
    /// you can relaunch; macOS ignores the injection otherwise.
    func traceConnections() {
        guard let bundle, !isTracing else { return }
        let exe = bundle.executableURL
        let name = exe.lastPathComponent
        let hardened = staticReport?.codeSigning.hardenedRuntime ?? false
        isTracing = true
        lastError = nil
        Task {
            do {
                let conns = try await ConnectionTracer().trace(executable: exe, timeout: 20)
                let now = Date()
                var added = 0
                for c in conns where c.kind == .connect {
                    if let ev = ConnectionTracer.networkEvent(
                        from: c, processName: name, processPath: exe.path, now: now) {
                        self.upsert(.network(ev))
                        added += 1
                    }
                }
                if added == 0 {
                    self.fidelityNotes.append(hardened
                        ? "Connection trace of ‘\(name)’ captured nothing: it uses the Hardened Runtime, so macOS ignored the tracer injection. Runtime attribution only works on non-hardened binaries you can relaunch."
                        : "Connection trace of ‘\(name)’ observed no outbound connections in the trace window.")
                } else {
                    self.fidelityNotes.append("Connection trace captured \(added) outbound connection(s) from ‘\(name)’ with call-site backtraces.")
                }
            } catch {
                self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self.isTracing = false
        }
    }

    func startMonitoredRun() async {
        guard let staticReport = staticReport, let bundle = bundle else { return }

        // Upgrade tier when the helper is installed and reachable. Otherwise
        // fall back to user-space (tier A) and tell the user file events are
        // empty in the fidelity notes.
        let helperReady = helperInstaller?.status == .installed
        let tier: DynamicMonitor.Tier = helperReady ? .b : .a
        let m = DynamicMonitor(bundle: bundle, staticReport: staticReport, tier: tier)
        self.monitor = m
        self.events = []
        self.eventIndices = [:]
        self.startedAt = Date()
        self.endedAt = nil
        self.isMonitoring = true
        self.isVMRun = false   // this is a host run; keep stop() on the host path
        self.fidelityNotes = m.fidelityNotes
        self.lastError = nil

        do {
            let pid = try await m.start()

            // Sloth-style resource snapshot stream. Replaces openResources
            // on each poll. PID set is synced from the dynamic monitor when
            // process events come in (see streamTask below).
            let rm = ResourceMonitor(initialPIDs: [pid])
            self.resourceMonitor = rm
            self.openResources = []
            await rm.start()

            resourceTask = Task { [weak self] in
                guard let self else { return }
                for await snapshot in rm.stream {
                    if Task.isCancelled { break }
                    await MainActor.run { self.openResources = snapshot }
                }
            }

            // Live probe monitor — pasteboard / camera / mic / screen deltas.
            let lpm = LiveProbeMonitor()
            self.liveProbeMonitor = lpm
            self.liveProbeEvents = []
            await lpm.updatePIDs([pid])
            // Hand the inspected app's display name over so the log-stream
            // tail can match against controlcenter messages by name.
            await lpm.setTrackedAppName(bundle.bundleName ?? bundle.url
                .deletingPathExtension().lastPathComponent)
            await lpm.start()

            // System resource monitor — CPU / RAM / disk per PID tree.
            let srm = SystemResourceMonitor()
            self.resourceUsageMonitor = srm
            self.resourceSamples = []
            await srm.updatePIDs([pid])
            await srm.start()

            // USB device monitor — system-wide poll, attribution is
            // best-effort (see USBDeviceMonitor docs).
            let usb = USBDeviceMonitor()
            self.usbMonitor = usb
            self.usbChanges = []
            self.connectedUSBDevices = []
            await usb.start()
            usbTask = Task { [weak self, weak usb] in
                guard let self else { return }
                for await change in (usb?.stream ?? AsyncStream { _ in }) {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self.usbChanges.append(change)
                    }
                    // Refresh the snapshot of currently-connected devices.
                    if let usb = usb {
                        let devs = await usb.currentDevices
                        await MainActor.run { self.connectedUSBDevices = devs }
                    }
                }
            }
            resourceUsageTask = Task { [weak self] in
                guard let self else { return }
                for await sample in srm.stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self.resourceSamples.append(sample)
                        if self.resourceSamples.count > self.maxResourceSamples {
                            let overflow = self.resourceSamples.count - self.maxResourceSamples
                            self.resourceSamples.removeFirst(overflow)
                        }
                    }
                }
            }
            liveProbeTask = Task { [weak self] in
                guard let self else { return }
                for await probe in lpm.stream {
                    if Task.isCancelled { break }
                    await MainActor.run { self.liveProbeEvents.append(probe) }
                }
            }

            // Single consumer of m.stream: upsert events AND keep the
            // resource monitor's PID set in sync as the process tree grows.
            // Two consumers on the same AsyncStream is undefined behavior,
            // so we do both jobs in this loop.
            streamTask = Task { [weak self, weak rm, weak lpm, weak srm] in
                guard let self else { return }
                for await event in m.stream {
                    await MainActor.run { self.upsert(event) }
                    if case .process = event,
                       let pids = await self.monitor?.currentTrackedPIDs() {
                        await rm?.updatePIDs(pids)
                        await lpm?.updatePIDs(pids)
                        await srm?.updatePIDs(pids)
                    }
                }
            }

            // If the helper is available, kick off file monitoring and pump
            // its events through `monitor.ingest(file:)` so they get
            // classified and surfaced to the UI.
            if helperReady, let installer = helperInstaller {
                do {
                    try await installer.startFileMonitor(forPID: pid)
                    helperEventTask = Task { [weak self] in
                        guard let self else { return }
                        for await fileEvent in installer.fileEventStream {
                            // Skip events that arrive after we've stopped.
                            if Task.isCancelled { break }
                            await self.monitor?.ingest(file: fileEvent)
                        }
                    }
                } catch {
                    // Helper failure is non-fatal — the run continues without
                    // file monitoring. Surface the error so the user knows.
                    self.lastError = "File monitoring unavailable: \(error.localizedDescription)"
                }
            }
        } catch {
            self.lastError = error.localizedDescription
            self.isMonitoring = false
        }
    }

    // MARK: - VM run

    /// True when the guest agent has been confirmed reachable and we're not
    /// already running. Gates the "Run in VM" button.
    var canStartVMRun: Bool {
        if case .connected = vmConnection { return !isMonitoring }
        return false
    }

    /// Fidelity caveats specific to a VM run — guest observations come over
    /// the wire from `privacycommand-guest`, and path classification is
    /// host-relative.
    static let vmFidelityNotes: [String] = [
        "This run happened inside a VM. Observations are reported by the privacycommand-guest agent over TCP and reflect the guest's process tree, not your host.",
        "File-path categories are classified host-side, so a guest whose username differs from yours may show some paths as ‘home (other)’ rather than the exact category.",
        "Guest network destinations may be reachable from the host or guest-only depending on the VM's networking mode."
    ]

    /// Probe the configured VM address and update `vmConnection`. Safe to
    /// call repeatedly (e.g. a Refresh button).
    func testVMConnection() async {
        let host = vmHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            vmConnection = .unreachable("Enter the VM's IP address first.")
            return
        }
        guard let port = UInt16(exactly: vmPort), port > 0 else {
            vmConnection = .unreachable("Port must be between 1 and 65535.")
            return
        }
        vmConnection = .checking
        switch await VMGuestSession.probe(host: host, port: port) {
        case .connected(let info):
            vmConnection = .connected(hostName: info.hostName,
                                      macOSVersion: info.macOSVersion,
                                      guestVersion: info.guestVersion)
        case .versionMismatch(let g, let h):
            vmConnection = .versionMismatch(guestVersion: g, hostVersion: h)
        case .unreachable(let why):
            vmConnection = .unreachable(why)
        }
    }

    /// Offload a whole-app decompilation to the guest VM: connect to the agent,
    /// ask it to run Ghidra on the bundle at `guestBundlePath` (a path inside
    /// the guest), and collect the streamed classes into `vmDecompileResult`.
    /// The guest VM image must have Ghidra installed (see docs/GUEST_AGENT.md).
    func decompileInVM(guestBundlePath: String, scope: DecompileScope) async {
        let host = vmHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = guestBundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = UInt16(exactly: vmPort), port > 0 else {
            vmDecompileError = "Set the VM IP and port, then test the connection first."
            return
        }
        guard !path.isEmpty else {
            vmDecompileError = "Enter the path to the .app inside the VM."
            return
        }
        vmDecompiling = true
        vmDecompileError = nil
        vmDecompileResult = nil
        let session = VMGuestSession(host: host, port: port)
        do {
            vmDecompileResult = try await session.decompile(guestBundlePath: path, scope: scope)
        } catch {
            vmDecompileError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await session.stop()
        vmDecompiling = false
    }

    /// Start a monitored run *inside the VM*: connect to the guest agent and
    /// ask it to launch + monitor the bundle at `guestBundlePath` (a path on
    /// the guest's filesystem). Guest observations stream into the same
    /// `events` / `liveProbeEvents` / `resourceSamples` the host tabs read.
    func startMonitoredRunInVM(guestBundlePath: String) async {
        let host = vmHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = guestBundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = UInt16(exactly: vmPort), port > 0 else {
            lastError = "Set the VM IP and port, then test the connection first."
            return
        }
        guard !path.isEmpty else {
            lastError = "Enter the path to the .app inside the VM (e.g. /Users/you/Downloads/Foo.app)."
            return
        }

        // Reuse the host's classifiers so VM file events colour the same way.
        let riskClassifier: RiskClassifier
        if let staticReport {
            riskClassifier = RiskClassifier(
                declaredCategories: Set(staticReport.declaredPrivacyKeys.map(\.category)))
        } else {
            riskClassifier = RiskClassifier()
        }
        let session = VMGuestSession(host: host, port: port,
                                     ownerBundleURL: bundle?.url,
                                     pathClassifier: PathClassifier(),
                                     riskClassifier: riskClassifier)
        self.vmSession = session

        // Reset run state, mirroring startMonitoredRun().
        self.events = []
        self.eventIndices = [:]
        self.liveProbeEvents = []
        self.resourceSamples = []
        self.openResources = []
        self.usbChanges = []
        self.connectedUSBDevices = []
        self.startedAt = Date()
        self.endedAt = nil
        self.lastError = nil
        self.isVMRun = true
        self.isMonitoring = true
        self.fidelityNotes = Self.vmFidelityNotes

        // Fan the guest's four streams into the published arrays. One task so
        // teardown is a single cancel.
        vmStreamTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    for await event in session.events {
                        await MainActor.run { self?.upsert(event) }
                    }
                }
                group.addTask { [weak self] in
                    for await probe in session.liveProbes {
                        await MainActor.run { self?.liveProbeEvents.append(probe) }
                    }
                }
                group.addTask { [weak self] in
                    for await sample in session.resourceSamples {
                        await MainActor.run { self?.appendResourceSample(sample) }
                    }
                }
                group.addTask { [weak self] in
                    for await notice in session.notices {
                        await self?.handleVMNotice(notice)
                    }
                }
            }
        }

        do {
            let info = try await session.start(guestBundlePath: path)
            self.vmConnection = .connected(hostName: info.hostName,
                                           macOSVersion: info.macOSVersion,
                                           guestVersion: info.guestVersion)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            self.lastError = message
            // The agent went away between the test and the run — reflect that
            // in the badge so the user isn't left thinking it's still connected.
            if case VMGuestSession.SessionError.versionMismatch(let g, let h) = error {
                self.vmConnection = .versionMismatch(guestVersion: g, hostVersion: h)
            } else {
                self.vmConnection = .unreachable(message)
            }
            await stopMonitoredRun()
        }
    }

    private func appendResourceSample(_ sample: SystemResourceMonitor.Sample) {
        resourceSamples.append(sample)
        if resourceSamples.count > maxResourceSamples {
            resourceSamples.removeFirst(resourceSamples.count - maxResourceSamples)
        }
    }

    private func handleVMNotice(_ notice: VMGuestSession.Notice) async {
        switch notice {
        case .log(let level, let message):
            if level == "error" { lastError = message }
        case .targetExited:
            if isMonitoring { await stopMonitoredRun() }
        case .agentError(let message):
            lastError = message
            if isMonitoring { await stopMonitoredRun() }
        }
    }

    /// Tear down a VM run: stop the guest session and cancel the stream
    /// fan-out. Then persist like any other run.
    private func stopVMRun() async {
        isVMRun = false
        vmStreamTask?.cancel()
        vmStreamTask = nil
        await vmSession?.stop()
        vmSession = nil
        persistCurrentReport()
    }

    func stopMonitoredRun() async {
        // Flip the UI state FIRST so the toolbar / dashboard immediately
        // reflect "stopped" — the helper RPC and monitor.stop() can take
        // up to a couple of seconds and the user shouldn't see live activity
        // continue while we wind down.
        self.isMonitoring = false
        self.endedAt = Date()

        // Reset the live Resource-use card and Resources tab. Both are
        // live-only state (never persisted), so once the run stops they'd
        // otherwise sit frozen looking like current activity. Clearing returns
        // them to their pre-run empty state. Done before the VM branch below so
        // it covers VM runs too.
        self.resourceSamples = []
        self.openResources = []

        // A VM run has none of the host-side monitors / helper / PID tree to
        // tear down — just the guest session. Branch out early.
        if isVMRun {
            await stopVMRun()
            return
        }

        // Capture the tracked PID set BEFORE we tear the monitor down,
        // otherwise we'd lose the list and not be able to terminate the
        // target process tree.
        let trackedPIDs = await monitor?.currentTrackedPIDs() ?? []

        // Cancel forwarding tasks immediately so no further events get
        // upserted into `events`. The polling actors also gate yields on
        // an internal `stopped` flag (set in their own stop()), so even
        // events captured by an in-flight lsof don't reach the UI.
        helperEventTask?.cancel()
        helperEventTask = nil
        streamTask?.cancel()
        streamTask = nil
        resourceTask?.cancel()
        resourceTask = nil

        // Now do the slow part: tell the helper to stop and stop the
        // monitor. Any events these emit during shutdown are dropped at
        // the source.
        if helperInstaller?.status == .installed {
            await helperInstaller?.stopFileMonitor()
        }
        await monitor?.stop()
        await resourceMonitor?.stop()
        resourceMonitor = nil
        await liveProbeMonitor?.stop()
        liveProbeMonitor = nil
        liveProbeTask?.cancel()
        liveProbeTask = nil
        await resourceUsageMonitor?.stop()
        resourceUsageMonitor = nil
        resourceUsageTask?.cancel()
        resourceUsageTask = nil
        await usbMonitor?.stop()
        usbMonitor = nil
        usbTask?.cancel()
        usbTask = nil

        // If the kill switch was engaged when the user clicked Stop, we
        // need to SIGCONT every PID first — SIGTERM on a stopped process
        // is queued, so the app can never act on it (won't get to drain
        // its run loop) and the cleanup grace would be wasted.
        if isPaused {
            Self.resumeTargetTree(trackedPIDs)
            isPaused = false
        }

        // Lift the network kill switch so we don't leave the user with
        // a half-blocked machine after they stop the run.
        if isNetworkBlocked, let installer = helperInstaller {
            try? await installer.removeKillSwitch()
            isNetworkBlocked = false
        }

        // Terminate the target's whole process tree. SIGTERM first so the
        // app can save state / unwind cleanly; SIGKILL after a 2 s grace
        // for anything still alive.
        Self.terminateTargetTree(trackedPIDs)

        // Persist the now-final report so it shows up in History.
        persistCurrentReport()
    }

    /// Read-only accessor exposed to the AppDelegate so it can fetch the
    /// live PID set during applicationWillTerminate.
    func currentlyTrackedPIDsForExit() async -> Set<Int32> {
        await monitor?.currentTrackedPIDs() ?? []
    }

    /// Toggle the process-level kill switch. SIGSTOP freezes every
    /// tracked PID; SIGCONT resumes them. While paused the app can't do
    /// anything — no network, no file I/O, no code execution at all.
    func toggleKillSwitch() async {
        guard isMonitoring else { return }
        let pids = await monitor?.currentTrackedPIDs() ?? []
        if isPaused {
            Self.resumeTargetTree(pids)
            isPaused = false
        } else {
            Self.pauseTargetTree(pids)
            isPaused = true
        }
    }

    /// Toggle the network-level kill switch. Requires the privileged
    /// helper. When engaged, asks the helper to install a pf anchor
    /// that drops outbound traffic to every IP the inspected app has
    /// been seen contacting during the run. The process keeps running
    /// — observe how it handles connection failures.
    ///
    /// **Limitations** — pf can't filter by PID on macOS; the block is
    /// system-wide for the chosen IPs. Apps that contact destinations
    /// the inspected app *hasn't* visited yet won't be blocked. New
    /// destinations are not automatically added; toggle off and on again
    /// to refresh the address set.
    func toggleNetworkKillSwitch() async {
        guard let installer = helperInstaller else {
            lastError = "Network kill switch requires the file-monitoring helper to be installed."
            return
        }
        if isNetworkBlocked {
            do {
                try await installer.removeKillSwitch()
                isNetworkBlocked = false
            } catch {
                lastError = "Couldn't lift network kill switch: \(error.localizedDescription)"
            }
        } else {
            // Pull every IP the inspected app has contacted so far.
            let addresses: [String] = events.compactMap {
                if case .network(let n) = $0 { return n.remoteEndpoint.address }
                return nil
            }
            let unique = Array(Set(addresses)).filter { !$0.isEmpty && $0 != "0.0.0.0" }
            guard !unique.isEmpty else {
                lastError = "No destinations captured yet — let the run gather some traffic first."
                return
            }
            do {
                try await installer.installKillSwitch(addresses: unique)
                isNetworkBlocked = true
            } catch {
                lastError = "Couldn't engage network kill switch: \(error.localizedDescription)"
            }
        }
    }

    /// Send SIGSTOP to every PID. Static so it can be called from
    /// non-MainActor contexts (e.g. AppDelegate hooks). Only sends to
    /// PIDs > 1 so we never accidentally target launchd.
    static func pauseTargetTree(_ pids: Set<Int32>) {
        for pid in pids where pid > 1 {
            kill(pid, SIGSTOP)
        }
    }

    /// Send SIGCONT to every PID. Idempotent — sending CONT to a
    /// non-stopped process is a no-op.
    static func resumeTargetTree(_ pids: Set<Int32>) {
        for pid in pids where pid > 1 {
            kill(pid, SIGCONT)
        }
    }

    /// Send SIGTERM to every PID, then escalate to SIGKILL after a short
    /// delay for any still alive. Static so it can be called from
    /// applicationWillTerminate without going through MainActor.
    static func terminateTargetTree(_ pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        for pid in pids where pid > 1 {
            kill(pid, SIGTERM)
        }
        // Background escalation pass.
        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            for pid in pids where pid > 1 {
                // signal 0 is "is the process still alive?" — returns 0 on
                // success (alive), -1 + ESRCH if dead.
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    // MARK: - Run history

    func refreshRecents() {
        // Outer Task inherits @MainActor from the class; the detached inner
        // task does the disk I/O off-main. When `await .value` returns we're
        // back on MainActor, so assigning to `recentRuns` is isolation-safe.
        Task {
            let metas = await Task.detached { RunStore.shared.list() }.value
            self.recentRuns = metas
        }
    }

    func loadFromStore(id: UUID) {
        do {
            let report = try RunStore.shared.load(id: id)
            self.currentRunID = report.id
            self.bundle = report.bundle
            self.staticReport = report.staticReport
            self.events = report.events
            self.eventIndices = Dictionary(
                uniqueKeysWithValues: report.events.enumerated().map { ($1.id, $0) }
            )
            // Historical reports don't carry live resource samples or open
            // files/sockets; clear any left over from a prior live run so the
            // Resource-use card and Resources tab match the loaded run rather
            // than the last thing monitored.
            self.resourceSamples = []
            self.openResources = []
            self.subBundleAnalyses = [:]
            self.subBundleErrors = [:]
            self.subBundleAnalyzing = []
            self.fidelityNotes = report.fidelityNotes
            self.startedAt = report.startedAt
            self.endedAt = report.endedAt
            self.isMonitoring = false
            self.lastError = nil
        } catch {
            self.lastError = "Failed to load run: \(error.localizedDescription)"
        }
    }

    /// Lazy: kicks off a static analysis of a nested bundle (XPC service,
    /// helper, login item) on a background task and stores the result.
    /// Idempotent — repeated calls are no-ops while one is in flight or has
    /// already completed.
    func analyzeSubBundle(at url: URL) {
        guard subBundleAnalyses[url] == nil,
              !subBundleAnalyzing.contains(url) else { return }
        subBundleAnalyzing.insert(url)
        subBundleErrors[url] = nil

        // Same pattern as refreshRecents: outer Task is @MainActor, the
        // synchronous heavy work (binary scan, codesign, spctl) runs in a
        // detached task; we return to MainActor after `await .value`.
        Task {
            let outcome: Result<StaticReport, Error> = await Task.detached(priority: .userInitiated) {
                let auditorVersion = RunReport.currentAuditorVersion
                if let cached = StaticReportCache.shared.load(
                    for: url, auditorVersion: auditorVersion) {
                    return .success(cached)
                }
                do {
                    let report = try StaticAnalyzer().analyze(bundleAt: url)
                    StaticReportCache.shared.store(
                        report, for: url, auditorVersion: auditorVersion)
                    return .success(report)
                } catch { return .failure(error) }
            }.value

            subBundleAnalyzing.remove(url)
            switch outcome {
            case .success(let report):
                subBundleAnalyses[url] = report
            case .failure(let error):
                subBundleErrors[url] = error.localizedDescription
            }
        }
    }

    func deleteRun(id: UUID) {
        do {
            try RunStore.shared.delete(id: id)
            // If the user deleted the current run, leave the in-memory copy
            // alone but generate a fresh ID so the next save lands elsewhere.
            if id == currentRunID { currentRunID = UUID() }
            refreshRecents()
        } catch {
            self.lastError = "Failed to delete run: \(error.localizedDescription)"
        }
    }

    /// Save the current state to the run store under `currentRunID`.
    /// Called automatically after select() and stopMonitoredRun().
    private func persistCurrentReport() {
        // Respect the "Save runs to history automatically" setting. When off,
        // runs are only written to disk via explicit Export actions. Unset
        // defaults to on (matches the @AppStorage default in Settings).
        let autoSave = UserDefaults.standard.object(forKey: "autoSaveRuns") as? Bool ?? true
        guard autoSave else { return }
        guard let report = currentRunReport() else { return }
        Task {
            // Save off-main. Errors are logged but not surfaced — persistence
            // failures shouldn't block the user's foreground work.
            await Task.detached {
                do { _ = try RunStore.shared.save(report) }
                catch { print("[AnalysisCoordinator] Failed to persist run: \(error)") }
            }.value
            let metas = await Task.detached { RunStore.shared.list() }.value
            self.recentRuns = metas
        }
    }

    func exportJSON() {
        guard let report = currentRunReport() else { return }
        savePanel(suggestedName: suggestedExportFilename(report: report, ext: "json"),
                  utType: .json) { url in
            try? JSONExporter.write(report: report, to: url)
        }
    }

    func exportHTML() {
        guard let report = currentRunReport() else { return }
        savePanel(suggestedName: suggestedExportFilename(report: report, ext: "html"),
                  utType: .html) { url in
            try? HTMLExporter.write(report: report, to: url)
        }
    }

    func exportPDF() {
        guard let report = currentRunReport() else { return }
        savePanel(suggestedName: suggestedExportFilename(report: report, ext: "pdf"),
                  utType: .pdf) { url in
            Task { [weak self] in
                do {
                    try await PDFExporter.write(report: report, to: url)
                } catch {
                    self?.lastError = "PDF export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - State for menu items

    var canStartRun: Bool { staticReport != nil && !isMonitoring }
    var canStopRun:  Bool { isMonitoring }
    var hasRunReport: Bool { currentRunReport() != nil }

    /// Live risk score combining static + dynamic findings. Recomputes on
    /// every `events` change because computed properties don't cache and
    /// SwiftUI re-reads them each body render.
    var riskScore: RiskScore? {
        guard let staticReport else { return nil }
        return RiskScorer().score(staticReport: staticReport, events: events)
    }

    /// Live behavioural anomaly report. Same pattern as `riskScore` —
    /// recomputed every time `events` changes.
    var behaviorReport: BehaviorReport {
        BehaviorAnalyzer.analyse(events: events, staticReport: staticReport)
    }

    /// Aggregated summary of the events captured so far — recomputed each
    /// time `events` changes, so the Dashboard can re-render with the latest
    /// counts/top-hosts. Returns nil before a monitored run has begun.
    var runSummary: RunSummary? {
        guard let m = monitor, !events.isEmpty else { return nil }
        return m.summarize(events: events)
    }

    /// Wall-clock duration of the run; nil before a run starts.
    var runDurationSeconds: Int? {
        guard let started = startedAt else { return nil }
        let end = endedAt ?? Date()
        return Int(end.timeIntervalSince(started))
    }

    // MARK: - Helpers

    /// Append a new event or replace an existing one with the same id. Network
    /// monitors re-emit the same `NetworkEvent` (preserved UUID, updated bytes)
    /// every poll cycle, and SwiftUI's `ForEach` requires unique ids — without
    /// the upsert we'd get the "ID … occurs multiple times" warnings.
    private func upsert(_ event: DynamicEvent) {
        if let idx = eventIndices[event.id] {
            events[idx] = event
        } else {
            eventIndices[event.id] = events.count
            events.append(event)
        }
    }

    private func currentRunReport() -> RunReport? {
        guard let bundle, let staticReport else { return nil }
        let summary = monitor?.summarize(events: events)
            ?? RunSummary(
                processCount: 0, fileEventCount: 0, networkEventCount: 0,
                topRemoteHosts: [], topPathCategories: [],
                surprisingEventCount: 0,
                riskScore: RiskScorer().score(staticReport: staticReport, events: events)
            )
        let behavior = BehaviorAnalyzer.analyse(
            events: events, staticReport: staticReport)
        return RunReport(
            id: currentRunID,
            auditorVersion: RunReport.currentAuditorVersion,
            startedAt: startedAt ?? Date(),
            endedAt: endedAt ?? Date(),
            bundle: bundle,
            staticReport: staticReport,
            events: events,
            summary: summary,
            fidelityNotes: fidelityNotes,
            behavior: behavior,
            liveProbeEvents: liveProbeEvents
        )
    }

    private func savePanel(suggestedName: String, utType: UTType, then: (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [utType]
        if panel.runModal() == .OK, let url = panel.url {
            then(url)
        }
    }

    /// Build a friendly default filename for the export panel —
    /// `<bundle>-<date>-<runID-prefix>-runreport.<ext>`. The short
    /// run-ID prefix disambiguates multiple runs of the same app on the
    /// same day so the user doesn't get a "report (1).json" cascade.
    private func suggestedExportFilename(report: RunReport, ext: String) -> String {
        let appPart = sanitize(
            report.bundle.bundleName
            ?? report.bundle.url.deletingPathExtension().lastPathComponent
        )
        let datePart: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmmss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: report.startedAt)
        }()
        let idPart = String(report.id.uuidString.prefix(8))
        return "\(appPart)-\(datePart)-\(idPart)-runreport.\(ext)"
    }

    /// Replace anything that isn't safe in a file name with `-`. We're
    /// strict about whitelist rather than blacklist to handle non-ASCII
    /// app names like "财付宝" or "Café" — Finder accepts these but the
    /// resulting filenames are awkward to share, so we ASCII-fold.
    private func sanitize(_ s: String) -> String {
        let safe = s.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            // Keep alphanumerics, dot, hyphen, underscore.
            if (0x30...0x39).contains(v) || (0x41...0x5A).contains(v)
               || (0x61...0x7A).contains(v) || v == 0x2E || v == 0x2D || v == 0x5F {
                return Character(scalar)
            }
            return "-"
        }
        // Collapse runs of `-` and trim.
        let collapsed = String(safe).replacingOccurrences(
            of: "-+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty
            ? "Bundle" : collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
