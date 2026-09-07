// tkzmux-vtdump — headless VT tooling. See docs/design.md → *Testing without UI*.
//
//   abi                                   the libghostty-vt ABI manifest (ghostty_type_json)
//   version                               vendored library version + build options
//   record   …                            tee a real pty session into a .tkzrec (M1.3 follow-up)
//   replay   [--format …] <file.tkzrec>   feed a recording into a terminal and dump the screen
//   replay   --modes      <file.tkzrec>   the modes / kitty flags the recording left behind
//   replay   --snapshot   <file.tkzrec>   snapshot round-trip: encoded size + restore time
//
// Hand-rolled argument parsing on purpose: no third-party dependencies (CLAUDE.md).
import Foundation
import GhosttyVt
import TkzTerminalCore

let usage = """
usage: tkzmux-vtdump <command> [options]

  abi                       print the libghostty-vt ABI manifest (ghostty_type_json) as sorted, pretty JSON
  version                   print the vendored libghostty-vt version and build options

  record  [options] -- <cmd> …
                            record a pty session into a .tkzrec file
      --cols <n>            terminal width  (default 120)
      --rows <n>            terminal height (default 40)
      --out <file>          output path (required)

  replay  [options] <file.tkzrec>
      --format plain|vt|html   dump the screen through ghostty_formatter_format_alloc (default plain)
      --modes                  print modes 1049/2004/1000/1006/2026/25/1004 + kitty keyboard flags
      --snapshot               round-trip through a snapshot; report encoded size and restore time
      --unwrap                 unwrap soft-wrapped lines (plain/vt)
      --no-trim                keep trailing whitespace
      --cols <n> --rows <n>    override the recording's geometry
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// `vendor/ghostty-vt/COMMIT` relative to this source file (a dev tool; the repo path is compile-time).
func vendoredCommit() -> String? {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let file = repoRoot.appending(path: "vendor/ghostty-vt/COMMIT")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    let commit = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return commit.isEmpty ? nil : commit
}

// MARK: - Tiny argument parser

/// Splits `--flag value`, `--flag`, `-- rest…` and positionals. Unknown flags are an error at the
/// point of use, not here, so each subcommand decides what it accepts.
struct Arguments {
    private(set) var flags: [String: String] = [:]
    private(set) var positionals: [String] = []
    private(set) var trailing: [String] = []

    init(_ argv: [String], valueFlags: Set<String>) {
        var index = argv.startIndex
        while index < argv.endIndex {
            let argument = argv[index]
            if argument == "--" {
                trailing = Array(argv[argv.index(after: index)...])
                return
            }
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if valueFlags.contains(name) {
                    let next = argv.index(after: index)
                    guard next < argv.endIndex else { fail("tkzmux-vtdump: --\(name) needs a value", code: 2) }
                    flags[name] = argv[next]
                    index = argv.index(after: next)
                    continue
                }
                flags[name] = ""
            } else {
                positionals.append(argument)
            }
            index = argv.index(after: index)
        }
    }

    func has(_ name: String) -> Bool { flags[name] != nil }
    func value(_ name: String) -> String? { flags[name].flatMap { $0.isEmpty ? nil : $0 } }
    func uint16(_ name: String) -> UInt16? { value(name).flatMap(UInt16.init) }
}

// MARK: - replay

func runReplay(_ argv: [String]) throws {
    let arguments = Arguments(argv, valueFlags: ["format", "cols", "rows"])
    guard let path = arguments.positionals.first else { fail("tkzmux-vtdump replay: missing <file.tkzrec>", code: 2) }

    let reader = try RecordingReader(contentsOf: URL(fileURLWithPath: path))
    let cols = arguments.uint16("cols") ?? reader.header.cols
    let rows = arguments.uint16("rows") ?? reader.header.rows
    let session = try TerminalSession(options: TerminalSessionOptions(cols: cols, rows: rows))

    let replied = Replies()
    session.setOnWritePty { replied.append($0) }

    let start = ContinuousClock.now
    try reader.replay(into: session)
    let elapsed = ContinuousClock.now - start

    if arguments.has("modes") {
        printModes(session, reader: reader, elapsed: elapsed, replies: replied)
        return
    }
    if arguments.has("snapshot") {
        try printSnapshotRoundTrip(session)
        return
    }

    let format: GhosttyFormatterFormat
    switch arguments.value("format") ?? "plain" {
    case "plain": format = GHOSTTY_FORMATTER_FORMAT_PLAIN
    case "vt": format = GHOSTTY_FORMATTER_FORMAT_VT
    case "html": format = GHOSTTY_FORMATTER_FORMAT_HTML
    case let other: fail("tkzmux-vtdump replay: unknown --format \(other) (plain|vt|html)", code: 2)
    }
    print(try session.formatted(format, trim: !arguments.has("no-trim"), unwrap: arguments.has("unwrap")))
}

/// Captures whatever the terminal wrote back to the "pty" during a replay.
final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var bytes: Data { lock.withLock { data } }
}

func printModes(_ session: TerminalSession, reader: RecordingReader, elapsed: Duration, replies: Replies) {
    let modes: [(UInt16, String)] = [
        (1049, "alt screen + save cursor"),
        (2004, "bracketed paste"),
        (1000, "normal mouse tracking"),
        (1006, "SGR mouse format"),
        (2026, "synchronized output"),
        (25, "cursor visible (DECTCEM)"),
        (1004, "focus events"),
    ]
    print("recording: \(reader.header.cols)x\(reader.header.rows), \(reader.frames.count) frames, "
        + "\(reader.outputByteCount) output bytes\(reader.truncated ? " (truncated)" : "")")
    print("replayed in \(elapsed)")
    print("")
    for (mode, description) in modes {
        print("  ?\(mode)\t\(session.mode(mode) ? "set  " : "reset") \t\(description)")
    }
    let flags = session.kittyKeyboardFlags
    print("")
    print("  kitty keyboard flags: \(flags) (0b\(String(flags, radix: 2)))")
    print("  mouse tracking: \(session.mouseTrackingEnabled)")
    print("  title: \(session.title.isEmpty ? "<unset>" : session.title)")
    print("  pwd:   \(session.pwd.isEmpty ? "<unset>" : session.pwd)")
    print("  scrollback rows: \(session.scrollbackRows)")
    let replyBytes = replies.bytes
    if !replyBytes.isEmpty {
        print("  wrote back to pty: \(replyBytes.count) bytes \(escape(replyBytes))")
    }
}

func printSnapshotRoundTrip(_ session: TerminalSession) throws {
    let before = try session.formatted()

    let encodeStart = ContinuousClock.now
    let blob = try session.snapshot()
    let encodeElapsed = ContinuousClock.now - encodeStart

    let restoreStart = ContinuousClock.now
    try session.restore(from: blob)
    let restoreElapsed = ContinuousClock.now - restoreStart

    let after = try session.formatted()
    print("snapshot: \(blob.count) bytes (\(String(format: "%.2f", Double(blob.count) / 1_048_576)) MiB)")
    print("encode:   \(encodeElapsed)")
    print("restore:  \(restoreElapsed)")
    print("screen identical after restore: \(before == after)")
}

/// Renders bytes so escape sequences are readable in a terminal.
func escape(_ data: Data) -> String {
    var out = ""
    for byte in data {
        switch byte {
        case 0x1B: out += "ESC"
        case 0x20...0x7E: out.append(Character(UnicodeScalar(byte)))
        default: out += String(format: "<%02x>", byte)
        }
    }
    return out
}

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())

do {
    switch argv.first {
    case "abi":
        let raw = GhosttyVtInfo.abiManifestJSON
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8)
        else {
            print(raw)
            fail("tkzmux-vtdump: ghostty_type_json() is not valid JSON", code: 1)
        }
        print(text)

    case "version":
        var line = "libghostty-vt \(GhosttyVtInfo.versionString)"
            + "  simd=\(GhosttyVtInfo.simd)"
            + " kitty-graphics=\(GhosttyVtInfo.kittyGraphics)"
            + " tmux-control-mode=\(GhosttyVtInfo.tmuxControlMode)"
            + " optimize=\(GhosttyVtInfo.optimizeName)"
        if let commit = vendoredCommit() { line += "  commit=\(commit)" }
        print(line)

    case "replay":
        try runReplay(Array(argv.dropFirst()))

    case "record":
        // Needs the pty layer (M1.2 / TKZ-8); the .tkzrec writer it will use is already in
        // TkzTerminalCore (Recording.swift), so this is a small addition.
        fail("tkzmux-vtdump: record is not implemented yet (needs the pty layer)", code: 2)

    case "render":
        fail("tkzmux-vtdump: render is not implemented yet (M1.5 / TKZ-11)", code: 2)

    default:
        fail(usage, code: 2)
    }
} catch let error as GhosttyError {
    fail("tkzmux-vtdump: \(error.operation) failed (\(error.result))", code: 1)
} catch {
    fail("tkzmux-vtdump: \(error)", code: 1)
}
