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
    dependencies: [
        // Sparkle 2.x — auto-update framework. Used only by the
        // app target (the Xcode target wires it in directly via the
        // .xcodeproj's PBXSwiftPackageProductDependency block).
        // Pinned to the 2.x major; 2.x has been stable for years
        // and 1.x is end-of-life. Bump the floor when a new release
        // ships — the Swift Package Index dashboard at
        // https://swiftpackageindex.com/sparkle-project/Sparkle is
        // the source of truth. See docs/RELEASES.md for the appcast
        // generation flow.
        .package(url: "https://github.com/sparkle-project/Sparkle",
                 from: "2.9.0")
    ],
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
