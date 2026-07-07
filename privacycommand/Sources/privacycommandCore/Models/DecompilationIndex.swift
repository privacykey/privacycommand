import Foundation

/// A whole-app decompilation: the app's reconstructed classes and their
/// functions' pseudo-C. Produced on demand by `GhidraProgramDump` (from a
/// user-installed Ghidra) or imported from a Malimite project; the `source`
/// field records which, so the same browser renders either.
///
/// This is large and on-demand, so it is **not** part of the cached
/// `StaticReport`; it lives in its own `DecompilationIndexStore`.
public struct DecompilationIndex: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable {
        case ghidra
        case malimite
    }

    public let source: Source
    /// Absolute path of the binary this was produced from.
    public let binaryPath: String
    /// The `DecompileScope.key` used — part of the cache identity (a
    /// named-classes dump and an everything dump are different artifacts).
    public let scope: String
    public let classes: [DecompiledClass]
    /// Number of functions decompiled (may be below the true total if truncated).
    public let functionCount: Int
    /// True when the scope's cap stopped the dump before every function.
    public let truncated: Bool
    public let generatedAt: Date
    /// Optional human note (e.g. "capped at 1500 functions").
    public let note: String?

    public init(source: Source, binaryPath: String, scope: String,
                classes: [DecompiledClass], functionCount: Int,
                truncated: Bool, generatedAt: Date = Date(), note: String? = nil) {
        self.source = source
        self.binaryPath = binaryPath
        self.scope = scope
        self.classes = classes
        self.functionCount = functionCount
        self.truncated = truncated
        self.generatedAt = generatedAt
        self.note = note
    }

    public var classCount: Int { classes.count }
}

public struct DecompiledClass: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    /// Qualified class / namespace name, e.g. `MyApp.LoginViewController` or
    /// `-[SomeObjCClass]`. `(global)` collects namespace-less functions.
    public let name: String
    public let functions: [DecompiledFunction]

    public init(name: String, functions: [DecompiledFunction]) {
        self.name = name
        self.functions = functions
    }
}

public struct DecompiledFunction: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(className ?? "")::\(name)@\(entryHex ?? "")" }
    /// Owning class / namespace, or `nil` for global functions.
    public let className: String?
    /// The name as Ghidra sees it (may be mangled or a `FUN_…` synthetic name).
    public let name: String
    /// Demangled Swift/Obj-C name when available (else `nil`). Reserved for the
    /// optional demangle pass; always safe to fall back to `name`.
    public let demangled: String?
    /// Prototype string, e.g. `undefined8 foo(void)`.
    public let signature: String?
    /// Entry-point address (hex), used to disambiguate same-named functions.
    public let entryHex: String?
    /// Decompiled pseudo-C. Empty when the decompiler couldn't produce a body.
    public let cCode: String

    public init(className: String?, name: String, demangled: String? = nil,
                signature: String?, entryHex: String?, cCode: String) {
        self.className = className
        self.name = name
        self.demangled = demangled
        self.signature = signature
        self.entryHex = entryHex
        self.cCode = cCode
    }

    /// Best display name: demangled if we have it, else the raw name.
    public var displayName: String { demangled ?? name }
}

/// How much of a binary to decompile. Whole-binary decompilation is expensive,
/// so we never do "everything" by default.
public struct DecompileScope: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// Only functions that belong to a named class / namespace — skips
        /// Ghidra's synthetic `FUN_…` thunks and library glue. ~10× smaller.
        case namedClasses
        /// Every function, up to `cap`.
        case everything
    }

    public let kind: Kind
    /// Hard cap on functions decompiled; past it the index is `truncated`.
    public let cap: Int

    public init(kind: Kind, cap: Int = DecompileScope.defaultCap) {
        self.kind = kind
        self.cap = max(1, cap)
    }

    public static let defaultCap = 1500
    public static let namedClasses = DecompileScope(kind: .namedClasses)
    public static func everything(cap: Int = DecompileScope.defaultCap) -> DecompileScope {
        DecompileScope(kind: .everything, cap: cap)
    }

    /// Stable string used in cache keys and stored on the index.
    public var key: String { "\(kind.rawValue)-\(cap)" }
}
