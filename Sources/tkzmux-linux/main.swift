// tkzmux on Linux — the entry point until WOR-314 brings the GTK application.
//
// Seven cases, all answered synchronously on the main thread (no async main, no `dispatchMain()`:
// WOR-314's GTK loop must own this thread, so nothing here may start a different one):
//
//   --version, -v        the banner, exactly as `Sources/tkzmux/main.swift` prints it on the Mac;
//                        on Linux its values come from `<prefix>/lib/tkzmux/version.plist`
//   --vt-smoke           hidden: feeds `hello` to a libghostty-vt terminal and prints the
//                        formatted screen, proving the vendored archive links and runs in this binary
//   --locate-resources   hidden: one `<module> <bundle path>` line per resource bundle as this
//                        process resolves it (`ResourceLocator`), exit 1 if any is missing. The
//                        relocated-install test (`InstalledStubTests`) needs the real process,
//                        because the lookup starts at `/proc/self/exe`
//   --main-loop-check    hidden: iterates the default GMainContext headless and checks that the
//                        main actor and libdispatch's main queue run on this thread (MainLoopCheck)
//   --canvas-cycle-check hidden, needs a display: opens and closes windows holding a TkzCanvas and
//                        checks that every box, canvas and toplevel is gone again (CanvasCycleCheck)
//   --presentation-check hidden, needs a display and a Vulkan device: one GtkCanvasHost window
//                        presenting Vulkan frames as dma-buf textures (PresentationCheck)
//   anything else        "not yet implemented" on stderr, exit 69 (EX_UNAVAILABLE)
//
// Like the Mac entry point, `--version` is a *scan* rather than a match on argv[1].

import Foundation
import GhosttyVt
import TkzCore

let arguments = CommandLine.arguments.dropFirst()

if arguments.contains(where: { $0 == "--version" || $0 == "-v" }) {
    print(AppVersion.current.description)
    exit(0)
}

if arguments.contains("--vt-smoke") {
    exit(vtSmoke())
}

if arguments.contains("--locate-resources") {
    exit(locateResources())
}

if arguments.contains("--main-loop-check") {
    exit(MainLoopCheck.run())
}

if arguments.contains("--canvas-cycle-check") {
    exit(CanvasCycleCheck.run(arguments: Array(arguments)))
}

if arguments.contains("--presentation-check") {
    exit(PresentationCheck.run(arguments: Array(arguments)))
}

FileHandle.standardError.write(Data("tkzmux: not yet implemented on Linux (try --version)\n".utf8))
exit(69)

/// Prints where each module's resource bundle resolves. Returns 0, or 1 if any is missing.
func locateResources() -> Int32 {
    let locator = ResourceLocator.current
    var status: Int32 = 0
    for module in ResourceLocator.resourceModules {
        if let url = locator.bundleURL(forModule: module) {
            print("\(module) \(url.path)")
        } else {
            FileHandle.standardError.write(Data("tkzmux: no resource bundle for \(module)\n".utf8))
            status = 1
        }
    }
    return status
}

/// Creates an 80×24 terminal, writes `hello` to it and prints its plain-text screen. Returns the
/// exit status: 0, or 1 with the failing call on stderr.
func vtSmoke() -> Int32 {
    func fail(_ operation: String, _ result: GhosttyResult) -> Int32 {
        FileHandle.standardError.write(Data("tkzmux: \(operation) failed (\(result.rawValue))\n".utf8))
        return 1
    }

    var terminal: GhosttyTerminal?
    var result = ghostty_terminal_new(nil, &terminal, 80, 24)
    guard result == GHOSTTY_SUCCESS, let terminal else { return fail("ghostty_terminal_new", result) }
    defer { ghostty_terminal_free(terminal) }

    let input: [UInt8] = Array("hello".utf8)
    input.withUnsafeBufferPointer { ghostty_terminal_vt_write(terminal, $0.baseAddress, $0.count) }

    // Sized-struct ABI: C `sizeof` is Swift's `stride` (see GhosttyVt+Swift.swift).
    var options = GhosttyFormatterTerminalOptions()
    options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.stride
    options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
    options.trim = true

    var formatter: GhosttyFormatter?
    result = ghostty_formatter_terminal_new(nil, &formatter, terminal, options)
    guard result == GHOSTTY_SUCCESS, let formatter else { return fail("ghostty_formatter_terminal_new", result) }
    defer { ghostty_formatter_free(formatter) }

    var buffer: UnsafeMutablePointer<UInt8>?
    var length = 0
    result = ghostty_formatter_format_alloc(formatter, nil, &buffer, &length)
    // No buffer means an empty screen, which after `hello` is a failure too.
    guard result == GHOSTTY_SUCCESS, let buffer else { return fail("ghostty_formatter_format_alloc", result) }
    defer { ghostty_free(nil, buffer, length) }
    print(String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self))
    return 0
}
