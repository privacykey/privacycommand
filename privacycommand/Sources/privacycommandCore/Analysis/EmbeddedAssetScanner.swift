import Foundation

/// Walks an app bundle for embedded *content* — interpreted scripts and
/// launchd plists. Many apps install long-lived background services
/// without making it obvious from the UI; surfacing these up-front lets
/// the user see what the bundle is *prepared* to run, not just what it
/// runs while in the foreground.
public enum EmbeddedAssetScanner {

    public static func scan(bundle: AppBundle) -> EmbeddedAssets {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: bundle.url,
                                         includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else {
            return .empty
        }

        var scripts: [EmbeddedAssets.Script] = []
        var launchPlists: [EmbeddedAssets.LaunchPlist] = []

        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let size = Int(values?.fileSize ?? 0)
            let path = url.path

            // Scripts — surface only files the bundle is actually prepared to
            // RUN: executable, or carrying a shebang. Inert resources (bundled
            // web .js, library .py, …) are neither and were heavy FP noise.
            let isExec = fm.isExecutableFile(atPath: path)
            if let kind = scriptKind(forURL: url, isExecutable: isExec, probeSize: size) {
                scripts.append(EmbeddedAssets.Script(
                    url: url, kind: kind, sizeBytes: size, isExecutable: isExec))
                continue
            }

            // Launch agents / daemons. Apple's convention: a plist whose
            // CFBundleIdentifier-style label and `Program` key gets
            // installed under one of the Library/Launch{Agents,Daemons}
            // directories at install time.
            if url.pathExtension.lowercased() == "plist" {
                if let lp = parseLaunchPlist(at: url) {
                    launchPlists.append(lp)
                }
            }
        }

        return EmbeddedAssets(scripts: scripts.sorted(by: { $0.url.path < $1.url.path }),
                              launchPlists: launchPlists)
    }

    // MARK: - Scripts

    /// Classify a candidate script. Returns `nil` unless the file is actually
    /// prepared to run — executable, or carrying a shebang — so inert resource
    /// files (bundled web `.js`, library `.py`, …) are not reported.
    private static func scriptKind(forURL url: URL, isExecutable: Bool, probeSize: Int) -> EmbeddedAssets.Script.Kind? {
        // The shebang interpreter is authoritative when present. Probe small
        // files and anything executable (a shebang is ~the first line).
        let shebang = (isExecutable || probeSize < 65_536) ? shebangInterpreter(at: url) : nil
        let extKind: EmbeddedAssets.Script.Kind?
        switch url.pathExtension.lowercased() {
        case "sh", "bash", "zsh", "command": extKind = .shell
        case "py":                           extKind = .python
        case "rb":                           extKind = .ruby
        case "pl":                           extKind = .perl
        case "js", "mjs", "cjs":             extKind = .node
        case "applescript", "scpt":          extKind = .applescript
        case "swift":                        extKind = .swift
        default:                             extKind = nil
        }
        // "Prepared to run" = executable or shebang-declared. Extension alone
        // (no +x, no shebang) is an inert resource, not a runnable script.
        guard isExecutable || shebang != nil else { return nil }
        return shebang ?? extKind
    }

    /// Parse a `#!` line into a script kind, resolving the interpreter by its
    /// basename (and through `/usr/bin/env`). Avoids the old substring matching
    /// where "/sh" matched any path that merely contained it.
    private static func shebangInterpreter(at url: URL) -> EmbeddedAssets.Script.Kind? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 128), head.count >= 2 else { return nil }
        let bytes = [UInt8](head)
        guard bytes[0] == 0x23, bytes[1] == 0x21 else { return nil }   // "#!"
        let firstLine = String(decoding: head, as: UTF8.self)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let afterBang = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
        var tokens = afterBang.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = tokens.first else { return nil }
        var interp = (first as NSString).lastPathComponent
        if interp == "env" {                 // "#!/usr/bin/env python3 -u"
            tokens.removeFirst()
            while let t = tokens.first, t.hasPrefix("-") || t.contains("=") { tokens.removeFirst() }
            guard let next = tokens.first else { return .other(afterBang) }
            interp = (next as NSString).lastPathComponent
        }
        let i = interp.lowercased()
        if ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(i) { return .shell }
        if i.hasPrefix("python") { return .python }
        if i == "ruby"  { return .ruby }
        if i == "perl"  { return .perl }
        if i == "node" || i == "nodejs" { return .node }
        if i == "osascript" { return .applescript }
        if i == "swift" { return .swift }
        return .other(afterBang)
    }

    // MARK: - Launch plists

    private static func parseLaunchPlist(at url: URL) -> EmbeddedAssets.LaunchPlist? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return nil }

        // The smell-test for a launchd plist is the presence of `Label`
        // (always required) plus one of `Program`, `ProgramArguments`,
        // `ProgramArgumentVector`, or a `RunAtLoad` flag.
        guard let label = plist["Label"] as? String else { return nil }
        // A real launchd job must have something to run. Label + RunAtLoad /
        // KeepAlive alone (no Program/ProgramArguments) is too weak — ordinary
        // config plists carry those keys without being launchd jobs.
        guard plist["Program"] != nil || plist["ProgramArguments"] != nil else { return nil }

        let program = plist["Program"] as? String
        let args = (plist["ProgramArguments"] as? [String]) ?? []
        let runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        let keepAlive: Bool = {
            if let b = plist["KeepAlive"] as? Bool { return b }
            if plist["KeepAlive"] is [String: Any] { return true }
            return false
        }()
        let machServices: [String] = (plist["MachServices"] as? [String: Any])
            .map { Array($0.keys) } ?? []

        return EmbeddedAssets.LaunchPlist(
            url: url,
            label: label,
            program: program,
            programArguments: args,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            machServices: machServices.sorted(),
            kind: classifyLaunchPlist(at: url))
    }

    private static func classifyLaunchPlist(at url: URL) -> EmbeddedAssets.LaunchPlist.Kind {
        let path = url.path
        if path.contains("/LaunchDaemons/") { return .daemon }
        if path.contains("/LaunchAgents/")  { return .agent }
        // Plists living under a bundle's Resources are typically templates
        // copied into ~/Library/LaunchAgents at install time.
        if path.contains("/Resources/") || path.contains("/Library/") { return .template }
        return .unknown
    }
}

