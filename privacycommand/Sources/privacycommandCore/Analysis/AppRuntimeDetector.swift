import Foundation

/// Classifies the **runtime engine** an app is built on — native AppKit,
/// Mac Catalyst, or a bundled cross-platform runtime like Electron, NW.js,
/// Node, the JVM, Python, Mono/.NET, Qt, or Wine.
///
/// **Why it matters for privacy/security.** A native AppKit app and an
/// Electron app with the same Info.plist are wildly different risk profiles:
/// Electron / NW.js bundle a full Chromium + Node and routinely load remote
/// web content, so an attacker who controls that content (or a compromised
/// `app.asar`) gets a large RCE/IPC surface. Knowing the runtime up front
/// frames everything else the analyzer reports.
///
/// Pure + testable: callers pass the signals (linked dylibs, framework
/// names, top-level resource names); no I/O here.
public enum AppRuntimeDetector {

    public enum Flavor: String, Sendable, Hashable, Codable {
        case native      = "Native (AppKit/SwiftUI)"
        case catalyst    = "Mac Catalyst (UIKit)"
        case electron    = "Electron"
        case nwjs        = "NW.js"
        case node        = "Node.js"
        case java        = "Java / JVM"
        case python      = "Python"
        case dotnet      = "Mono / .NET"
        case qt          = "Qt"
        case wine        = "Wine / CrossOver"
        case unknown     = "Unknown"
    }

    public struct Result: Sendable, Hashable, Codable {
        public let flavor: Flavor
        public let evidence: [String]
        /// True for runtimes that bundle a web/script engine and commonly
        /// execute remote or scripted content (Electron / NW.js / Node / Wine).
        public let isSecuritySensitive: Bool
        public init(flavor: Flavor, evidence: [String], isSecuritySensitive: Bool) {
            self.flavor = flavor; self.evidence = evidence
            self.isSecuritySensitive = isSecuritySensitive
        }
    }

    public static func detect(dylibs: [String],
                              frameworkNames: [String],
                              resourceNames: [String]) -> Result {
        let libs = dylibs.map { $0.lowercased() }
        let fwks = frameworkNames.map { $0.lowercased() }
        let res  = resourceNames.map { $0.lowercased() }

        func anyContains(_ pools: [[String]], _ needle: String) -> String? {
            for pool in pools { if let hit = pool.first(where: { $0.contains(needle) }) { return hit } }
            return nil
        }

        // Electron — the distinctive marks are the Electron Framework and the
        // packed app.asar archive. Checked first: an Electron app also links
        // node, so node detection must not pre-empt it.
        if let e = anyContains([libs, fwks], "electron framework")
            ?? (res.contains("app.asar") ? "app.asar" : nil)
            ?? anyContains([fwks], "electron framework.framework") {
            return Result(flavor: .electron, evidence: ["Electron: \(e)"], isSecuritySensitive: true)
        }
        // NW.js
        if let n = anyContains([libs, fwks], "nwjs")
            ?? (res.contains("package.nw") ? "package.nw" : nil) {
            return Result(flavor: .nwjs, evidence: ["NW.js: \(n)"], isSecuritySensitive: true)
        }
        // Bare Node (no Electron/NW.js shell)
        if let n = anyContains([libs], "libnode") {
            return Result(flavor: .node, evidence: ["Node: \(n)"], isSecuritySensitive: true)
        }
        // Wine / CrossOver -- gate on specific dylib/resource signals only.
        // A bare "wine" substring would mis-flag benign names like Twine.framework.
        if let w = anyContains([libs], "libwine") ?? anyContains([libs], "crossover")
            ?? ((res.contains("wine") || res.contains("crossover")) ? "wine/crossover resource" : nil) {
            return Result(flavor: .wine, evidence: ["Wine: \(w)"], isSecuritySensitive: true)
        }
        // JVM
        if let j = anyContains([libs, fwks], "libjvm") ?? anyContains([libs, fwks], "javavm")
            ?? anyContains([fwks], "javanativefoundation") {
            return Result(flavor: .java, evidence: ["JVM: \(j)"], isSecuritySensitive: false)
        }
        // Python
        if let p = anyContains([libs], "libpython") ?? anyContains([fwks], "python.framework") {
            return Result(flavor: .python, evidence: ["Python: \(p)"], isSecuritySensitive: false)
        }
        // Mono / .NET
        if let m = anyContains([libs, fwks], "libmono") ?? anyContains([fwks], "mono.framework")
            ?? anyContains([libs], "libcoreclr") {
            return Result(flavor: .dotnet, evidence: [".NET: \(m)"], isSecuritySensitive: false)
        }
        // Qt
        if let q = anyContains([libs, fwks], "libqt") ?? anyContains([fwks], "qtcore") {
            return Result(flavor: .qt, evidence: ["Qt: \(q)"], isSecuritySensitive: false)
        }
        // Mac Catalyst — links UIKit out of /System/iOSSupport.
        if let c = anyContains([libs], "iossupport") {
            return Result(flavor: .catalyst, evidence: ["Catalyst: links \(c)"], isSecuritySensitive: false)
        }
        return Result(flavor: .native, evidence: [], isSecuritySensitive: false)
    }
}
