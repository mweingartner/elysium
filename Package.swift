// swift-tools-version: 6.0
// Elysium — a native Swift + Metal block-survival game for macOS.
// CLI-only workflow: swift build -c release. No .xcodeproj.

import PackageDescription

// The privileged debug app is built in its own scratch tree by package-debug-app.sh. Keep its
// protocol dependency out of the ordinary product graph so Elysium.app cannot accidentally link
// even transport-only debug-control types. The packager supplies both this manifest-time opt-in
// and the matching compile-time ELYSIUM_DEBUG_CONTROL definition.
let debugControlBuild = Context.environment["ELYSIUM_DEBUG_CONTROL_BUILD"] == "1"
let elysiumDependencies: [Target.Dependency] = [
    "ElysiumCore", "ElysiumTextInput", "ElysiumAppSupport",
] + (debugControlBuild ? ["ElysiumDebugProtocol"] : [])

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
        // vendored Lua 5.4.8 + the Elysium patch/shim/sandbox; owned exclusively by
        // ElysiumScript (see openspec/changes/embed-lua-runtime/design.md Decision 1-4).
        .target(
            name: "CLua",
            path: "Sources/CLua",
            cSettings: [
                .define("LUA_USE_POSIX"),
                .define("LUAI_ASSERT", .when(configuration: .debug)),
            ]
        ),
        // the sandboxed embedded script runtime's Swift surface; the sole owner of CLua.
        .target(
            name: "ElysiumScript",
            dependencies: ["CLua", "ElysiumTextInput"],
            path: "Sources/ElysiumScript",
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
        // authenticated, transport-independent localhost debug-control protocol
        .target(
            name: "ElysiumDebugProtocol",
            path: "Sources/ElysiumDebugProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // the engine: headless-testable, no AppKit dependencies
        .target(
            name: "ElysiumCore",
            dependencies: ["ElysiumStorage", "ElysiumTextInput", "ElysiumScript"],
            path: "Sources/ElysiumCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // the app: AppKit + MTKView shell
        .executableTarget(
            name: "Elysium",
            dependencies: elysiumDependencies,
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
                .linkedFramework("WebKit"),
            ]
        ),
        // local CLI/controller for the opt-in Elysium Debug.app control plane
        .executableTarget(
            name: "elydebug",
            dependencies: ["ElysiumDebugProtocol"],
            path: "Sources/elydebug",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Network")]
        ),
        // headless smoke tests against the frozen golden baselines
        .executableTarget(
            name: "elysmoke",
            dependencies: ["ElysiumCore", "ElysiumScript"],
            path: "Sources/elysmoke",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ElysiumScriptTests",
            dependencies: ["ElysiumScript", "ElysiumCore", "ElysiumTextInput"],
            path: "Tests/ElysiumScriptTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ElysiumCoreTests",
            dependencies: ["ElysiumCore", "ElysiumScript", "ElysiumStorage", "ElysiumTextInput"],
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
        .testTarget(
            name: "ElysiumDebugProtocolTests",
            dependencies: ["ElysiumDebugProtocol"],
            path: "Tests/ElysiumDebugProtocolTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ElysiumResourcePackTests",
            dependencies: ["Elysium"],
            path: "Tests/ElysiumResourcePackTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