// MARK: - Public types

public struct EmbeddedAssets: Sendable, Hashable, Codable {
    public let scripts: [Script]
    public let launchPlists: [LaunchPlist]

    public init(scripts: [Script] = [], launchPlists: [LaunchPlist] = []) {
        self.scripts = scripts
        self.launchPlists = launchPlists
    }

    public static let empty = EmbeddedAssets()

    public struct Script: Sendable, Hashable, Codable, Identifiable {
        public var id: String { url.path }
        public let url: URL
        public let kind: Kind
        public let sizeBytes: Int
        public let isExecutable: Bool

        public enum Kind: Sendable, Hashable, Codable {
            case shell, python, ruby, perl, node, applescript, swift
            case other(String)

            public var label: String {
                switch self {
                case .shell:        return "Shell script"
                case .python:       return "Python"
                case .ruby:         return "Ruby"
                case .perl:         return "Perl"
                case .node:         return "Node / JavaScript"
                case .applescript:  return "AppleScript"
                case .swift:        return "Swift script"
                case .other(let s): return "Script (#! \(s.replacingOccurrences(of: "#!", with: "")))"
                }
            }
        }
    }

    public struct LaunchPlist: Sendable, Hashable, Codable, Identifiable {
        public var id: String { url.path }
        public let url: URL
        public let label: String
        public let program: String?
        public let programArguments: [String]
        public let runAtLoad: Bool
        public let keepAlive: Bool
        public let machServices: [String]
        public let kind: Kind

        public enum Kind: String, Sendable, Hashable, Codable {
            case daemon    = "Launch daemon"   // root, /Library/LaunchDaemons
            case agent     = "Launch agent"    // user, /Library/LaunchAgents
            case template  = "Template (installs at runtime)"
            case unknown
        }

        public var commandSummary: String {
            if let p = program { return ([p] + programArguments).joined(separator: " ") }
            return programArguments.joined(separator: " ")
        }
    }
}
