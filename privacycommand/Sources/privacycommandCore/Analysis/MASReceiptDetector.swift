import Foundation

/// Detects whether an app bundle was installed from the **Mac App Store**.
///
/// **Why this matters.** App Store apps come with two extra guarantees a
/// general Developer ID app does not: (1) Apple manually reviewed the
/// binary against the App Review guidelines, and (2) the developer
/// declared "Privacy Nutrition Labels" — a structured, machine-readable
/// statement of what data the app collects and how. Auditor surfaces both
/// signals to users when they're available, and `MASReceiptDetector` is
/// the gate that decides whether to even try the App Store lookup.
///
/// **How we detect.** The canonical indicator is the presence of a
/// `_MASReceipt/receipt` file inside the bundle's `Contents/` directory.
/// Apple writes this file at install time (it's a CMS-signed PKCS#7
/// envelope containing the user's purchase receipt) and a non-App-Store
/// build of the same bundle will not have one. We don't validate the
/// receipt's signature here — Apple already did that at install time.
/// We just check for the file's existence and capture its size as a
/// sanity-check that it's a real receipt rather than a zero-byte stub.
public enum MASReceiptDetector {

    public struct Result: Sendable, Hashable, Codable {
        /// True if the bundle has a `_MASReceipt/receipt` file.
        public let isMASApp: Bool
        /// Receipt file size in bytes. Useful as a sanity check —
        /// real Mac App Store receipts are typically 5–15 KB.
        public let receiptBytes: Int?
        /// Bundle ID lifted from the bundle's `Info.plist`. We capture
        /// it here (rather than re-reading later) because the App Store
        /// lookup is keyed by bundle ID, and the caller already has us
        /// poking at the bundle's filesystem.
        public let bundleID: String?

        public init(isMASApp: Bool, receiptBytes: Int? = nil, bundleID: String? = nil) {
            self.isMASApp = isMASApp
            self.receiptBytes = receiptBytes
            self.bundleID = bundleID
        }

        /// Empty / negative result.
        public static let none = Result(isMASApp: false)
    }

    /// Inspect the bundle at `bundleURL`. Pure I/O — runs in microseconds
    /// (a single FileManager `attributesOfItem` call) so it can be invoked
    /// inline from `StaticAnalyzer` without a background dispatch.
    public static func detect(bundleAt bundleURL: URL) -> Result {
        let receiptURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("_MASReceipt", isDirectory: true)
            .appendingPathComponent("receipt", isDirectory: false)

        let fm = FileManager.default
        guard fm.fileExists(atPath: receiptURL.path) else {
            return .none
        }

        var size: Int? = nil
        if let attrs = try? fm.attributesOfItem(atPath: receiptURL.path),
           let n = attrs[.size] as? NSNumber {
            size = n.intValue
        }

        // Pull the bundle ID from Info.plist. Best-effort — if the
        // plist is unreadable we still report `isMASApp: true`; the
        // App Store lookup just won't have anything to key on.
        let bundleID = readBundleID(from: bundleURL)

        return Result(isMASApp: true, receiptBytes: size, bundleID: bundleID)
    }

    // MARK: - Helpers

    private static func readBundleID(from bundleURL: URL) -> String? {
        let plistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }
}
