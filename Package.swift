// swift-tools-version: 6.2
// tkzmux — native macOS Claude Code session manager.
// Pure SwiftPM; the .app bundle is assembled by `make app` (scripts/make-app.sh).
// Swift 6 language mode (strict concurrency) is the default for tools-version 6.x.
import PackageDescription

let package = Package(
    name: "tkzmux",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "tkzmux", targets: ["tkzmux"]),
        .executable(name: "tkzmux-vtdump", targets: ["tkzmux-vtdump"]),
        .executable(name: "tkzmux-hook", targets: ["tkzmux-hook"]),
        .library(name: "TkzTerminalCore", targets: ["TkzTerminalCore"]),
        .library(name: "TkzTerminalRender", targets: ["TkzTerminalRender"]),
        .library(name: "TkzTerminalView", targets: ["TkzTerminalView"]),
        .library(name: "TkzCore", targets: ["TkzCore"]),
        .library(name: "ClaudeBridge", targets: ["ClaudeBridge"]),
        .library(name: "GitStatus", targets: ["GitStatus"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "TkzApp", targets: ["TkzApp"]),
    ],
    targets: [
        // MARK: Vendored libghostty-vt (added in M1.1 / TKZ-7).
        // Produced by `make vendor` (scripts/build-ghostty-vt.sh) at a pinned commit.
        // .binaryTarget(
        //     name: "GhosttyVt",
        //     path: "vendor/ghostty-vt/ghostty-vt.xcframework"
        // ),

        // MARK: C targets
        .target(
            name: "TkzPtyShim",
            path: "Sources/TkzPtyShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "TkzShaderTypes",
            path: "Sources/TkzShaderTypes",
            publicHeadersPath: "include"
        ),

        // MARK: Terminal engine
        .target(
            name: "TkzTerminalCore",
            dependencies: [
                "TkzPtyShim",
                // "GhosttyVt",   // M1.1
            ],
            path: "Sources/TkzTerminalCore"
            // If the SIMD build of libghostty-vt fails to link on std::__1 symbols (M1.1):
            // linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(
            name: "TkzTerminalRender",
            dependencies: ["TkzTerminalCore", "TkzShaderTypes"],
            path: "Sources/TkzTerminalRender"
        ),
        .target(
            name: "TkzTerminalView",
            dependencies: ["TkzTerminalRender"],
            path: "Sources/TkzTerminalView"
        ),

        // MARK: App core and services
        .target(
            name: "TkzCore",
            path: "Sources/TkzCore"
        ),
        .target(
            name: "ClaudeBridge",
            dependencies: ["TkzCore"],
            path: "Sources/ClaudeBridge"
        ),
        .target(
            name: "GitStatus",
            dependencies: ["TkzCore"],
            path: "Sources/GitStatus"
        ),
        .target(
            name: "Persistence",
            dependencies: ["TkzCore"],
            path: "Sources/Persistence"
        ),
        .target(
            name: "TkzApp",
            dependencies: ["TkzCore", "TkzTerminalView", "ClaudeBridge", "GitStatus", "Persistence"],
            path: "Sources/TkzApp"
        ),

        // MARK: Executables
        .executableTarget(
            name: "tkzmux",
            dependencies: ["TkzApp"],
            path: "Sources/tkzmux"
        ),
        .executableTarget(
            name: "tkzmux-vtdump",
            dependencies: ["TkzTerminalCore"],
            path: "Sources/tkzmux-vtdump"
        ),
        .executableTarget(
            name: "tkzmux-hook",
            path: "Sources/tkzmux-hook"
        ),

        // MARK: Tests (one per Swift library module; Swift Testing)
        .testTarget(name: "TkzTerminalCoreTests", dependencies: ["TkzTerminalCore"], path: "Tests/TkzTerminalCoreTests"),
        .testTarget(name: "TkzTerminalRenderTests", dependencies: ["TkzTerminalRender"], path: "Tests/TkzTerminalRenderTests"),
        .testTarget(name: "TkzTerminalViewTests", dependencies: ["TkzTerminalView"], path: "Tests/TkzTerminalViewTests"),
        .testTarget(name: "TkzCoreTests", dependencies: ["TkzCore"], path: "Tests/TkzCoreTests"),
        .testTarget(name: "ClaudeBridgeTests", dependencies: ["ClaudeBridge"], path: "Tests/ClaudeBridgeTests"),
        .testTarget(name: "GitStatusTests", dependencies: ["GitStatus"], path: "Tests/GitStatusTests"),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"], path: "Tests/PersistenceTests"),
        .testTarget(name: "TkzAppTests", dependencies: ["TkzApp"], path: "Tests/TkzAppTests"),
    ]
)
