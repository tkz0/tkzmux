// RealAgentProbe — the plumbing behind `RealAgentProbeTests` (WOR-306 S6): a throwaway HOME, the
// fake model API, tkzmux's own pieces wired the way the app wires them, and a pane driven through
// a real `Pty` and libghostty-vt. Nothing here runs unless `TKZMUX_REAL_AGENTS=1`.
//
// What a probe run touches: only the directory it makes under the temp directory. HOME,
// `XDG_DATA_HOME`, `XDG_RUNTIME_DIR`, `CLAUDE_CONFIG_DIR` and `CODEX_HOME` all point inside it, and
// the agents talk to `fake-model-api.py` on loopback with a made-up key. On Linux the probe refuses
// to run while a network interface other than `lo` is visible, so it has to be started inside a
// fresh network namespace (`bwrap --unshare-net`, see docs/linux/agents.md); nothing an agent does
// at startup can then reach the network either.
import Foundation
import Synchronization
import TkzCore
import TkzTerminalCore

@testable import AgentBridge

enum RealAgentProbe {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    static var enabled: Bool { environment["TKZMUX_REAL_AGENTS"] == "1" }

    /// `TKZMUX_REAL_AGENTS_CAPTURE=<dir>`: also keep every payload the agents handed the hook, and
    /// write the normalized fixtures `Fixtures/linux/` is made of (see its README).
    static var captureRoot: URL? {
        environment["TKZMUX_REAL_AGENTS_CAPTURE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var fixtures: URL { packageRoot.appending(path: "Tests/AgentBridgeTests/Fixtures/linux") }

    /// The release hook: `TKZMUX_HOOK_BIN`, else the static musl build on Linux
    /// (docs/linux/hook.md) and the release build on macOS.
    static func hookBinary() throws -> URL {
        if let override = environment["TKZMUX_HOOK_BIN"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        #if os(Linux)
        let relative = ".build/x86_64-swift-linux-musl/release/tkzmux-hook"
        #else
        let relative = ".build/release/tkzmux-hook"
        #endif
        let url = packageRoot.appending(path: relative)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ProbeError.missing("release tkzmux-hook at \(url.path); build it or set TKZMUX_HOOK_BIN")
        }
        return url
    }

    /// The directory holding `name` on the test's own PATH, resolved through symlinks, so the
    /// pane's PATH can name it without inheriting anything else (mise shims included).
    static func agentDirectory(_ name: String) -> String? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return (TraceNormalizer.realPath(candidate) as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Linux: true when `lo` is the only interface this process can see, i.e. it runs in a network
    /// namespace of its own. `TKZMUX_REAL_AGENTS_ALLOW_NETWORK=1` skips the check. macOS has no
    /// equivalent; there the agents' own opt-outs are all there is (docs/linux/agents.md).
    static func networkIsIsolated() -> Bool {
        if environment["TKZMUX_REAL_AGENTS_ALLOW_NETWORK"] == "1" { return true }
        #if os(Linux)
        guard let table = try? String(contentsOfFile: "/proc/net/dev", encoding: .utf8) else { return false }
        let interfaces = table.split(separator: "\n").dropFirst(2)
            .compactMap { $0.split(separator: ":").first?.trimmingCharacters(in: .whitespaces) }
        return interfaces == ["lo"]
        #else
        return true
        #endif
    }

    static func version(of binary: String) -> String {
        guard let result = try? ShimTestSupport.run(
            URL(fileURLWithPath: binary), ["--version"], environment: ["PATH": "/usr/bin:/bin"])
        else { return "unknown" }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case missing(String)
    case timeout(String)

    var description: String {
        switch self {
        case .missing(let what): "missing \(what)"
        case .timeout(let what): "timed out waiting for \(what)"
        }
    }
}

/// Polls `condition` every 50 ms until it holds or `seconds` pass.
func probeWait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

// MARK: - What arrived

/// Everything tkzmux's own pieces reported during a run, in arrival order.
final class ProbeRecorder: Sendable {
    enum Item: Sendable {
        case frame(HookFrame)
        case observation(ObservationEvent)
        case statusline(StatuslineEvent)
    }

    private let items = Mutex<[Item]>([])

    func append(_ item: Item) { items.withLock { $0.append(item) } }
    var all: [Item] { items.withLock { $0 } }

    var frames: [HookFrame] {
        all.compactMap { if case .frame(let frame) = $0 { frame } else { nil } }
    }

    var launches: [LaunchAnnouncement] {
        frames.compactMap { if case .launch(let launch) = $0 { launch } else { nil } }
    }

    var hookPayloads: [(payload: HookPayload, sessionID: SessionID?, ppid: pid_t)] {
        frames.compactMap {
            if case .hook(let payload, let sid, let ppid, _) = $0 { (payload, sid, ppid) } else { nil }
        }
    }

    func count(of event: String) -> Int {
        hookPayloads.filter { $0.payload.eventName == event }.count
    }

    var observations: [ObservationEvent] {
        all.compactMap { if case .observation(let event) = $0 { event } else { nil } }
    }

    var statusline: [StatuslineEvent] {
        all.compactMap { if case .statusline(let event) = $0 { event } else { nil } }
    }
}

// MARK: - The sandbox

/// One probe run's throwaway world, laid out like a real user's: the project and every dot
/// directory under HOME, user data in `$XDG_DATA_HOME/tkzmux`, the socket under
/// `$XDG_RUNTIME_DIR/tkzmux`.
struct ProbeWorld {
    var root: URL
    var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }
    var project: URL { home.appending(path: "project", directoryHint: .isDirectory) }
    var dataHome: URL { home.appending(path: ".local/share", directoryHint: .isDirectory) }
    var support: URL { dataHome.appending(path: "tkzmux", directoryHint: .isDirectory) }
    var runtime: URL { root.appending(path: "run", directoryHint: .isDirectory) }
    var capture: URL?

    /// A short root under `/tmp`: on macOS the hook socket sits in the support directory, three
    /// levels down, and `sun_path` holds 104 bytes there.
    init(label: String, capture: URL?) throws {
        var template = Array("/tmp/tkzp-\(label.prefix(12)).XXXXXX".utf8CString)
        guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) != nil }) else {
            throw ProbeError.missing("a temporary directory")
        }
        root = URL(fileURLWithPath: template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, isDirectory: true)
        self.capture = capture
        for directory in [home, project, dataHome, runtime] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtime.path)
        if let capture {
            try? FileManager.default.removeItem(at: capture)
            try FileManager.default.createDirectory(
                at: capture.appending(path: "raw"), withIntermediateDirectories: true)
        }
    }

    /// The placeholders a trace uses for this world.
    var normalizer: TraceNormalizer {
        TraceNormalizer(paths: [
            (project.path, "<project>"), (support.path, "<support>"), (home.path, "<home>"),
            (root.path, "<root>"),
        ])
    }

    /// The fixture spelling of this world: HOME becomes `/home/tester`, the way the macOS fixtures
    /// use `/Users/tester`, the runtime directory `/run/user/1000`, and the machine id in a Linux
    /// pid domain is zeroed.
    func fixtureText(_ text: String) -> String {
        var result = text
        for spelling in Set([runtime.path, TraceNormalizer.realPath(runtime.path)]) {
            result = result.replacingOccurrences(of: spelling, with: "/run/user/1000")
        }
        for spelling in Set([home.path, TraceNormalizer.realPath(home.path)]).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: spelling, with: "/home/tester")
            result = result.replacingOccurrences(
                of: TraceNormalizer.claudeSlug(spelling), with: TraceNormalizer.claudeSlug("/home/tester"))
        }
        if let regex = try? NSRegularExpression(pattern: #"linux:[0-9a-f]{32}:pid"#) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: "linux:00000000000000000000000000000000:pid")
        }
        return result
    }

    /// The shims, the wrappers and the release hook in `<support>/bin`, by the real installer. In
    /// capture mode the hook is moved to `tkzmux-hook.real` and a wrapper that keeps a copy of each
    /// payload takes its place; the real hook still runs from the same directory, so it derives
    /// the same support directory from its argv0.
    func installShims(hook: URL) throws {
        let installer = ShimInstaller(
            directory: support, hookBinary: hook, resources: try ShimResources.bundled())
        _ = try installer.ensureInstalled()
        guard let capture else { return }
        let bin = support.appending(path: "bin")
        try FileManager.default.moveItem(
            at: bin.appending(path: "tkzmux-hook"), to: bin.appending(path: "tkzmux-hook.real"))
        let raw = capture.appending(path: "raw").path
        try ShimTestSupport.writeExecutable(
            """
            #!/bin/sh
            # Probe capture: keep what the agent hands tkzmux-hook, then run the real one.
            real="$0.real"
            stamp=$(date +%s%N 2>/dev/null)
            case "$stamp" in *N|"") stamp=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1e9') ;; esac
            case "$1" in
            launch) printf '%s\\n' "$@" > "\(raw)/$stamp-launch.argv"; exec "$real" "$@" ;;
            notify-argv) printf '%s' "$2" > "\(raw)/$stamp-notify-argv.json"; exec "$real" "$@" ;;
            settings-merge|statusline-settings) exec "$real" "$@" ;;
            *) tee "\(raw)/$stamp-$1.json" | "$real" "$@" ;;
            esac

            """, to: bin.appending(path: "tkzmux-hook"))
    }

    /// The hook server at the socket a pane spawned from `environment` is told about.
    func startHookServer(environment: [String: String], recorder: ProbeRecorder) throws -> HookServer {
        let directory = HookSocket.directory(support: support, environment: environment)
        let server = HookServer(socketPath: HookSocket.url(in: directory, pid: getpid())) { frame in
            recorder.append(.frame(frame))
        }
        try server.start()
        return server
    }

    /// What a GUI session hands tkzmux, minus anything that would let the agents find the real
    /// user: a fixed PATH (the agent's own directory, then the system's) and this world's HOME and
    /// XDG directories. `LANG` is left out so the pane gets the fallback.
    func baseEnvironment(agentDirectory: String, extra: [String: String]) -> [String: String] {
        var environment: [String: String] = [
            "HOME": home.path,
            "USER": ProcessInfo.processInfo.userName,
            "PATH": "\(agentDirectory):/usr/local/bin:/usr/bin:/bin",
            "XDG_DATA_HOME": dataHome.path,
            "XDG_RUNTIME_DIR": runtime.path,
            "SHELL": "/bin/bash",
        ]
        for (key, value) in extra { environment[key] = value }
        return environment
    }
}

