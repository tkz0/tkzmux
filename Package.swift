// swift-tools-version: 6.2
// tkzmux — native macOS Claude Code session manager, with a Linux port in progress (docs/linux/).
// Pure SwiftPM; the .app bundle is assembled by `make app` (scripts/make-app.sh).
// Swift 6 language mode (strict concurrency) is the default for tools-version 6.x.
//
// One manifest, two target graphs, branched on the HOST with `#if os(Linux)`. SwiftPM evaluates
// this file on the machine that runs it, so only native builds are supported: a cross-compile from
// a Mac would silently take the macOS branch (`make` refuses one). `.when(platforms:)` alone is not
// enough, because `swift build` and `swift test` compile every root non-test target, so the AppKit,
// Metal and CoreText targets must not be in the Linux graph at all (docs/linux/build.md).
//
//   shared     builds on both OSes
//   macOnly    the rest of the macOS graph, unchanged from the macOS-only manifest
//   linuxOnly  Linux additions
//
// Arrays whose declaration line carries `hygiene-scan` are read by
// Tests/TkzCoreTests/RunLoopHygieneTests.swift: every `path: "Sources/…"`/`"Tests/…"` in them is
// checked for RunLoop/Timer APIs, which never fire under the Linux main loop. A target moved into
// `shared` or `linuxOnly` is covered without touching the test.
import PackageDescription

// MARK: - Shared (macOS and Linux)

#if os(Linux)
let ghosttyVtPath = "vendor/ghostty-vt/ghostty-vt-linux.artifactbundle"
#else
let ghosttyVtPath = "vendor/ghostty-vt/ghostty-vt.xcframework"
#endif

let sharedProducts: [Product] = [
    .library(name: "TkzCore", targets: ["TkzCore"]),
    .library(name: "TkzTerminalCore", targets: ["TkzTerminalCore"]),
]

let sharedTargets: [Target] = [  // hygiene-scan
    // MARK: Vendored libghostty-vt (M1.1).
    // Built by `make vendor` (scripts/build-ghostty-vt.sh) at the commit in vendor/ghostty-vt/COMMIT;
    // arm64-only static archive, module `GhosttyVt` (umbrella ghostty/vt.h). On Linux the same
    // module comes from an SE-0482 artifact bundle built by `make vendor-linux` at the same commit
    // (docs/linux/vendoring.md); its consumers link libm (`.linkedLibrary("m")`).
    .binaryTarget(
        name: "GhosttyVt",
        path: ghosttyVtPath
    ),

    // Leaf platform layer (WOR-304): one API per OS-specific primitive, a back-end per OS.
    // Foundation only, never AppKit or GTK; nothing in tkzmux below it.
    .target(
        name: "TkzPlatform",
        dependencies: ["TkzPlatformShim"],
        path: "Sources/TkzPlatform"
    ),
    // Its C half: the pidfd system calls Swift cannot make (Linux only; empty on macOS).
    .target(
        name: "TkzPlatformShim",
        path: "Sources/TkzPlatformShim",
        publicHeadersPath: "include"
    ),

    // fork/exec on a pty, the only C that runs in the child (WOR-305: clone3/pidfd on Linux).
    .target(
        name: "TkzPtyShim",
        dependencies: ["TkzPlatformShim"],
        path: "Sources/TkzPtyShim",
        publicHeadersPath: "include"
    ),

    .target(
        name: "TkzCore",
        dependencies: ["TkzPlatform"],
        path: "Sources/TkzCore"
    ),

    // MARK: Terminal engine
    .target(
        name: "TkzTerminalCore",
        dependencies: [
            "TkzCore",
            "TkzPtyShim",
            "GhosttyVt",
        ],
        path: "Sources/TkzTerminalCore",
        // The files live under the target (Sources/<target>/Resources), so `Bundle.module` works
        // for `swift test` / `swift run`; the repo-root Resources/* entries are symlinks to them.
        // make-app.sh copies the .bundle into the .app.
        resources: [.copy("Resources/terminfo")],
        // libghostty-vt's vendored simdutf/highway are built without libc++ (verified M1.1):
        // no linkerSettings: [.linkedLibrary("c++")] needed. Linux needs libm (see GhosttyVt).
        linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux]))]
    ),
    .testTarget(name: "TkzTerminalCoreTests", dependencies: ["TkzTerminalCore", "GhosttyVt"], path: "Tests/TkzTerminalCoreTests", resources: [.copy("Fixtures")]),

    .target(
        name: "Persistence",
        dependencies: ["TkzCore", "TkzPlatform"],
        path: "Sources/Persistence"
    ),

    // Fixtures/ (NIST SHAVS vectors) is read through #filePath, not bundled.
    .testTarget(name: "TkzPlatformTests", dependencies: ["TkzPlatform"], path: "Tests/TkzPlatformTests", exclude: ["Fixtures"]),
    .testTarget(name: "TkzCoreTests", dependencies: ["TkzCore"], path: "Tests/TkzCoreTests"),

    // Dependency-free PNG codec for the parity harness and Linux goldens (WOR-311 S6). Not linked
    // into the app; the Mac renderer keeps ImageIO.
    .target(name: "TkzPNG", path: "Sources/TkzPNG"),
    .testTarget(name: "TkzPNGTests", dependencies: ["TkzPNG"], path: "Tests/TkzPNGTests"),

    // The Swift/C/Metal (and, through TkzShadersSPIRV, Vulkan) struct contract. Header-only; the
    // header falls back to `ext_vector_type` typedefs where <simd/simd.h> is absent (WOR-311 S1).
    .target(
        name: "TkzShaderTypes",
        path: "Sources/TkzShaderTypes",
        publicHeadersPath: "include"
    ),

    // The device-free half of the renderer, shared by Metal and Vulkan (WOR-311): the font seam
    // and CellMetrics so far; WOR-311 S3-S5 move the atlas packer, FrameBuilder and the box-sprite
    // geometry in.
    .target(name: "TkzRenderCore", dependencies: ["TkzShaderTypes"], path: "Sources/TkzRenderCore"),
    .testTarget(name: "TkzRenderCoreTests", dependencies: ["TkzRenderCore", "TkzShaderTypes"], path: "Tests/TkzRenderCoreTests"),
]

