import Foundation

/// Imports a **Malimite** project database into a `DecompilationIndex`, so an
/// app decompiled with LaurieWired/Malimite renders in the same class browser
/// as our native Ghidra dump.
///
/// Malimite has no headless/CLI mode, so this is an *importer*, not a driver:
/// the user produces the project database in Malimite, then imports it here.
/// Malimite writes a SQLite database whose `Functions` table carries the
/// per-function decompiled code (`SQLiteDBHandler.java`):
///
///     Functions(FunctionName, ParentClass, DecompilationCode, ExecutableName, DecompilationLine)
///
/// We read that table (schema-defensively) and group by `ParentClass`.
public enum MalimiteImporter {

    public enum ImportError: LocalizedError, Equatable {
        case unreadable(String)
        case notAMalimiteDatabase

        public var errorDescription: String? {
            switch self {
            case .unreadable(let m):
                return "Couldn't open the Malimite database: \(m)"
            case .notAMalimiteDatabase:
                return "That file doesn't look like a Malimite project — it has no `Functions` table with decompiled code."
            }
        }
    }

    /// Import the Malimite SQLite database at `url`.
    public static func importDatabase(at url: URL) throws -> DecompilationIndex {
        let reader: SQLiteReader
        do {
            reader = try SQLiteReader(path: url.path)
        } catch {
            throw ImportError.unreadable((error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription)
        }
        return try parse(reader: reader, binaryPath: url.path)
    }

    /// Pure mapping over a reader — unit-tested against a fixture database.
    static func parse(reader: SQLiteReader, binaryPath: String) throws -> DecompilationIndex {
        let columns = Set((try? reader.columns(of: "Functions")) ?? [])
        guard columns.contains("FunctionName") else { throw ImportError.notAMalimiteDatabase }

        // Select only columns that exist (older/newer Malimite schemas vary).
        let wanted = ["FunctionName", "ParentClass", "DecompilationCode"].filter(columns.contains)
        let rows = try reader.query("SELECT \(wanted.joined(separator: ", ")) FROM Functions")

        var byClass: [String: [DecompiledFunction]] = [:]
        var order: [String] = []
        var count = 0
        for row in rows {
            guard let name = row["FunctionName"]?.string, !name.isEmpty else { continue }
            let parent = row["ParentClass"]?.string
            let className = (parent?.isEmpty == false) ? parent : nil
            let fn = DecompiledFunction(
                className: className,
                name: name,
                signature: nil,
                entryHex: nil,
                cCode: row["DecompilationCode"]?.string ?? "")
            let key = className ?? "(global)"
            if byClass[key] == nil { order.append(key) }
            byClass[key, default: []].append(fn)
            count += 1
        }

        let classes = order
            .map { DecompiledClass(name: $0, functions: byClass[$0] ?? []) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return DecompilationIndex(
            source: .malimite,
            binaryPath: binaryPath,
            scope: "malimite",
            classes: classes,
            functionCount: count,
            truncated: false,
            note: "Imported from a Malimite project database.")
    }
}