// MARK: - The fake model API

/// `Fixtures/linux/fake-model-api.py` on a loopback port.
final class FakeModelAPI {
    let process = Process()
    let port: Int
    let log: URL

    init(directory: URL, delay: Double = 1.5) throws {
        let portFile = directory.appending(path: "fake-api.port")
        log = directory.appending(path: "fake-api.log")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", RealAgentProbe.fixtures.appending(path: "fake-model-api.py").path,
            portFile.path, log.path, "--delay", String(delay),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        var found: Int?
        while found == nil, Date() < deadline {
            found = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap { Int($0) }
            if found == nil { usleep(50_000) }
        }
        guard let found else {
            process.terminate()
            throw ProbeError.timeout("the fake model API to listen")
        }
        port = found
    }

    var requests: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// SIGKILL, not `terminate()`: corelibs Foundation starts the child with the test process's
    /// blocked-signal mask, SIGTERM included, so a SIGTERM would stay pending forever.
    func stop() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

// MARK: - The pane

/// A pane as `TerminalViewHost` runs one: the login shell on a `Pty`, its output into
/// libghostty-vt, which answers the agents' terminal queries back into the pty.
final class ProbePane: Sendable {
    /// A value set from a callback, read from the test.
    private final class Box<Value: Sendable>: Sendable {
        let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
    }

