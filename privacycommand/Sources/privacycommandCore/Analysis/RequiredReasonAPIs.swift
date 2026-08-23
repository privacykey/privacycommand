import Foundation

/// Apple's "required reason API" vocabulary as data: the five
/// `NSPrivacyAccessedAPICategory*` values, the symbols in each, and the
/// approved reason codes with their restrictions.
///
/// Required-reason declarations apply to iOS, iPadOS, tvOS, visionOS and
/// watchOS only — Apple explicitly excludes macOS, even for Mac App Store
/// apps. The vocabulary is still useful when auditing macOS binaries (the
/// same symbols reveal the same behaviour); it just carries no App Review
/// obligation there.
public enum RequiredReasonAPIs {

    public typealias Category = PrivacyManifest.AccessedAPI.Category

    /// One approved reason code and the restriction Apple attaches to it.
    /// Codes are category-scoped: a syntactically real code declared under a
    /// different category is invalid.
    public struct ReasonCode: Sendable, Hashable {
        /// The code as it appears in a manifest, e.g. "C617.1".
        public let code: String
        /// Apple's stated permitted use and off-device restrictions.
        public let note: String

        public init(code: String, note: String) {
            self.code = code
            self.note = note
        }
    }

    /// One API from Apple's per-category symbol list, with the exact
    /// spellings it produces in a Mach-O symbol table.
    public struct SymbolEntry: Sendable, Hashable {
        /// The API as Apple's documentation names it, e.g. "fstat(_:_:)".
        public let apiName: String
        /// Exact undefined-external (nlist) spellings this API produces:
        /// C functions and exported constants keep their leading underscore
        /// (`_stat`, `_NSFileCreationDate`); x86_64 slices spell part of the
        /// stat family with a `$INODE64` suffix (`_stat$INODE64`); Objective-C
        /// class references appear as `_OBJC_CLASS_$_NSUserDefaults`. APIs
        /// reached only through `objc_msgSend` (properties like
        /// `ProcessInfo.systemUptime`) leave no per-selector import — the
        /// class reference is the only nlist-visible evidence, so matches on
        /// those spellings are class-level, not member-level. Swift-mangled
        /// accessor symbols are not enumerated here.
        public let nlistSpellings: Set<String>

        public init(apiName: String, nlistSpellings: Set<String>) {
            self.apiName = apiName
            self.nlistSpellings = nlistSpellings
        }
    }

    /// One documented category: its reason codes and its symbol list.
    public struct CategoryEntry: Sendable {
        public let category: Category
        public let reasonCodes: [ReasonCode]
        public let symbols: [SymbolEntry]

        public init(category: Category, reasonCodes: [ReasonCode], symbols: [SymbolEntry]) {
            self.category = category
            self.reasonCodes = reasonCodes
            self.symbols = symbols
        }
    }

