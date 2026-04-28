import Foundation

/// One detected access-or-use event from the live-probe monitor —
/// pasteboard writes, camera in-use transitions, microphone in-use
/// transitions. Distinct from the existing `DynamicEvent` cases because
/// these come from *system-state polling* rather than the per-process
/// monitors (lsof / fs_usage / proc_pid).
public struct LiveProbeEvent: Codable, Hashable, Sendable, Identifiable {

    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case pasteboardWrite       = "Pasteboard write"
        case cameraStart           = "Camera started"
        case cameraStop            = "Camera stopped"
        case microphoneStart       = "Microphone started"
        case microphoneStop        = "Microphone stopped"
        case screenRecordingStart  = "Screen recording started"
        case screenRecordingStop   = "Screen recording stopped"

        public var icon: String {
            switch self {
            case .pasteboardWrite:                            return "doc.on.clipboard"
            case .cameraStart, .cameraStop:                   return "camera.fill"
            case .microphoneStart, .microphoneStop:           return "mic.fill"
            case .screenRecordingStart, .screenRecordingStop: return "rectangle.dashed.badge.record"
            }
        }

        public var category: Category {
            switch self {
            case .pasteboardWrite:                            return .pasteboard
            case .cameraStart, .cameraStop:                   return .camera
            case .microphoneStart, .microphoneStop:           return .microphone
            case .screenRecordingStart, .screenRecordingStop: return .screenRecording
            }
        }

        public enum Category: String, Sendable, Hashable, Codable, CaseIterable {
            case pasteboard, camera, microphone, screenRecording
        }
    }

    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    /// PID we attributed the event to. May be `0` for "stopped"
    /// transitions where we no longer know who held the device.
    public let pid: Int32
    public let processName: String
    /// Free-text detail, e.g. "string + url + ..." for pasteboard
    /// writes, or "Built-in microphone" for the device used.
    public let detail: String?

    public init(id: UUID = .init(),
                timestamp: Date = .init(),
                kind: Kind,
                pid: Int32,
                processName: String,
                detail: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.pid = pid
        self.processName = processName
        self.detail = detail
    }
}
