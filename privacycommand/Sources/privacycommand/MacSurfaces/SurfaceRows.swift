#if os(macOS)
import ServiceManagement
import SwiftUI

/// A row label with an ⓘ button. Explanations go in the popover; captions
/// under a row are for live status and warnings only.
public struct SurfaceInfoLabel: View {
    private let title: String
    private let info: String
    @State private var isShowing = false

    public init(_ title: String, info: String) {
        self.title = title
        self.info = info
    }

    public var body: some View {
        HStack(spacing: 5) {
            Text(title)
            Button {
                isShowing.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(info)
            .accessibilityLabel("About \(title)")
            .popover(isPresented: $isShowing, arrowEdge: .trailing) {
                Text(info)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(width: 280, alignment: .leading)
            }
        }
    }
}

/// What macOS reports for the app's login item.
public enum SurfaceLoginItemState: Sendable, Equatable {
    case enabled
    case off
    case requiresApproval
    case unavailable

    public init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .notRegistered: self = .off
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .unavailable
        @unknown default: self = .unavailable
        }
    }

    public var isOn: Bool { self == .enabled || self == .requiresApproval }

    /// Shown under the toggle. Nil when off, where the toggle says enough.
    public var caption: String? {
        switch self {
        case .enabled: "Enabled"
        case .off: nil
        case .requiresApproval: "Waiting for approval in System Settings ▸ General ▸ Login Items"
        case .unavailable: "Unavailable for this copy of the app"
        }
    }
}

/// Launch at login for menu bar utilities, with the real state as a caption.
public struct SurfaceLaunchAtLoginRow: View {
    private let app: SurfaceApp
    @State private var state = SurfaceLoginItemState(SMAppService.mainApp.status)
    @State private var failure: String?

    public init(app: SurfaceApp) {
        self.app = app
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open \(app.name) at login", isOn: Binding(
                get: { state.isOn },
                set: { set($0) }
            ))
            if let text = failure ?? state.caption {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
        }
        .onAppear { state = SurfaceLoginItemState(SMAppService.mainApp.status) }
    }

    private func set(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        state = SurfaceLoginItemState(SMAppService.mainApp.status)
    }
}

/// How much a destructive action asks before it runs.
public enum SurfaceGate: Sendable, Equatable {
    /// Settings, caches, logs: one confirmation that names what is lost.
    case confirm
    /// User data: the confirmation, then this word typed out.
    case typed(String)

    public func accepts(_ input: String) -> Bool {
        switch self {
        case .confirm: true
        case let .typed(word): input.trimmingCharacters(in: .whitespaces) == word
        }
    }
}

/// A destructive button that never acts on the first click.
public struct SurfaceDestructiveButton: View {
    private let title: String
    private let gate: SurfaceGate
    private let question: String
    private let consequence: String
    private let confirmTitle: String
    private let action: @MainActor () -> Void

    @State private var isConfirming = false
    @State private var isTyping = false
    @State private var typed = ""

    /// `title` ends in an ellipsis because it opens a dialog.
    public init(
        _ title: String,
        gate: SurfaceGate,
        question: String,
        consequence: String,
        confirmTitle: String,
        action: @escaping @MainActor () -> Void
    ) {
        assert(title.hasSuffix("…"), "A button that opens a dialog ends in an ellipsis")
        self.title = title
        self.gate = gate
        self.question = question
        self.consequence = consequence
        self.confirmTitle = confirmTitle
        self.action = action
    }

    public var body: some View {
        Button(title, role: .destructive) { isConfirming = true }
            .confirmationDialog(question, isPresented: $isConfirming) {
                Button(gate == .confirm ? confirmTitle : "Continue", role: .destructive) {
                    if gate == .confirm {
                        action()
                    } else {
                        typed = ""
                        isTyping = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(consequence)
            }
            .sheet(isPresented: $isTyping) { typeToConfirm }
    }

    private var typeToConfirm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question).font(.headline)
            Text(consequence).fixedSize(horizontal: false, vertical: true)
            if case let .typed(word) = gate {
                TextField("Type \(word) to confirm", text: $typed)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isTyping = false }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: .destructive) {
                    isTyping = false
                    action()
                }
                .disabled(!gate.accepts(typed))
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
#endif