// MARK: - Linux only

let linuxOnlyProducts: [Product] = [
    // Same product name as the Mac app, so the binary is `tkzmux` on both OSes.
    .executable(name: "tkzmux", targets: ["TkzmuxLinux"]),
]

let linuxOnlyTargets: [Target] = [  // hygiene-scan
    // The Linux entry point: `--version` and a libghostty-vt smoke check until WOR-314 brings the
    // GTK application.
    .executableTarget(
        name: "TkzmuxLinux",
        dependencies: ["TkzCore", "GhosttyVt"],
        path: "Sources/tkzmux-linux",
        linkerSettings: [.linkedLibrary("m")]
    ),

    // Committed SPIR-V for the Vulkan renderer (WOR-313 S2); regenerate with
    // scripts/build-shaders-linux.sh.
    .target(
        name: "TkzShadersSPIRV",
        path: "Sources/TkzShadersSPIRV",
        exclude: ["glsl", "generated"],
        publicHeadersPath: "include"
    ),
    .testTarget(
        name: "TkzShadersSPIRVTests",
        dependencies: ["TkzShadersSPIRV", "TkzShaderTypes"],
        path: "Tests/TkzShadersSPIRVTests"
    ),

    // The Mac's PersistenceTests also lists TkzTerminalCore and GhosttyVt; nothing in it imports
    // them, and neither is in the Linux graph yet (WOR-304 S3).
    .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "TkzCore"], path: "Tests/PersistenceTests"),

    .testTarget(
        name: "GhosttyVtSmokeTests",
        dependencies: ["GhosttyVt"],
        path: "Tests/GhosttyVtSmokeTests",
        linkerSettings: [.linkedLibrary("m")]
    ),
]

// MARK: - macOS only

