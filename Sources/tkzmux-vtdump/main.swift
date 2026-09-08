// tkzmux-vtdump — headless VT tooling. See docs/design.md → *Testing without UI*.
//
//   abi                                   the libghostty-vt ABI manifest (ghostty_type_json)
//   version                               vendored library version + build options
//   record   … -- <cmd>                   tee a real pty session into a .tkzrec
//   replay   [--format …] <file.tkzrec>   feed a recording into a terminal and dump the screen
//   replay   --modes      <file.tkzrec>   the modes / kitty flags the recording left behind
//   replay   --snapshot   <file.tkzrec>   snapshot round-trip: encoded size + restore time
//
// Hand-rolled argument parsing on purpose: no third-party dependencies (CLAUDE.md).
import Darwin
import Dispatch
import Foundation
import GhosttyVt
import TkzTerminalCore
import TkzTerminalRender

let usage = """
usage: tkzmux-vtdump <command> [options]

  abi                       print the libghostty-vt ABI manifest (ghostty_type_json) as sorted, pretty JSON
  version                   print the vendored libghostty-vt version and build options

  record  [options] -- <cmd> [args …]
                            spawn <cmd> on a pty under the full tkzmux environment
                            (TERM=xterm-ghostty, TERM_PROGRAM=ghostty, bundled TERMINFO) and tee
                            every byte it writes into a .tkzrec
      --out <file>          output path (required)
      --cols <n> --rows <n> geometry (default: the real terminal's size, else 120x40)
      --cwd <dir>           working directory for the child (default: the current directory)
      --script <file>       drive the child from a script instead of stdin (see below)
      --golden <file>       also write the final PLAIN screen there
      --note <text>         free-form note stored in the recording header
      --timeout <ms>        give up and SIGHUP the child after this long (default 120000)
      --quiet               do not echo the child's output to our own stdout

    script syntax, one command per line ('#' starts a comment):
      wait <ms>                     sleep
      waitfor "<text>" [<ms>]       wait until the rendered screen contains <text> (default 30000)
      send "<text>"                 write to the pty; \\n \\r \\t \\e \\xNN \\\\ are decoded
      resize <cols> <rows>          TIOCSWINSZ + a resize frame in the recording
      stop                          SIGKILL the child and end the recording *now* — no teardown,
                                    so the fixture keeps the modes the program had while running

    The child gets a minimal base environment (HOME, PATH, SHELL, USER, LOGNAME, TMPDIR, LANG)
    plus the full tkzmux contract, so recordings are reproducible and cannot carry the recording
    user's environment. --inherit-env keeps the current process environment instead.

  state-churn <dir> [--iterations n] [--seed n]
                            mutate and save <dir>/state.json in a tight loop until killed. The
                            crash-safety harness for M5.1: scripts/state-crash-test.sh SIGKILLs it
                            at random moments and asserts the survivor still parses.

  render  --out <file.png> [--cols n] [--rows n] <file.tkzrec>
                            replay a recording and rasterise the screen offscreen (M1.5)
  atlas   --out <prefix> [--point-size n] [--scale n] [--sample <text>]
                            dump the glyph atlas textures as PNGs (M1.4)

  bench   --sessions <n> [--busy <k>] [--seconds <s>] [--fill uniform|varied] [--lines <n>]
          [--no-compress] [--json <file>]
                            spawn <n> real zsh sessions, fill <k>, idle for <s>, then snapshot and
                            restore all of them; prints RSS, phys_footprint, threads, CPU, timings
  bench   <file.tkzrec> --compress [--full] [--repeats <n>] [--json <file>]
                            replay a recording and measure ghostty_terminal_compress
  bench   <file.tkzrec> [--points 1,10,50,200] [--json <file>]
                            snapshot size / restore time vs replay count

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


// MARK: - record

/// Streams frames into a `.tkzrec` while a real child runs on a pty.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let writer: RecordingWriter
    private let start: ContinuousClock.Instant
    private var frameCount = 0
    private var outputBytes = 0
    private var closed = false

    init(url: URL, header: RecordingHeader) throws {
        writer = RecordingWriter(header: header)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        start = ContinuousClock.now
        try handle.write(contentsOf: writer.headerLine())
    }

    private func elapsedNanos() -> UInt64 {
        let components = (ContinuousClock.now - start).components
        return UInt64(max(0, components.seconds)) &* 1_000_000_000
            &+ UInt64(max(0, components.attoseconds / 1_000_000_000))
    }

    func append(output data: Data) {
        lock.withLock {
            guard !closed else { return }
            frameCount += 1
            outputBytes += data.count
            try? handle.write(contentsOf: writer.encode(.output(elapsedNanos: elapsedNanos(), bytes: data)))
        }
    }

    func append(resizeTo cols: UInt16, rows: UInt16) {
        lock.withLock {
            guard !closed else { return }
            frameCount += 1
            try? handle.write(contentsOf: writer.encode(.resize(elapsedNanos: elapsedNanos(), cols: cols, rows: rows)))
        }
    }

    @discardableResult
    func finish() -> (frames: Int, bytes: Int) {
        lock.withLock {
            if !closed {
                closed = true
                try? handle.close()
            }
            return (frameCount, outputBytes)
        }
    }
}

/// One line of a `--script` file.
enum ScriptStep: Sendable {
    case wait(milliseconds: Int)
    case waitFor(text: String, milliseconds: Int)
    case send(Data)
    case resize(cols: UInt16, rows: UInt16)
    /// End the recording while the child is still live: SIGKILL, so nothing resets the modes.
    case stop
}

enum ScriptError: Error, CustomStringConvertible {
    case syntax(line: Int, message: String)
    var description: String {
        if case .syntax(let line, let message) = self { return "script line \(line): \(message)" }
        return "script error"
    }
}

/// Decodes `\n \r \t \e \0 \\ \" \xNN` inside a double-quoted script argument.
func decodeScriptString(_ raw: String) -> Data {
    var out = [UInt8]()
    var iterator = Array(raw.unicodeScalars).makeIterator()
    var pending: [Unicode.Scalar] = []
    while let scalar = pending.isEmpty ? iterator.next() : pending.removeFirst() {
        guard scalar == "\\" else {
            out.append(contentsOf: Array(String(scalar).utf8))
            continue
        }
        guard let escape = iterator.next() else { out.append(0x5C); break }
        switch escape {
        case "n": out.append(0x0A)
        case "r": out.append(0x0D)
        case "t": out.append(0x09)
        case "e": out.append(0x1B)
        case "0": out.append(0x00)
        case "\\": out.append(0x5C)
        case "\"": out.append(0x22)
        case "x":
            var hex = ""
            for _ in 0..<2 { if let digit = iterator.next() { hex.unicodeScalars.append(digit) } }
            out.append(UInt8(hex, radix: 16) ?? 0)
        default: out.append(contentsOf: Array(String(escape).utf8))
        }
    }
    return Data(out)
}

/// Splits a script line into its command and a single optional quoted argument plus the rest.
func parseScript(_ text: String) throws -> [ScriptStep] {
    var steps: [ScriptStep] = []
    for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let number = index + 1

        func quotedArgument() throws -> (String, String) {
            guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else {
                throw ScriptError.syntax(line: number, message: "expected a \"quoted\" argument")
            }
            let body = String(line[line.index(after: open)..<close])
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return (body, rest)
        }

        let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch fields.first {
        case "wait":
            guard fields.count == 2, let ms = Int(fields[1].trimmingCharacters(in: .whitespaces)) else {
                throw ScriptError.syntax(line: number, message: "wait needs a millisecond count")
            }
            steps.append(.wait(milliseconds: ms))
        case "waitfor":
            let (body, rest) = try quotedArgument()
            steps.append(.waitFor(text: body, milliseconds: Int(rest) ?? 30_000))
        case "send":
            let (body, _) = try quotedArgument()
            steps.append(.send(decodeScriptString(body)))
        case "resize":
            let parts = line.split(separator: " ").dropFirst().compactMap { UInt16($0) }
            guard parts.count == 2 else { throw ScriptError.syntax(line: number, message: "resize needs <cols> <rows>") }
            steps.append(.resize(cols: parts[0], rows: parts[1]))
        case "stop":
            steps.append(.stop)
        default:
            throw ScriptError.syntax(line: number, message: "unknown command \(fields.first ?? "")")
        }
    }
    return steps
}

/// The size of the real terminal we are running in, if any.
func currentTerminalSize() -> (cols: UInt16, rows: UInt16)? {
    var window = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0, window.ws_col > 0, window.ws_row > 0 else { return nil }
    return (window.ws_col, window.ws_row)
}

/// `execve` needs an absolute path; resolve a bare name through PATH like a shell would.
func resolveExecutable(_ command: String) -> String? {
    if command.contains("/") {
        return FileManager.default.isExecutableFile(atPath: command) ? command : nil
    }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for directory in path.split(separator: ":") {
        let candidate = "\(directory)/\(command)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// A tty in canonical mode truncates a line longer than `MAX_INPUT` (~1 KiB), so scripted input is
/// written in newline-terminated pieces rather than one blob.
func chunkForCanonicalTty(_ data: Data, limit: Int = 512) -> [Data] {
    var chunks: [Data] = []
    var current = Data()
    for byte in data {
        current.append(byte)
        if byte == 0x0A || byte == 0x0D || current.count >= limit {
            chunks.append(current)
            current = Data()
        }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
}

func runRecord(_ argv: [String]) throws {
    let arguments = Arguments(argv, valueFlags: ["cols", "rows", "out", "cwd", "script", "golden", "note", "timeout"])
    guard let outPath = arguments.value("out") else { fail("tkzmux-vtdump record: --out is required", code: 2) }
    let command = arguments.trailing
    guard let program = command.first else { fail("tkzmux-vtdump record: missing `-- <cmd>`", code: 2) }
    guard let executablePath = resolveExecutable(program) else {
        fail("tkzmux-vtdump record: \(program) not found on PATH", code: 2)
    }

    let terminal = currentTerminalSize()
    let cols = arguments.uint16("cols") ?? terminal?.cols ?? 120
    let rows = arguments.uint16("rows") ?? terminal?.rows ?? 40
    let quiet = arguments.has("quiet")
    let timeoutMilliseconds = Int(arguments.value("timeout") ?? "") ?? 120_000
    let cwd = arguments.value("cwd") ?? FileManager.default.currentDirectoryPath

    let steps: [ScriptStep]
    if let scriptPath = arguments.value("script") {
        steps = try parseScript(try String(contentsOf: URL(fileURLWithPath: scriptPath), encoding: .utf8))
    } else {
        steps = []
    }

    // The recording is only worth anything if the child sees the *real* session environment:
    // Claude Code gates kitty keyboard and synchronized output on TERM_PROGRAM=ghostty.
    // The tkzmux support directory is a throwaway one, so recording never touches real state and
    // the ZDOTDIR wrapper resolves to an empty directory (zsh simply skips the rc files).
    let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "tkzmux-vtdump-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    // A recording must be reproducible and must not carry the recording user's environment, so
    // only the handful of variables a child genuinely needs are inherited unless asked otherwise.
    let processEnvironment = ProcessInfo.processInfo.environment
    let baseEnvironment: [String: String] = arguments.has("inherit-env")
        ? processEnvironment
        : ["HOME", "PATH", "SHELL", "USER", "LOGNAME", "TMPDIR", "LANG"]
            .reduce(into: [String: String]()) { base, key in base[key] = processEnvironment[key] }
    let environment = TerminalEnvironment.make(
        sessionID: "vtdump-\(UUID().uuidString.prefix(8))",
        tkzmuxDir: sandbox,
        baseEnvironment: baseEnvironment
    )
    let spawn = PtySpawn(
        executablePath: executablePath,
        argv: command,
        environment: environment,
        cwd: cwd,
        size: TerminalSize(rows: rows, cols: cols)
    )

    let session = try TerminalSession(options: TerminalSessionOptions(cols: cols, rows: rows))
    let header = RecordingHeader(
        cols: cols, rows: rows,
        argv: command,
        // Only the variables that change VT behaviour: a recording must never carry a user's env.
        env: ["TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM", "LANG"]
            .reduce(into: [String: String]()) { summary, key in summary[key] = environment[key] },
        note: arguments.value("note")
    )
    let recorder = try Recorder(url: URL(fileURLWithPath: outPath), header: header)

    let finished = DispatchSemaphore(value: 0)
    let exitStatus = ExitBox()
    let ioQueue = DispatchQueue(label: "tkzmux.vtdump.record", qos: .userInteractive)

    let pty = try Pty(
        spawn: spawn,
        ioQueue: ioQueue,
        onData: { data in
            recorder.append(output: data)
            session.write(ptyBytes: data)
            if !quiet { FileHandle.standardOutput.write(data) }
        },
        onExit: { status in
            exitStatus.set(status)
            finished.signal()
        }
    )

    // Forward our own stdin when we are attached to a terminal and nothing is scripted.
    var stdinSource: (any DispatchSourceRead)?
    var savedTermios: termios?
    if steps.isEmpty && isatty(STDIN_FILENO) == 1 {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        savedTermios = raw
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: ioQueue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, 4096) }
            if count > 0 { try? pty.write(Data(buffer[0..<count])) }
        }
        source.resume()
        stdinSource = source
    }

    // Run the script off the main thread so the child keeps being pumped while we wait.
    if !steps.isEmpty {
        DispatchQueue.global(qos: .userInitiated).async {
            for step in steps {
                if pty.hasExited { break }
                switch step {
                case .wait(let milliseconds):
                    usleep(UInt32(milliseconds) * 1000)
                case .waitFor(let text, let milliseconds):
                    let deadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
                    while ContinuousClock.now < deadline, !pty.hasExited {
                        if (try? session.formatted())?.contains(text) == true { break }
                        usleep(100_000)
                    }
                case .send(let data):
                    for chunk in chunkForCanonicalTty(data) {
                        ioQueue.async { try? pty.write(chunk) }
                        usleep(20_000)
                    }
                case .resize(let newCols, let newRows):
                    ioQueue.async { try? pty.resize(TerminalSize(rows: newRows, cols: newCols)) }
                    try? session.resize(cols: newCols, rows: newRows)
                    recorder.append(resizeTo: newCols, rows: newRows)
                case .stop:
                    // SIGKILL, not SIGHUP: a hang-up makes the program tear down (alt screen off,
                    // mouse off, kitty flags cleared), which is exactly the state a "what does a
                    // running program leave behind" fixture must NOT end in.
                    pty.terminate(signal: SIGKILL)
                    return  // nothing can run against a dead pty
                }
            }
        }
    }

    let timedOut = finished.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .timedOut
    if timedOut {
        pty.terminate(signal: SIGHUP)
        _ = finished.wait(timeout: .now() + .seconds(5))
    }

    stdinSource?.cancel()
    if var saved = savedTermios { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }

    let totals = recorder.finish()
    let screen = (try? session.formatted()) ?? ""
    if let goldenPath = arguments.value("golden") {
        try (screen + "\n").write(to: URL(fileURLWithPath: goldenPath), atomically: true, encoding: .utf8)
    }

    let status = exitStatus.value
    var summary = "recorded \(totals.frames) frames / \(totals.bytes) output bytes to \(outPath)"
    summary += "  [\(cols)x\(rows)]"
    if timedOut { summary += "  (timed out after \(timeoutMilliseconds) ms, child SIGHUPed)" }
    if let status {
        if let code = status.exitCode { summary += "  child exit=\(code)" }
        if let signal = status.signal { summary += "  child signal=\(signal)" }
    }
    FileHandle.standardError.write(Data((summary + "\n").utf8))
    FileHandle.standardError.write(Data(
        ("modes: 1049=\(session.mode(1049)) 2004=\(session.mode(2004)) 1000=\(session.mode(1000)) "
         + "1006=\(session.mode(1006)) kitty=\(session.kittyKeyboardFlags) "
         + "mouse=\(session.mouseTrackingEnabled)\n").utf8
    ))
}

/// A `PtyExit` handed from the IO queue back to the main thread.
final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: PtyExit?
    func set(_ status: PtyExit) { lock.withLock { self.status = status } }
    var value: PtyExit? { lock.withLock { status } }
}

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())

do {
    switch argv.first {
    case "bench":
        // M1.10 / TKZ-16 — spawns real pty sessions and measures RSS, phys_footprint, threads,
        // CPU, compression and snapshot cost. See docs/perf.md.
        try BenchCommands.run(Array(argv.dropFirst()))

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

    case "state-churn":
        // M5.1 / TKZ-29 — the SIGKILL harness for state.json; see scripts/state-crash-test.sh.
        try StateChurnCommand.run(Array(argv.dropFirst()))

    case "replay":
        try runReplay(Array(argv.dropFirst()))

    case "record":
        try runRecord(Array(argv.dropFirst()))

    case "render":
        let arguments = Arguments(Array(argv.dropFirst()), valueFlags: ["out", "cols", "rows"])
        guard let input = arguments.positionals.first else {
            fail("tkzmux-vtdump render: missing <file.tkzrec>", code: 2)
        }
        guard let out = arguments.value("out") else { fail("tkzmux-vtdump render: --out is required", code: 2) }
        try RenderCommands.render(
            recording: URL(fileURLWithPath: input),
            png: URL(fileURLWithPath: out),
            cols: arguments.uint16("cols"),
            rows: arguments.uint16("rows")
        )

    case "atlas":
        let arguments = Arguments(Array(argv.dropFirst()), valueFlags: ["out", "point-size", "scale", "sample"])
        guard let out = arguments.value("out") else { fail("tkzmux-vtdump atlas: --out is required", code: 2) }
        try RenderCommands.atlas(
            pngPrefix: URL(fileURLWithPath: out),
            pointSize: Double(arguments.value("point-size") ?? "") ?? 12.5,
            scale: Double(arguments.value("scale") ?? "") ?? 2,
            sample: arguments.value("sample")
        )

    default:
        fail(usage, code: 2)
    }
} catch let error as GhosttyError {
    fail("tkzmux-vtdump: \(error.operation) failed (\(error.result))", code: 1)
} catch {
    fail("tkzmux-vtdump: \(error)", code: 1)
}
