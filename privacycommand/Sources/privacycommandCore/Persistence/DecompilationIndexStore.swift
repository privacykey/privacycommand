import Foundation

/// On-disk cache for whole-app `DecompilationIndex`es, so re-opening an app
/// that was already decompiled is instant instead of re-running Ghidra.
///
/// Keyed by `GhidraProgramDump.cacheKey(for:scope:)` — i.e. the binary's
/// path+size+mtime *and* the scope — so replacing the binary or switching scope
/// produces a distinct, correct entry. Stored as the encoded `DecompilationIndex`
/// (JSON) under `~/Library/Caches/privacycommand/decompiled/`, separate from the
/// content-keyed `RunStore`/`StaticReport` cache (different lifecycle).
public struct DecompilationIndexStore {
    private let directory: URL

    /// `directory` overrides the on-disk location (used by tests); production
    /// callers omit it to use `~/Library/Caches/privacycommand/decompiled/`.
    public init(fileManager fm: FileManager = .default, directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("privacycommand/decompiled", isDirectory: true)
        }
        try fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    /// Return the cached index for `key`, or `nil` on a miss / unreadable file.
    public func load(key: String) -> DecompilationIndex? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DecompilationIndex.self, from: data)
    }

    /// Persist `index` under `key`.
    @discardableResult
    public func save(_ index: DecompilationIndex, key: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let target = url(for: key)
        try encoder.encode(index).write(to: target, options: .atomic)
        return target
    }

    /// Convenience: cached index for a (binary, scope) pair.
    public func load(binary: URL, scope: DecompileScope) -> DecompilationIndex? {
        load(key: GhidraProgramDump.cacheKey(for: binary, scope: scope))
    }
}
