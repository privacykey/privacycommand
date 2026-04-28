import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

struct OnboardingView: View {
    @EnvironmentObject var helperInstaller: HelperInstaller
    @State private var step: Step = .welcome
    let onComplete: () -> Void

    enum Step: Int, CaseIterable {
        case welcome
        case staticAnalysis
        case networkMonitoring
        case fileMonitoring
        case allSet

        var title: String {
            switch self {
            case .welcome:           return "Welcome to privacycommand"
            case .staticAnalysis:    return "Static analysis"
            case .networkMonitoring: return "Network monitoring"
            case .fileMonitoring:    return "File monitoring (optional)"
            case .allSet:            return "You're all set"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            stepIndicator
                .padding(.top, 24)
                .padding(.horizontal, 32)

            // Step content
            ScrollView {
                Group {
                    switch step {
                    case .welcome:           WelcomeStep()
                    case .staticAnalysis:    StaticAnalysisStep()
                    case .networkMonitoring: NetworkMonitoringStep()
                    case .fileMonitoring:    FileMonitoringStep()
                    case .allSet:            AllSetStep()
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 32)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Bottom navigation
            HStack(spacing: 12) {
                Button("Skip onboarding") { onComplete() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Back") { goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(step == .welcome)

                Button(step == .allSet ? "Get started" : "Continue") {
                    goForward()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    // MARK: - Step indicator

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Navigation

    private func goForward() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        } else {
            onComplete()
        }
    }
    private func goBack() {
        if let prev = Step(rawValue: step.rawValue - 1) {
            step = prev
        }
    }
}