    // https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
    public static let categories: [CategoryEntry] = [
        CategoryEntry(
            category: .fileTimestamp,
            reasonCodes: [
                ReasonCode(code: "DDA9.1", note: "Display file timestamps to the person using the device. Information accessed for this reason, or any derived information, may not be sent off-device."),
                ReasonCode(code: "C617.1", note: "Access timestamps, size, or other metadata of files inside the app container, app group container, or the app's CloudKit container."),
                ReasonCode(code: "3B52.1", note: "Access timestamps, size, or other metadata of files or directories the user specifically granted access to, e.g. via a document picker."),
                ReasonCode(code: "0A2A.1", note: "Third-party SDKs only: a wrapper function around file timestamp APIs called only when the app calls the wrapper. May not be declared by an SDK that exists primarily to wrap required reason APIs; data may not be used for the SDK's own purposes or sent off-device by the SDK."),
            ],
            symbols: [
                SymbolEntry(apiName: "FileAttributeKey.creationDate",
                            nlistSpellings: ["_NSFileCreationDate"]),
                SymbolEntry(apiName: "FileAttributeKey.modificationDate",
                            nlistSpellings: ["_NSFileModificationDate"]),
                SymbolEntry(apiName: "UIDocument.fileModificationDate",
                            nlistSpellings: ["_OBJC_CLASS_$_UIDocument"]),
                SymbolEntry(apiName: "URLResourceKey.contentModificationDateKey",
                            nlistSpellings: ["_NSURLContentModificationDateKey"]),
                SymbolEntry(apiName: "URLResourceKey.creationDateKey",
                            nlistSpellings: ["_NSURLCreationDateKey"]),
                SymbolEntry(apiName: "getattrlist(_:_:_:_:_:)",
                            nlistSpellings: ["_getattrlist"]),
                SymbolEntry(apiName: "getattrlistbulk(_:_:_:_:_:)",
                            nlistSpellings: ["_getattrlistbulk"]),
                SymbolEntry(apiName: "fgetattrlist(_:_:_:_:_:)",
                            nlistSpellings: ["_fgetattrlist"]),
                SymbolEntry(apiName: "stat",
                            nlistSpellings: ["_stat", "_stat$INODE64"]),
                SymbolEntry(apiName: "fstat(_:_:)",
                            nlistSpellings: ["_fstat", "_fstat$INODE64"]),
                SymbolEntry(apiName: "fstatat(_:_:_:_:)",
                            nlistSpellings: ["_fstatat", "_fstatat$INODE64"]),
                SymbolEntry(apiName: "lstat(_:_:)",
                            nlistSpellings: ["_lstat", "_lstat$INODE64"]),
                SymbolEntry(apiName: "getattrlistat(_:_:_:_:_:_:)",
                            nlistSpellings: ["_getattrlistat"]),
            ]
        ),
        CategoryEntry(
            category: .systemBootTime,
            reasonCodes: [
                ReasonCode(code: "35F9.1", note: "Measure elapsed time between in-app events or enable timers. Data may not be sent off-device, except the amount of time elapsed between in-app events."),
                ReasonCode(code: "8FFB.1", note: "Calculate absolute timestamps for in-app events. The absolute timestamps may be sent off-device; the system boot time itself (or anything derived from it) may not."),
                ReasonCode(code: "3D61.1", note: "Include system boot time in an optional bug report the person chooses to submit; it must be prominently displayed as part of the report."),
            ],
            symbols: [
                SymbolEntry(apiName: "ProcessInfo.systemUptime",
                            nlistSpellings: ["_OBJC_CLASS_$_NSProcessInfo"]),
                SymbolEntry(apiName: "mach_absolute_time()",
                            nlistSpellings: ["_mach_absolute_time"]),
            ]
        ),
        CategoryEntry(
            category: .diskSpace,
            reasonCodes: [
                ReasonCode(code: "85F4.1", note: "Display disk space information to the person. May not be sent off-device, except over the local network to another device operated by the same person purely to display it there, with explicit permission, never over the Internet."),
                ReasonCode(code: "E174.1", note: "Check whether there is sufficient disk space to write files, or whether space is low so the app can delete files; the app must behave differently in a user-observable way. May not be sent off-device, except to avoid server downloads when space is insufficient."),
                ReasonCode(code: "7D9E.1", note: "Include disk space information in an optional bug report the person chooses to submit; it must be prominently displayed. May be sent off-device only after the user affirmatively submits that specific report."),
                ReasonCode(code: "B728.1", note: "Health research apps only: detect and inform research participants about low disk space impacting research data collection, per the Health and Health Research review guidelines."),
            ],
            symbols: [
                SymbolEntry(apiName: "URLResourceKey.volumeAvailableCapacityKey",
                            nlistSpellings: ["_NSURLVolumeAvailableCapacityKey"]),
                SymbolEntry(apiName: "URLResourceKey.volumeAvailableCapacityForImportantUsageKey",
                            nlistSpellings: ["_NSURLVolumeAvailableCapacityForImportantUsageKey"]),
                SymbolEntry(apiName: "URLResourceKey.volumeAvailableCapacityForOpportunisticUsageKey",
                            nlistSpellings: ["_NSURLVolumeAvailableCapacityForOpportunisticUsageKey"]),
                SymbolEntry(apiName: "URLResourceKey.volumeTotalCapacityKey",
                            nlistSpellings: ["_NSURLVolumeTotalCapacityKey"]),
                SymbolEntry(apiName: "FileAttributeKey.systemFreeSize",
                            nlistSpellings: ["_NSFileSystemFreeSize"]),
                SymbolEntry(apiName: "FileAttributeKey.systemSize",
                            nlistSpellings: ["_NSFileSystemSize"]),
                SymbolEntry(apiName: "statfs(_:_:)",
                            nlistSpellings: ["_statfs", "_statfs$INODE64"]),
                SymbolEntry(apiName: "statvfs(_:_:)",
                            nlistSpellings: ["_statvfs"]),
                SymbolEntry(apiName: "fstatfs(_:_:)",
                            nlistSpellings: ["_fstatfs", "_fstatfs$INODE64"]),
                SymbolEntry(apiName: "fstatvfs(_:_:)",
                            nlistSpellings: ["_fstatvfs"]),
                // The getattrlist family sits in BOTH the FileTimestamp and
                // DiskSpace symbol lists; one import is evidence for each.
                SymbolEntry(apiName: "getattrlist(_:_:_:_:_:)",
                            nlistSpellings: ["_getattrlist"]),
                SymbolEntry(apiName: "fgetattrlist(_:_:_:_:_:)",
                            nlistSpellings: ["_fgetattrlist"]),
                SymbolEntry(apiName: "getattrlistat(_:_:_:_:_:_:)",
                            nlistSpellings: ["_getattrlistat"]),
            ]
        ),
        CategoryEntry(
            category: .activeKeyboards,
            reasonCodes: [
                ReasonCode(code: "3EC4.1", note: "Custom keyboard apps only: determine which keyboards are active on the device. Providing a systemwide custom keyboard must be the app's primary functionality. May not be sent off-device."),
                ReasonCode(code: "54BD.1", note: "Present the correct customized UI. The app must have text fields for entering or editing text and must behave differently based on active keyboards in a user-observable way. May not be sent off-device."),
            ],
            symbols: [
                SymbolEntry(apiName: "UITextInputMode.activeInputModes",
                            nlistSpellings: ["_OBJC_CLASS_$_UITextInputMode"]),
            ]
        ),
        CategoryEntry(
            category: .userDefaults,
            reasonCodes: [
                ReasonCode(code: "CA92.1", note: "Read and write information accessible only to the app itself. Does not permit reading information written by other apps or the system, nor writing information other apps can access."),
                ReasonCode(code: "1C8F.1", note: "Read and write information accessible only to apps, app extensions and App Clips in the same App Group. Does not permit reading or writing across the App Group boundary, or reading system-written data."),
                ReasonCode(code: "C56D.1", note: "Third-party SDKs only: a wrapper function around user defaults APIs called only when the app calls the wrapper. May not be declared by an SDK that exists primarily to wrap required reason APIs; data may not be used for the SDK's own purposes or sent off-device by the SDK."),
                ReasonCode(code: "AC6B.1", note: "Read the com.apple.configuration.managed key for MDM-set managed app configuration, or set the com.apple.feedback.managed key to store feedback queryable over MDM."),
            ],
            symbols: [
                SymbolEntry(apiName: "UserDefaults",
                            nlistSpellings: ["_OBJC_CLASS_$_NSUserDefaults"]),
            ]
        ),
    ]