    let pty: Pty
    let terminal: TerminalSession
    private let exitStatus: Box<PtyExit?>

    init(spawn: PtySpawn, label: String) throws {
        let terminal = try TerminalSession(
            options: TerminalSessionOptions(cols: spawn.size.cols, rows: spawn.size.rows))
        let ptyBox = Box<Pty?>(nil)
        let exitStatus = Box<PtyExit?>(nil)
        terminal.setOnWritePty { data in
            guard let pty = ptyBox.value.withLock({ $0 }) else { return }
            pty.ioQueue.async { try? pty.write(data) }
        }
        let pty = try Pty(
            spawn: spawn, ioQueue: DispatchQueue(label: "tkzmux.probe.\(label)"),
            onData: { data in terminal.write(ptyBytes: data) },
            onExit: { status in exitStatus.value.withLock { $0 = status } })
        ptyBox.value.withLock { $0 = pty }
        self.pty = pty
        self.terminal = terminal
        self.exitStatus = exitStatus
    }

    var exited: Bool { exitStatus.value.withLock { $0 != nil } }

    /// The screen as plain text.
    var screen: String { (try? terminal.formatted()) ?? "" }

    /// Typed, not pasted: the text and the Enter go separately, with a pause, because a TUI
    /// reads a burst ending in CR as a paste and keeps the newline.
    func type(_ text: String) async {
        let pty = pty
        pty.ioQueue.async { try? pty.write(Data(text.utf8)) }
        try? await Task.sleep(for: .milliseconds(400))
    }

    func enter() async { await type("\r") }

    func close() async {
        _ = pty.terminate(signal: SIGHUP)
        if await probeWait(3, { exited }) { return }
        _ = pty.terminate(signal: SIGKILL)
        _ = await probeWait(3, { exited })
    }
}
