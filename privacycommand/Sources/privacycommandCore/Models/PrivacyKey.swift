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
    case unknown
}