    // MARK: - Lookups

    /// Exact-match lookup from an nlist spelling to every category whose
    /// symbol list contains it. Exact means exact: `stat` (no underscore)
    /// matches nothing, and no substring or prefix matching happens.
    public static let categoriesByNlistSpelling: [String: Set<Category>] = {
        var out: [String: Set<Category>] = [:]
        for entry in categories {
            for symbol in entry.symbols {
                for spelling in symbol.nlistSpellings {
                    out[spelling, default: []].insert(entry.category)
                }
            }
        }
        return out
    }()

    /// Categories a single undefined-external symbol is evidence for
    /// (empty for symbols outside the vocabulary).
    public static func categories(forNlistSpelling spelling: String) -> Set<Category> {
        categoriesByNlistSpelling[spelling] ?? []
    }

    /// Reason code → the one category it belongs to. Codes never repeat
    /// across categories.
    public static let categoryByReasonCode: [String: Category] = {
        var out: [String: Category] = [:]
        for entry in categories {
            for reason in entry.reasonCodes {
                out[reason.code] = entry.category
            }
        }
        return out
    }()

    /// Whether `code` is an approved reason code for `category`. False for
    /// unknown codes and for real codes declared under the wrong category.
    public static func isValid(reasonCode code: String, in category: Category) -> Bool {
        categoryByReasonCode[code] == category
    }

    /// Every approved reason code across all five categories.
    public static let allReasonCodes: [ReasonCode] =
        categories.flatMap(\.reasonCodes)
}