let macOnlyProducts: [Product] = [
    .executable(name: "tkzmux", targets: ["tkzmux"]),
    .executable(name: "tkzmux-vtdump", targets: ["tkzmux-vtdump"]),
    .executable(name: "tkzmux-hook", targets: ["tkzmux-hook"]),
    .library(name: "TkzTerminalRender", targets: ["TkzTerminalRender"]),
    .library(name: "TkzTerminalView", targets: ["TkzTerminalView"]),
    .library(name: "AgentBridge", targets: ["AgentBridge"]),
    .library(name: "GitStatus", targets: ["GitStatus"]),
    .library(name: "Persistence", targets: ["Persistence"]),
    .library(name: "TkzApp", targets: ["TkzApp"]),
]

let macOnlyTargets: [Target] = [
    // MARK: Terminal engine
    .target(
        name: "TkzTerminalRender",
        dependencies: ["TkzCore", "TkzTerminalCore", "TkzShaderTypes", "TkzRenderCore"],
        path: "Sources/TkzTerminalRender",
        resources: [.copy("Resources/Fonts"), .copy("Resources/Shaders")]
    ),
    .target(
        name: "TkzTerminalView",
        dependencies: ["TkzCore", "TkzPlatform", "TkzTerminalCore", "TkzTerminalRender", "TkzRenderCore"],
        path: "Sources/TkzTerminalView"
    ),

    // MARK: App core and services
    .target(
        name: "AgentBridge",
        dependencies: ["TkzCore", "TkzPlatform"],
        path: "Sources/AgentBridge",
        resources: [
            .copy("Resources/shim"), .copy("Resources/zsh"), .copy("Resources/bash"),
            .copy("Resources/fish"),
        ]
    ),
    .target(
        name: "GitStatus",
        dependencies: ["TkzCore"],
        path: "Sources/GitStatus"
    ),
    .target(
        name: "TkzApp",
        dependencies: ["TkzCore", "TkzPlatform", "TkzTerminalCore", "TkzTerminalView", "AgentBridge", "GitStatus", "Persistence"],
        path: "Sources/TkzApp"
    ),

    // MARK: Executables
    .executableTarget(
        name: "tkzmux",
        // TkzCore for AppVersion: `--version` is answered before NSApplication exists (M6.1).
        dependencies: ["TkzApp", "TkzCore"],
        path: "Sources/tkzmux"
    ),
    .executableTarget(
        name: "tkzmux-vtdump",
        dependencies: ["TkzTerminalCore", "TkzTerminalRender", "TkzRenderCore", "Persistence"],
        path: "Sources/tkzmux-vtdump"
    ),
    .executableTarget(
        name: "tkzmux-hook",
        path: "Sources/tkzmux-hook"
    ),

    // MARK: Tests (one per Swift library module; Swift Testing)
    .testTarget(name: "TkzTerminalRenderTests", dependencies: ["TkzTerminalRender", "TkzRenderCore", "GhosttyVt", "TkzPNG"], path: "Tests/TkzTerminalRenderTests", resources: [.copy("Fixtures")]),
    .testTarget(name: "TkzTerminalViewTests", dependencies: ["TkzTerminalView", "TkzTerminalCore", "GhosttyVt"], path: "Tests/TkzTerminalViewTests"),
    // TkzTerminalCore + GhosttyVt for the shell-integration harness, which spawns each login
    // shell on a real `Pty`, like PersistenceTests does for snapshots.
    .testTarget(name: "AgentBridgeTests", dependencies: ["AgentBridge", "TkzTerminalCore", "GhosttyVt"], path: "Tests/AgentBridgeTests", resources: [.copy("Fixtures")]),
    .testTarget(name: "GitStatusTests", dependencies: ["GitStatus"], path: "Tests/GitStatusTests"),
    .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "TkzTerminalCore", "GhosttyVt"], path: "Tests/PersistenceTests"),
    .testTarget(name: "TkzAppTests", dependencies: ["TkzApp"], path: "Tests/TkzAppTests"),
]

// MARK: - Package

#if os(Linux)
let products = sharedProducts + linuxOnlyProducts
let targets = sharedTargets + linuxOnlyTargets
#else
let products = sharedProducts + macOnlyProducts
let targets = sharedTargets + macOnlyTargets
#endif

let package = Package(
    name: "tkzmux",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets
)
