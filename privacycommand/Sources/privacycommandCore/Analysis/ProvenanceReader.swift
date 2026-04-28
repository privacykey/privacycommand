import Foundation
import CryptoKit
import Darwin

// MARK: - Public types

/// Where this copy of the app came from, as inferred from macOS extended
/// attributes. None of these are cryptographically authoritative — they're
/// hints macOS captured at download time and a determined attacker could
/// strip them — but they're high-signal and almost always present on apps
/// downloaded from the web.
public struct ProvenanceInfo: Codable, Hashable, Sendable {
    /// URLs from `com.apple.metadata:kMDItemWhereFroms`. Typically two:
    /// element 0 is the direct download URL (e.g. the dmg / zip URL), and
    /// element 1 is the page the user clicked from.
    public let whereFromURLs: [String]
    public let quarantineFlagsHex: String?
    public let quarantineAgentName: String?
    public let quarantineAgentUUID: String?
    public let quarantineDate: Date?
    public let isQuarantined: Bool
    /// Path to the bundle's main executable, captured here so the UI can
    /// trigger SHA-256 computation lazily without re-resolving the bundle.
    public let mainExecutablePath: String

    public init(
        whereFromURLs: [String] = [],
        quarantineFlagsHex: String? = nil,
        quarantineAgentName: String? = nil,
        quarantineAgentUUID: String? = nil,
        quarantineDate: Date? = nil,
        isQuarantined: Bool = false,
        mainExecutablePath: String
    ) {
        self.whereFromURLs = whereFromURLs
        self.quarantineFlagsHex = quarantineFlagsHex
        self.quarantineAgentName = quarantineAgentName
        self.quarantineAgentUUID = quarantineAgentUUID
        self.quarantineDate = quarantineDate
        self.isQuarantined = isQuarantined
        self.mainExecutablePath = mainExecutablePath
    }

    public static let empty = ProvenanceInfo(mainExecutablePath: "")
}

// MARK: - Reader

public enum ProvenanceReader {

    /// Reads xattrs on the bundle URL. Cheap (microseconds). Doesn't compute
    /// the SHA-256 — that's `sha256(of:)` and is opt-in / async because it
    /// reads the entire executable.
    public static func read(for bundle: AppBundle) -> ProvenanceInfo {
        let bundlePath = bundle.url.path
        let whereFromURLs = readWhereFroms(at: bundlePath)
        let q = readQuarantine(at: bundlePath)

        return ProvenanceInfo(
            whereFromURLs: whereFromURLs,
            quarantineFlagsHex: q?.flagsHex,
            quarantineAgentName: q?.agent,
            quarantineAgentUUID: q?.uuid,
            quarantineDate: q?.date,
            isQuarantined: q != nil,
            mainExecutablePath: bundle.executableURL.path
        )
    }

    /// Compute SHA-256 of a file. Memory-mapped read so we don't blow up the
    /// heap for large executables. Synchronous — call from a Task.
    public static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience for "did the user paste a hash that matches?" Trims and
    /// lowercases both sides; tolerates "sha256:" / "SHA-256:" prefixes.
    public static func hashMatches(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b)
    }

    private static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sha-256:", "sha256:", "sha-256 ", "sha256 "] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        // Strip any non-hex chars (developers sometimes paste hashes with
        // dashes or surrounding quotes).
        return t.filter { $0.isHexDigit }
    }

    // MARK: - Internal helpers

    private static func readXattr(name: String, atPath path: String) -> Data? {
        let cstr = path.cString(using: .utf8) ?? []
        let size = getxattr(cstr, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { ptr -> ssize_t in
            guard let base = ptr.baseAddress else { return -1 }
            return getxattr(cstr, name, base, size, 0, 0)
        }
        guard result > 0 else { return nil }
        return data
    }

    private static func readWhereFroms(at path: String) -> [String] {
        guard let data = readXattr(name: "com.apple.metadata:kMDItemWhereFroms", atPath: path) else {
            return []
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let arr = plist as? [String] else {
            return []
        }
        // Filter empty strings and keep order (download URL → referrer URL).
        return arr.filter { !$0.isEmpty }
    }

    /// `com.apple.quarantine` payload format:
    ///   `<flags hex>;<unix timestamp hex>;<agent name>;<event uuid>`
    /// e.g. `0083;5e7d3b1a;Safari;F9C8...`
    private struct Quarantine {
        let flagsHex: String
        let agent: String
        let uuid: String
        let date: Date?
    }

    private static func readQuarantine(at path: String) -> Quarantine? {
        guard let data = readXattr(name: "com.apple.quarantine", atPath: path) else {
            return nil
        }
        // Strip trailing NUL bytes some writers append.
        let trimmed = data.prefix(while: { $0 != 0 })
        guard let s = String(data: Data(trimmed), encoding: .utf8) else { return nil }
        let parts = s.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        let date: Date? = {
            if let unix = UInt32(parts[1], radix: 16) {
                return Date(timeIntervalSince1970: TimeInterval(unix))
            }
            return nil
        }()
        return Quarantine(
            flagsHex: parts[0],
            agent: parts[2].isEmpty ? "Unknown" : parts[2],
            uuid: parts[3],
            date: date
        )
    }
}
