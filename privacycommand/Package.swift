// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "privacycommand",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "privacycommandCore", targets: ["privacycommandCore"]),
        .library(name: "privacycommandGuestProtocol",
                 targets: ["privacycommandGuestProtocol"]),
        // The CLI. Named after the app: the release build embeds it at
        // privacycommand.app/Contents/Helpers/privacycommand.
        .executable(name: "privacycommand", targets: ["privacycommandCLI"]),
        .executable(name: "privacycommand-guest",
                    targets: ["privacycommandGuestAgent"])
    ],
    // No SwiftPM-level dependencies — every target in this manifest
    // is headless (Core, the guest agent, the CLI smoke test). The
    // SwiftUI app target lives only in privacycommand.xcodeproj and
    // pulls in Sparkle through Xcode's "Add Package Dependencies"
    // UI, which writes to the project's XCRemoteSwiftPackageReference
    // blocks rather than this manifest.
    //
    // Declaring Sparkle here would just emit a "dependency not used
    // by any target" warning on every `swift build` — see
    // docs/RELEASES.md for how the Xcode side wires it in.
    targets: [
        // Wire format the host and the in-VM agent share. Kept in its
        // own target with no dependencies so the guest agent can be
        // built without dragging Core in, and Core can ship the
        // `GuestObservationStream` host-side connector.
        .target(
            name: "privacycommandGuestProtocol",
            path: "Sources/privacycommandGuestProtocol"
        ),
        .target(
            name: "privacycommandCore",
            dependencies: ["privacycommandGuestProtocol"],
            path: "Sources/privacycommandCore",
            resources: [
                .copy("../../Resources/PrivacyKeyDatabase.json"),
                .copy("../../Resources/PathClassifier.json"),
                .copy("../../Resources/RiskRules.json")
            ],
            // macOS ships libsqlite3; we link it to read external
            // SQLite databases (TCC.db, Malimite / mac_apt exports)
            // through the read-only `SQLiteReader`. No SwiftPM package
            // dependency — `import SQLite3` resolves against the SDK's
            // system module. The Xcode app target needs the same link
            // flag (see privacycommand.xcodeproj).
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // Pure, testable CLI/TUI logic (input decoding, browser state, frame
        // rendering, ANSI styling). Split out of the executable so
        // `privacycommandCLIKitTests` can cover it — the executable stays a thin
        // termios / poll-loop / IO shell around this.
        .target(
            name: "privacycommandCLIKit",
            dependencies: ["privacycommandCore"],
            path: "Sources/privacycommandCLIKit"
        ),
        .executableTarget(
            name: "privacycommandCLI",
            dependencies: ["privacycommandCLIKit", "privacycommandCore"],
            path: "Sources/privacycommandCLI"
        ),
        // Runs inside the macOS guest VM — listens for commands from
        // the host, runs the inspected app, ships observations back.
        // See docs/GUEST_AGENT.md for build / deploy instructions.
        .executableTarget(
            name: "privacycommandGuestAgent",
            dependencies: ["privacycommandGuestProtocol", "privacycommandCore"],
            path: "Sources/privacycommandGuestAgent"
        ),
        .testTarget(
            name: "privacycommandCoreTests",
            dependencies: ["privacycommandCore", "privacycommandGuestProtocol"],
            path: "Tests/privacycommandCoreTests"
        ),
        .testTarget(
            name: "privacycommandCLIKitTests",
            dependencies: ["privacycommandCLIKit", "privacycommandCore"],
            path: "Tests/privacycommandCLIKitTests"
        )
    ]
)
