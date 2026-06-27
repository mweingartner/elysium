// swift-tools-version: 6.0
// Pebble — a native Swift + Metal block-survival game for macOS.
// CLI-only workflow: swift build -c release. No .xcodeproj.

import PackageDescription

let package = Package(
    name: "Pebble",
    platforms: [.macOS(.v14)],
    targets: [
        // the engine: headless-testable, no AppKit dependencies
        .target(
            name: "PebbleCore",
            path: "Sources/PebbleCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // the app: AppKit + MTKView shell
        .executableTarget(
            name: "Pebble",
            dependencies: ["PebbleCore"],
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
            dependencies: ["PebbleCore"],
            path: "Tests/PebbleCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
