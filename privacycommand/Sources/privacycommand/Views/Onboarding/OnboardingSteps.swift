import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

// MARK: - Reusable step shell

private struct StepShell<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var iconColor: Color = .accentColor
    let content: Content

    init(icon: String, title: String, subtitle: String, iconColor: Color = .accentColor,
         @ViewBuilder body: () -> Content) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.iconColor = iconColor
        self.content = body()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(iconColor)
                    .frame(width: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle.bold())
                    Text(subtitle).font(.title3).foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Welcome

struct WelcomeStep: View {
    var body: some View {
        StepShell(
            icon: "shield.lefthalf.filled",
            title: "See what your apps actually do",
            subtitle: "Catch trackers, sneaky permissions, and unexpected behaviour."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Drop any Mac app onto privacycommand and you'll get a plain-English report on what it collects, who it talks to, and what it does in the background. Nothing about the apps you inspect ever leaves your Mac.")

                FeatureRow(icon: "doc.text.magnifyingglass",
                           title: "What's inside the app",
                           desc: "Every permission it asks for, every tracker SDK it ships, and any credentials the developer accidentally baked in.")
                FeatureRow(icon: "network",
                           title: "Where it sends your data",
                           desc: "A live list of every server the app talks to while it runs — ad networks, analytics, the dev's API, everything.")
                FeatureRow(icon: "folder.badge.questionmark",
                           title: "Which files it touches",
                           desc: "Optional. Needs a one-time admin install — we'll walk you through it next.",
                           muted: true)

                Text("All analysis runs locally on your Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Static analysis

struct StaticAnalysisStep: View {
    var body: some View {
        StepShell(
            icon: "doc.text.magnifyingglass",
            title: "Inspect an app before you even open it",
            subtitle: "You'll see the report fill in as soon as you drop a bundle."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                bullet("Every permission the app will ask for — camera, microphone, location, contacts, calendar, full disk access — and whether the developer's reason makes sense.")
                bullet("Tracker SDKs the app ships with: Google Analytics, Firebase, Sentry, Mixpanel, Crashlytics, AdMob, and dozens more.")
                bullet("Hard-coded credentials the developer accidentally left in — AWS keys, Stripe tokens, GitHub PATs, private SSH keys.")
                bullet("Whether it's properly signed, notarised by Apple, and where you originally downloaded it from.")
                bullet("Helpers, login items, frameworks, and bundled services — each gets its own mini-report so nothing hides inside the bundle.")
                bullet("A side-by-side check: **does the app actually need everything it's asking for?** Apps that declare permissions they don't use — or use APIs they didn't declare — get flagged.")

                HStack(spacing: 8) {
                    FidelityBadge(.staticAnalysis)
                    Text("Read straight from the .app file. No running it required.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text)
        }
    }
}

// MARK: - Network monitoring

struct NetworkMonitoringStep: View {
    var body: some View {
        StepShell(
            icon: "network",
            title: "See where the app sends your data",
            subtitle: "Every server it talks to, while it's running."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Hit Start when you're ready. Use the app like you normally would. privacycommand watches every connection it opens — analytics, ads, crash reporters, the developer's own backend, everything — and you get a live, ranked list of who it's talking to and how much.")

                HStack(alignment: .top, spacing: 12) {
                    canColumn
                    Divider().frame(maxHeight: 200)
                    cantColumn
                }

                HStack(spacing: 8) {
                    FidelityBadge(.bestEffort)
                    Text("Very short-lived connections may slip through; everything that lasts more than half a second is captured.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var canColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You'll see").font(.headline).foregroundStyle(.green)
            row("Hostname and IP of every server the app contacts")
            row("Port and protocol (HTTPS, websockets, etc.)")
            row("Which part of the app made the connection")
            row("How much data went each way")
            row("How often it's connecting and to whom")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var cantColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You won't see").font(.headline).foregroundStyle(.orange)
            row("The contents of encrypted (HTTPS) traffic — that's the point of HTTPS.")
            row("Connections that open and close in milliseconds.")
            row("Network activity from before you clicked Start.")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func row(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }
}

// MARK: - File monitoring (the install step)

struct FileMonitoringStep: View {
    @EnvironmentObject var helperInstaller: HelperInstaller

    var body: some View {
        StepShell(
            icon: "folder.badge.gearshape",
            title: "Watching file activity needs admin permission (optional)",
            subtitle: "macOS keeps file activity private from other apps unless you opt in.",
            iconColor: .blue
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("To show you which files an app reads or writes — including sneaky reads of `~/Documents`, `~/.ssh`, or other apps' caches — privacycommand needs to install a small admin helper. macOS will ask for your password once. **You can skip this step entirely**; everything else still works.")

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield").font(.title2).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What you're agreeing to").font(.headline)
                        Text("• A tiny background helper that **only** privacycommand itself can talk to.")
                        Text("• It only runs while you're actively monitoring an app — it stops on its own when the run ends.")
                        Text("• It only watches the app you chose. It doesn't read the contents of any file, just records which paths got opened.")
                        Text("• You can uninstall it at any time from this same screen.")
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 8))

                statusCard
                actionRow
            }
            .onAppear { helperInstaller.refresh() }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        let s = helperInstaller.status
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: statusIcon(s)).foregroundStyle(statusColor(s)).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle(s)).font(.headline)
                Text(statusSubtitle(s)).font(.callout).foregroundStyle(.secondary)
                if let v = helperInstaller.helperVersion {
                    Text(v).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(statusColor(s).opacity(0.08), in: .rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            switch helperInstaller.status {
            case .notFound:
                Text("The helper isn't included in this build of the app. File monitoring won't be available — feel free to skip this step.")
                    .font(.callout).foregroundStyle(.orange)
            case .notRegistered, .unknown:
                Button("Install file-monitoring helper") { helperInstaller.install() }
                    .buttonStyle(.borderedProminent)
            case .requiresApproval:
                Button("Open Login Items in System Settings") { helperInstaller.openSystemSettings() }
                    .buttonStyle(.borderedProminent)
                Text("Find **privacycommand** in the list and turn its switch on, then come back here.")
                    .font(.callout).foregroundStyle(.secondary)
            case .installed:
                Button("Check it's working") { _ = helperInstaller.ensureConnected() }
                Button("Uninstall", role: .destructive) { helperInstaller.uninstall() }
            case .error:
                Button("Try again") { helperInstaller.install() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
            Button("Refresh") { helperInstaller.refresh() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Status visuals

    private func statusIcon(_ s: HelperInstaller.Status) -> String {
        switch s {
        case .unknown:           return "questionmark.circle"
        case .notFound:          return "shippingbox"
        case .notRegistered:     return "play.circle"
        case .requiresApproval:  return "hand.raised.circle"
        case .installed:         return "checkmark.shield.fill"
        case .error:             return "exclamationmark.triangle.fill"
        }
    }
    private func statusColor(_ s: HelperInstaller.Status) -> Color {
        switch s {
        case .unknown, .notRegistered: return .secondary
        case .notFound:                return .orange
        case .requiresApproval:        return .blue
        case .installed:               return .green
        case .error:                   return .red
        }
    }
    private func statusTitle(_ s: HelperInstaller.Status) -> String {
        switch s {
        case .unknown:           return "Checking…"
        case .notFound:          return "File monitoring not available in this build"
        case .notRegistered:     return "Not installed"
        case .requiresApproval:  return "Waiting for you to approve it"
        case .installed:         return "All set"
        case .error(let msg):    return "Something went wrong: \(msg)"
        }
    }
    private func statusSubtitle(_ s: HelperInstaller.Status) -> String {
        switch s {
        case .unknown:           return "Just a moment, checking…"
        case .notFound:          return "You can still use everything else — skip this step."
        case .notRegistered:     return "Click the install button below to enable file monitoring."
        case .requiresApproval:  return "macOS needs you to switch it on in Login Items."
        case .installed:         return "File activity will be captured the next time you start a run."
        case .error:             return "Try again, or skip this step and use the rest of the app."
        }
    }
}

// MARK: - All set

struct AllSetStep: View {
    @EnvironmentObject var helperInstaller: HelperInstaller
    var body: some View {
        StepShell(
            icon: "sparkles",
            title: "Ready when you are",
            subtitle: "Drag any app onto the window — or pick one with ⌘O.",
            iconColor: .green
        ) {
            VStack(alignment: .leading, spacing: 14) {
                step("1", "Drag an app from /Applications (or anywhere) onto the window. The Summary tab fills in straight away.")
                step("2", "Skim the report — permissions, trackers, the developer's signing posture, where it phones home, and anything that looks off.")
                step("3", "When you want to see it in action, hit **Start monitored run**. The app launches under privacycommand's eye and you'll see network, processes, and (if you installed the helper) file activity live.")
                step("4", "Use the app the way you normally would. Click **Stop** when you're done, then save a report from the Export menu to share with someone or keep for later.")

                Divider().padding(.vertical, 4)

                if case .installed = helperInstaller.status {
                    Label("File monitoring is set up — you'll see file activity in the report.",
                          systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("File monitoring is off. Everything else still works — install the helper later from the Help menu if you change your mind.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(n)
                .font(.headline).bold()
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            Text(text).font(.body)
        }
    }
}

// MARK: - Small reusable bits

private struct FeatureRow: View {
    let icon: String
    let title: String
    let desc: String
    var muted: Bool = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(muted ? .secondary : Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(muted ? .secondary : .primary)
                Text(desc).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
