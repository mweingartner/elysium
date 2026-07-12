// swift-tools-version: 6.0
// Pebble — a native Swift + Metal block-survival game for macOS.
// CLI-only workflow: swift build -c release. No .xcodeproj.

import PackageDescription

let package = Package(
    name: "Pebble",
    platforms: [.macOS(.v14)],
    targets: [
        // shared pure text-ingress kernels; deliberately not exposed as a product
        .target(
            name: "PebbleTextInput",
            path: "Sources/PebbleTextInput",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // shared production AppKit disposition/retention kernels; no standalone product
        .target(
            name: "PebbleAppSupport",
            path: "Sources/PebbleAppSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // nonshipping release/receipt authority shared by the CLI adapter and executable tests
        .target(
            name: "PebbleReleaseGate",
            path: "Sources/PebbleReleaseGate",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security")]
        ),
        // the persistence boundary: typed rows/facades only; no engine dependency
        .target(
            name: "PebbleStorage",
            path: "Sources/PebbleStorage",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // the engine: headless-testable, no AppKit dependencies
        .target(
            name: "PebbleCore",
            dependencies: ["PebbleStorage", "PebbleTextInput"],
            path: "Sources/PebbleCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // the app: AppKit + MTKView shell
        .executableTarget(
            name: "Pebble",
            dependencies: ["PebbleCore", "PebbleTextInput", "PebbleAppSupport"],
            path: "Sources/Pebble",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("GameController"),
            ]
        ),
        // headless smoke tests against the frozen golden baselines
        .executableTarget(
            name: "pebsmoke",
            dependencies: ["PebbleCore"],
            path: "Sources/pebsmoke",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PebbleCoreTests",
            dependencies: ["PebbleCore", "PebbleStorage", "PebbleTextInput"],
            path: "Tests/PebbleCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PebbleTextInputTests",
            dependencies: ["PebbleTextInput"],
            path: "Tests/PebbleTextInputTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PebbleAppSupportTests",
            dependencies: ["PebbleAppSupport"],
            path: "Tests/PebbleAppSupportTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PebbleReleaseGateTests",
            dependencies: ["PebbleReleaseGate"],
            path: "Tests/PebbleReleaseGateTests",
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security")]
        ),
    ]
)
