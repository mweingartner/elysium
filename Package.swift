// swift-tools-version: 6.0
// Elysium — a native Swift + Metal block-survival game for macOS.
// CLI-only workflow: swift build -c release. No .xcodeproj.

import PackageDescription

let package = Package(
    name: "Elysium",
    platforms: [.macOS(.v14)],
    targets: [
        // shared pure text-ingress kernels; deliberately not exposed as a product
        .target(
            name: "ElysiumTextInput",
            path: "Sources/ElysiumTextInput",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // shared production AppKit disposition/retention kernels; no standalone product
        .target(
            name: "ElysiumAppSupport",
            path: "Sources/ElysiumAppSupport",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // the persistence boundary: typed rows/facades only; no engine dependency
        .target(
            name: "ElysiumStorage",
            path: "Sources/ElysiumStorage",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // the engine: headless-testable, no AppKit dependencies
        .target(
            name: "ElysiumCore",
            dependencies: ["ElysiumStorage", "ElysiumTextInput"],
            path: "Sources/ElysiumCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // the app: AppKit + MTKView shell
        .executableTarget(
            name: "Elysium",
            dependencies: ["ElysiumCore", "ElysiumTextInput", "ElysiumAppSupport"],
            path: "Sources/Elysium",
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
            name: "elysmoke",
            dependencies: ["ElysiumCore"],
            path: "Sources/elysmoke",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ElysiumCoreTests",
            dependencies: ["ElysiumCore", "ElysiumStorage", "ElysiumTextInput"],
            path: "Tests/ElysiumCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ElysiumTextInputTests",
            dependencies: ["ElysiumTextInput"],
            path: "Tests/ElysiumTextInputTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ElysiumAppSupportTests",
            dependencies: ["ElysiumAppSupport"],
            path: "Tests/ElysiumAppSupportTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
