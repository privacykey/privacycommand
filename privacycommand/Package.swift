// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "privacycommand",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "privacycommandCore", targets: ["privacycommandCore"]),
        .library(name: "privacycommandGuestProtocol",
                 targets: ["privacycommandGuestProtocol"]),
        .executable(name: "auditctl", targets: ["auditctl"]),
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
            ]
        ),
        .executableTarget(
            name: "auditctl",
            dependencies: ["privacycommandCore"],
            path: "Sources/auditctl"
        ),
        // Runs inside the macOS guest VM — listens for commands from
        // the host, runs the inspected app, ships observations back.
        // See docs/GUEST_AGENT.md for build / deploy instructions.
        .executableTarget(
            name: "privacycommandGuestAgent",
            dependencies: ["privacycommandGuestProtocol"],
            path: "Sources/privacycommandGuestAgent"
        ),
        .testTarget(
            name: "privacycommandCoreTests",
            dependencies: ["privacycommandCore"],
            path: "Tests/privacycommandCoreTests"
        )
    ]
)
