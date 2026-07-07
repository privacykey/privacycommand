import Foundation

/// A privacy purpose string declared in the bundle's Info.plist.
///
/// e.g. `NSCameraUsageDescription = "We use the camera for profile pictures."`
/// becomes `PrivacyKey(rawKey: "NSCameraUsageDescription", category: .camera, purposeString: ...)`.
public struct PrivacyKey: Codable, Hashable, Sendable, Identifiable {
    public var id: String { rawKey }
    public let rawKey: String
    public let category: PrivacyCategory
    public let humanLabel: String        // "Camera"
    public let purposeString: String     // the value supplied by the developer
    public let isEmpty: Bool              // empty/whitespace purpose strings are a finding

    public init(rawKey: String, category: PrivacyCategory, humanLabel: String, purposeString: String) {
        self.rawKey = rawKey
        self.category = category
        self.humanLabel = humanLabel
        self.purposeString = purposeString
        self.isEmpty = purposeString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum PrivacyCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case camera
    case microphone
    case contacts
    case calendar
    case reminders
    case photoLibrary
    case photoLibraryAdd
    case location
    case bluetooth
    case bluetoothAlways
    case homeKit
    case motion
    case speechRecognition
    case mediaLibrary
    case appleEvents
    case automation               // NSAppleScriptEnabled / NSAppleEventsUsageDescription
    case desktopFolder
    case documentsFolder
    case downloadsFolder
    case removableVolumes
    case networkVolumes
    case fileProviderDomain
    case localNetwork
    case userTrackingTransparency // NSUserTrackingUsageDescription
    case focusStatus
    case faceID
    // System-access grants with no Info.plist usage key — a user grants these
    // by hand in System Settings › Privacy & Security. They have no "requested"
    // channel, so they surface as *granted* (from TCC) and, for screen
    // recording, *used* (from a live probe). The StaticAnalyzer inference map
    // deliberately omits them (see its note) precisely because there was no
    // category to attach; that gap is what these cases close.
    case fullDiskAccess
    case screenCapture
    case accessibility
    case inputMonitoring
    case unknown
}

public extension PrivacyCategory {
    /// Human-facing label for the category, independent of any specific
    /// Info.plist usage key. The permission matrix has one row per category,
    /// not per declared key, so it needs a category-level label.
    var displayName: String {
        switch self {
        case .camera:                   return "Camera"
        case .microphone:               return "Microphone"
        case .contacts:                 return "Contacts"
        case .calendar:                 return "Calendar"
        case .reminders:                return "Reminders"
        case .photoLibrary:             return "Photo Library"
        case .photoLibraryAdd:          return "Photo Library (add)"
        case .location:                 return "Location"
        case .bluetooth:                return "Bluetooth"
        case .bluetoothAlways:          return "Bluetooth (always)"
        case .homeKit:                  return "HomeKit"
        case .motion:                   return "Motion & Fitness"
        case .speechRecognition:        return "Speech Recognition"
        case .mediaLibrary:             return "Media Library"
        case .appleEvents:              return "Apple Events"
        case .automation:               return "Automation"
        case .desktopFolder:            return "Desktop Folder"
        case .documentsFolder:          return "Documents Folder"
        case .downloadsFolder:          return "Downloads Folder"
        case .removableVolumes:         return "Removable Volumes"
        case .networkVolumes:           return "Network Volumes"
        case .fileProviderDomain:       return "File Provider"
        case .localNetwork:             return "Local Network"
        case .userTrackingTransparency: return "App Tracking"
        case .focusStatus:              return "Focus Status"
        case .faceID:                   return "Face ID"
        case .fullDiskAccess:           return "Full Disk Access"
        case .screenCapture:            return "Screen Recording"
        case .accessibility:            return "Accessibility"
        case .inputMonitoring:          return "Input Monitoring"
        case .unknown:                  return "Unknown"
        }
    }

    /// System-access categories: granted by hand, no Info.plist declaration
    /// channel. The matrix groups these separately from app-declared privacy
    /// categories because "requested" is never meaningful for them.
    var isSystemAccess: Bool {
        switch self {
        case .fullDiskAccess, .screenCapture, .accessibility, .inputMonitoring:
            return true
        default:
            return false
        }
    }
}
