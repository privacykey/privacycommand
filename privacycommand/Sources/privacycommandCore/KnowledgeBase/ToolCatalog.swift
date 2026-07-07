import Foundation

/// A curated, de-duplicated catalog of external tools for digging deeper into
/// an app — "want to go further? here are vetted tools." Distilled from the
/// CC0 list **ashishb/osx-and-ios-security-awesome** (stale entries pruned;
/// see NOTICES for attribution), grouped so the UI can surface the relevant
/// ones next to a finding (e.g. reverse-engineering tools by the disassembler).
public struct AnalysisTool: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let blurb: String
    public let urlString: String
    public let category: Category

    public enum Category: String, Sendable, Hashable, CaseIterable {
        case reverseEngineering = "Reverse engineering"
        case dynamicAnalysis    = "Dynamic analysis"
        case forensics          = "Forensics & provenance"
        case network            = "Network"
    }

    public var url: URL? { URL(string: urlString) }

    public init(name: String, blurb: String, urlString: String, category: Category) {
        self.name = name
        self.blurb = blurb
        self.urlString = urlString
        self.category = category
    }
}

public enum ToolCatalog {
    public static let all: [AnalysisTool] = [
        // Reverse engineering / static
        .init(name: "Ghidra", blurb: "NSA's open-source SRE suite. privacycommand drives its headless analyzer for on-demand and whole-app decompilation.", urlString: "https://ghidra-sre.org", category: .reverseEngineering),
        .init(name: "Hopper Disassembler", blurb: "Native macOS disassembler/decompiler for Mach-O.", urlString: "https://www.hopperapp.com", category: .reverseEngineering),
        .init(name: "Rizin / Cutter", blurb: "Open-source reverse-engineering framework with a Qt GUI (Cutter).", urlString: "https://cutter.re", category: .reverseEngineering),
        .init(name: "class-dump", blurb: "Recovers Objective-C class/method declarations from a Mach-O.", urlString: "https://github.com/nygard/class-dump", category: .reverseEngineering),
        .init(name: "Malimite", blurb: "iOS/macOS decompiler built on Ghidra. Produce a project database, then import it here.", urlString: "https://github.com/LaurieWired/Malimite", category: .reverseEngineering),

        // Dynamic analysis
        .init(name: "Frida", blurb: "Dynamic instrumentation — hook and trace functions in a running process.", urlString: "https://frida.re", category: .dynamicAnalysis),
        .init(name: "Objection", blurb: "Frida-powered runtime exploration for mobile apps.", urlString: "https://github.com/sensepost/objection", category: .dynamicAnalysis),

        // Forensics & provenance
        .init(name: "mac_apt", blurb: "macOS/iOS forensic artifact parser (TCC, Spotlight, quarantine, …). Export to SQLite and import its TCC table here.", urlString: "https://github.com/ydkhatri/mac_apt", category: .forensics),
        .init(name: "Objective-See tools", blurb: "KnockKnock, BlockBlock, and friends — persistence and behavior monitors for macOS.", urlString: "https://objective-see.org/tools.html", category: .forensics),
        .init(name: "Suspicious Package", blurb: "Inspect the contents and scripts of a macOS installer .pkg before running it.", urlString: "https://www.mothersruin.com/software/SuspiciousPackage/", category: .forensics),

        // Network
        .init(name: "Wireshark", blurb: "Capture and inspect network traffic at the packet level.", urlString: "https://www.wireshark.org", category: .network),
        .init(name: "Proxyman", blurb: "Native macOS HTTP(S) debugging proxy for inspecting app traffic.", urlString: "https://proxyman.io", category: .network),
    ]

    public static func tools(in category: AnalysisTool.Category) -> [AnalysisTool] {
        all.filter { $0.category == category }
    }
}
