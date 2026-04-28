import Foundation

/// Mapping from Info.plist privacy keys to a (category, label) pair we use in the UI.
/// The database is loaded from `Resources/PrivacyKeyDatabase.json`. We keep a
/// hard-coded fallback so the analyzer is still useful when the JSON is missing.
public struct PrivacyKeyDatabase: Sendable {
    public struct Entry: Codable, Sendable, Hashable {
        public let category: PrivacyCategory
        public let label: String
    }

    private let table: [String: Entry]

    public init(table: [String: Entry]) {
        self.table = table
    }

    public func entry(forKey k: String) -> Entry? { table[k] }

    /// Loads from a JSON resource on disk. Falls back to the built-in defaults if
    /// the resource is missing or unreadable.
    public static func load(fromResource url: URL?) -> PrivacyKeyDatabase {
        if let url,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            return PrivacyKeyDatabase(table: decoded)
        }
        return .builtin
    }

    /// Built-in defaults — covers every privacy usage description Apple has
    /// documented at time of writing. Sources:
    /// https://developer.apple.com/documentation/bundleresources/information_property_list/protected_resources
    public static let builtin: PrivacyKeyDatabase = .init(table: [
        "NSCameraUsageDescription":                       Entry(category: .camera,            label: "Camera"),
        "NSMicrophoneUsageDescription":                   Entry(category: .microphone,        label: "Microphone"),
        "NSContactsUsageDescription":                     Entry(category: .contacts,          label: "Contacts"),
        "NSCalendarsUsageDescription":                    Entry(category: .calendar,          label: "Calendar"),
        "NSCalendarsFullAccessUsageDescription":          Entry(category: .calendar,          label: "Calendar (full access)"),
        "NSCalendarsWriteOnlyAccessUsageDescription":     Entry(category: .calendar,          label: "Calendar (write-only)"),
        "NSRemindersUsageDescription":                    Entry(category: .reminders,         label: "Reminders"),
        "NSRemindersFullAccessUsageDescription":          Entry(category: .reminders,         label: "Reminders (full access)"),
        "NSPhotoLibraryUsageDescription":                 Entry(category: .photoLibrary,      label: "Photos"),
        "NSPhotoLibraryAddUsageDescription":              Entry(category: .photoLibraryAdd,   label: "Photos (add only)"),
        "NSLocationUsageDescription":                     Entry(category: .location,          label: "Location"),
        "NSLocationAlwaysUsageDescription":               Entry(category: .location,          label: "Location (always)"),
        "NSLocationWhenInUseUsageDescription":            Entry(category: .location,          label: "Location (when in use)"),
        "NSLocationAlwaysAndWhenInUseUsageDescription":   Entry(category: .location,          label: "Location (always & when in use)"),
        "NSBluetoothAlwaysUsageDescription":              Entry(category: .bluetoothAlways,   label: "Bluetooth"),
        "NSBluetoothPeripheralUsageDescription":          Entry(category: .bluetooth,         label: "Bluetooth (legacy)"),
        "NSHomeKitUsageDescription":                      Entry(category: .homeKit,           label: "HomeKit"),
        "NSMotionUsageDescription":                       Entry(category: .motion,            label: "Motion"),
        "NSSpeechRecognitionUsageDescription":            Entry(category: .speechRecognition, label: "Speech Recognition"),
        "NSAppleMusicUsageDescription":                   Entry(category: .mediaLibrary,      label: "Media library"),
        "NSAppleEventsUsageDescription":                  Entry(category: .appleEvents,       label: "Apple Events / Automation"),
        "NSDesktopFolderUsageDescription":                Entry(category: .desktopFolder,     label: "Desktop folder"),
        "NSDocumentsFolderUsageDescription":              Entry(category: .documentsFolder,   label: "Documents folder"),
        "NSDownloadsFolderUsageDescription":              Entry(category: .downloadsFolder,   label: "Downloads folder"),
        "NSRemovableVolumesUsageDescription":             Entry(category: .removableVolumes,  label: "Removable volumes"),
        "NSNetworkVolumesUsageDescription":               Entry(category: .networkVolumes,    label: "Network volumes"),
        "NSFileProviderDomainUsageDescription":           Entry(category: .fileProviderDomain,label: "File Provider"),
        "NSLocalNetworkUsageDescription":                 Entry(category: .localNetwork,      label: "Local network"),
        "NSUserTrackingUsageDescription":                 Entry(category: .userTrackingTransparency, label: "User Tracking"),
        "NSFocusStatusUsageDescription":                  Entry(category: .focusStatus,       label: "Focus status"),
        "NSFaceIDUsageDescription":                       Entry(category: .faceID,            label: "Face ID")
    ])
}
