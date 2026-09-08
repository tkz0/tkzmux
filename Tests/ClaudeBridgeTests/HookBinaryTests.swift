// Exercises the built `tkzmux-hook` binary end-to-end via `Process`. M3.2 (TKZ-22).
//
// Timing acceptance (c) is measured against the debug build here; the release binary is measured
// separately (see the ticket's Finish step) since `swift test` always runs against the debug
// product build directory.
import Darwin
import Foundation
import Synchronization
import Testing
import TkzCore

@testable import ClaudeBridge

private func makeSocketDir() throws -> URL {
    var template = Array("/tmp/tkzhs.XXXXXX".utf8CString)
    let result = template.withUnsafeMutableBufferPointer { buf -> UnsafeMutablePointer<CChar>? in
        mkdtemp(buf.baseAddress)
    }
    guard result != nil else { throw HookBinaryTestError.mkdtempFailed }
    let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private enum HookBinaryTestError: Error { case mkdtempFailed, binaryNotFound }

/// Locates the built `tkzmux-hook` next to the test bundle's products directory. `TKZMUX_HOOK_BIN`
/// overrides this (used for the release-binary timing run, since `swift test` always builds the
/// debug product).
private func hookBinaryURL() throws -> URL {
    if let override = ProcessInfo.processInfo.environment["TKZMUX_HOOK_BIN"], !override.isEmpty {
        let url = URL(fileURLWithPath: override)
        guard FileManager.default.fileExists(atPath: url.path) else { throw HookBinaryTestError.binaryNotFound }
        return url
    }

    // The documented lookup — Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") } —
    // finds nothing under `swift test`'s out-of-process `swiftpm-testing-helper` runner (verified:
    // Bundle.allBundles there lists resource bundles but not the .xctest bundle itself). Try it
    // first for when the tests run inside Xcode, then fall back to scanning our own launch
    // arguments, which the helper always includes as `--test-bundle-path <bundle>/Contents/MacOS/…`.
    if let xctestBundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
        let candidate = xctestBundle.bundleURL.deletingLastPathComponent().appendingPathComponent("tkzmux-hook")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    for arg in ProcessInfo.processInfo.arguments {
        guard let range = arg.range(of: ".xctest") else { continue }
        let bundlePath = String(arg[arg.startIndex..<range.upperBound])
        let productsDir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
        let candidate = productsDir.appendingPathComponent("tkzmux-hook")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    throw HookBinaryTestError.binaryNotFound
}

/// A base environment with every `TKZMUX_*` key stripped, so ambient state from the developer's
/// own shell (this is a Claude-Code-managing app; `TKZMUX_SOCKET`/`TKZMUX_SESSION_ID` may already
/// be exported) never contaminates a test that asserts on their absence or a specific value.
private func cleanEnvironment(_ overrides: [String: String] = [:]) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for key in env.keys where key.hasPrefix("TKZMUX_") {
        env.removeValue(forKey: key)
    }
    for (k, v) in overrides { env[k] = v }
    return env
}

/// Runs the hook binary with `stdinBytes` on stdin, returning exit code, stdout and stderr.
/// Writes stdin from a background queue so payloads bigger than the pipe buffer (64 KiB) — the 200
/// KiB and 2 MiB fixtures — don't deadlock the test writing synchronously into a child that hasn't
/// started reading yet.
@discardableResult
private func runHook(
    _ arguments: [String],
    stdin stdinBytes: [UInt8] = [],
    environment: [String: String],
    binary: URL
) throws -> (exitCode: Int32, stdout: Data, stderr: Data, wallTime: TimeInterval) {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.environment = environment

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let start = Date()
    try process.run()

    let writeQueue = DispatchQueue(label: "hook-binary-test-stdin")
    writeQueue.async {
        if !stdinBytes.isEmpty {
            stdinPipe.fileHandleForWriting.write(Data(stdinBytes))
        }
        try? stdinPipe.fileHandleForWriting.close()
    }

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let wallTime = Date().timeIntervalSince(start)

    return (process.terminationStatus, stdoutData, stderrData, wallTime)
}

@Suite struct HookBinaryTests {
    @Test func socketUnsetExitsZeroWithEmptyStdout() throws {
        let binary = try hookBinaryURL()
        let result = try runHook(
            ["Stop"],
            stdin: Array(#"{"session_id":"x"}"#.utf8),
            environment: cleanEnvironment(),
            binary: binary
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.wallTime < 1.0)
    }

    @Test func socketPointingNowhereExitsZeroFast() throws {
        let binary = try hookBinaryURL()
        let result = try runHook(
            ["Stop"],
            stdin: Array(#"{"session_id":"x"}"#.utf8),
            environment: cleanEnvironment(["TKZMUX_SOCKET": "/tmp/tkzhs-does-not-exist/hook.sock"]),
            binary: binary
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.wallTime < 0.25)
    }

    @Test func stopFixtureArrivesWithCorrectFields() async throws {
        let binary = try hookBinaryURL()
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")

        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hooks/stop.json")
        let fixtureBytes = try Array(Data(contentsOf: fixtureURL))

        // Untimed warm-up: a cold debug binary pays dyld/libswiftCore load once; don't let that
        // show up in the measured run.
        _ = try runHook(["Stop"], stdin: fixtureBytes, environment: cleanEnvironment(["TKZMUX_SOCKET": socketPath.path]), binary: binary)

        let result = try runHook(
            ["Stop"],
            stdin: fixtureBytes,
            environment: cleanEnvironment(["TKZMUX_SOCKET": socketPath.path, "TKZMUX_SESSION_ID": "22222222-3333-4444-5555-666666666666"]),
            binary: binary
        )
        #expect(result.exitCode == 0)
        #expect(result.wallTime <= 0.050, "expected ≤ 50 ms in a debug build, measured \(result.wallTime)s")

        let frames = await collector.waitFor(count: 2) // warm-up + measured
        #expect(frames.count == 2)
        guard case .hook(let event, let ppid, let fullMessage, let cwd) = frames.last! else {
            Issue.record("expected a .hook frame")
            return
        }
        #expect(event.kind == .stop)
        #expect(event.sessionID == SessionID("22222222-3333-4444-5555-666666666666"))
        #expect(event.claudeSessionId == "11111111-2222-3333-4444-555555555555")
        #expect(event.lastAssistantMessage == "All done, the build is green.")
        #expect(fullMessage == "All done, the build is green.")
        #expect(cwd == "/Users/thomas/dev/tkzmux")
        #expect(ppid > 0)
    }

    @Test func longMessageArrivesIntactPrefixTruncated() async throws {
        let binary = try hookBinaryURL()
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")

        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        let longMessage = String(repeating: "a", count: 200 * 1024)
        let payload = "{\"session_id\":\"s\",\"last_assistant_message\":\"\(longMessage)\"}"

        let result = try runHook(
            ["Stop"],
            stdin: Array(payload.utf8),
            environment: cleanEnvironment(["TKZMUX_SOCKET": socketPath.path]),
            binary: binary
        )
        #expect(result.exitCode == 0)

        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
        guard case .hook(let event, _, let fullMessage, _) = frames[0] else {
            Issue.record("expected a .hook frame")
            return
        }
        #expect(fullMessage?.utf8.count == 200 * 1024)
        #expect(event.lastAssistantMessage?.utf8.count == 4096)
        #expect(fullMessage?.hasPrefix(event.lastAssistantMessage ?? "") == true)
    }

    /// Exercises the byte-level string-truncation scanner directly: a 300 KiB message pushes the
    /// whole frame over the 240 KiB limit (unlike the 200 KiB fixture above, which stays under it),
    /// so this is the only test that actually runs `truncateLongStrings`.
    @Test func overSizeFrameTriggersStringTruncation() async throws {
        let binary = try hookBinaryURL()
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")

        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        let longMessage = String(repeating: "c", count: 300 * 1024)
        let payload = "{\"session_id\":\"s\",\"last_assistant_message\":\"\(longMessage)\"}"

        let result = try runHook(
            ["Stop"],
            stdin: Array(payload.utf8),
            environment: cleanEnvironment(["TKZMUX_SOCKET": socketPath.path]),
            binary: binary
        )
        #expect(result.exitCode == 0)

        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
        guard case .hook(_, _, let fullMessage, _) = frames[0] else {
            Issue.record("expected a .hook frame")
            return
        }
        #expect(fullMessage?.hasSuffix("…[truncated]") == true)
        let byteCount = fullMessage?.utf8.count ?? 0
        #expect(byteCount > 64 * 1024 && byteCount < 65 * 1024, "expected the string cut near the 64 KiB limit, got \(byteCount)")
    }

    /// The whole payload is well beyond the 1 MiB stdin cap, so the binary must skip the string
    /// scanner (it would see a JSON document chopped mid-value) and send `{"truncated":true}`.
    @Test func twoMegabytePayloadSendsTruncatedMarker() async throws {
        let binary = try hookBinaryURL()
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")

        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        let huge = String(repeating: "b", count: 2 * 1024 * 1024)
        let payload = "{\"session_id\":\"s\",\"last_assistant_message\":\"\(huge)\"}"

        let result = try runHook(
            ["Stop"],
            stdin: Array(payload.utf8),
            environment: cleanEnvironment(["TKZMUX_SOCKET": socketPath.path]),
            binary: binary
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)

        let frames = await collector.waitFor(count: 1, timeout: 1)
        #expect(server.isRunning, "the server must never crash on an oversized payload")
        // Either the {"truncated":true} marker arrived, or nothing did (still acceptable per the
        // wire protocol) — but if something arrived, it must be exactly the marker, never a
        // "successful" frame carrying 2 MiB of message.
        if let frame = frames.first {
            guard case .hook(_, _, let fullMessage, _) = frame else {
                Issue.record("expected a .hook frame")
                return
            }
            #expect(fullMessage == nil, "the marker payload has no last_assistant_message")
        }
    }

    @Test func launchFrameRoundTripsArgvWithSpacesAndQuotes() async throws {
        let binary = try hookBinaryURL()
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")

        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        let sessionID = SessionID.generate()
        let cwd = "/Users/thomas/dev/tkzmux worktrees/agent one"
        let configDir = "/Users/thomas/.claude-alt"
        let result = try runHook(
            ["launch", "--pid", "4242", "--cwd", cwd, "--", "claude", "--resume", "abc\"def", "arg with space"],
            environment: cleanEnvironment([
                "TKZMUX_SOCKET": socketPath.path,
                "TKZMUX_SESSION_ID": sessionID.rawValue,
                "CLAUDE_CONFIG_DIR": configDir,
            ]),
            binary: binary
        )
        #expect(result.exitCode == 0)

        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
        guard case .launch(let announcement) = frames[0] else {
            Issue.record("expected a .launch frame")
            return
        }
        #expect(announcement.sessionID == sessionID)
        #expect(announcement.pid == 4242)
        #expect(announcement.cwd == cwd)
        #expect(announcement.configDir == configDir)
        #expect(announcement.argv == ["claude", "--resume", "abc\"def", "arg with space"])
    }

    /// Contract #2: `config_dir` falls back to `$HOME/.claude` when `CLAUDE_CONFIG_DIR` is unset —
    /// this is the string design.md derives the account key from (`~/.claude` → `claude`,
    /// `~/.claude-alt` → `claude-alt`), so getting the fallback right matters.
    @Test func launchConfigDirFallsBackToHomeDotClaude() async throws {
        let binary = try hookBinaryURL()
        let dir = try makeSocketDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("hook.sock")

        let collector = FrameCollector()
        let server = HookServer(socketPath: socketPath) { collector.append($0) }
        try server.start()
        defer { server.stop() }

        let fakeHome = dir.appendingPathComponent("home").path
        var env = cleanEnvironment(["TKZMUX_SOCKET": socketPath.path, "HOME": fakeHome])
        env.removeValue(forKey: "CLAUDE_CONFIG_DIR")

        let result = try runHook(
            ["launch", "--pid", "1", "--cwd", "/tmp", "--", "claude"],
            environment: env,
            binary: binary
        )
        #expect(result.exitCode == 0)

        let frames = await collector.waitFor(count: 1)
        #expect(frames.count == 1)
        guard case .launch(let announcement) = frames[0] else {
            Issue.record("expected a .launch frame")
            return
        }
        #expect(announcement.configDir == fakeHome + "/.claude")
    }

    @Test func settingsMergeWithUserFixturePreservesUnrelatedKeys() throws {
        let binary = try hookBinaryURL()
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hooks/user_settings.json")

        let result = try runHook(
            ["settings-merge", fixtureURL.path],
            environment: cleanEnvironment(["TKZMUX_BIN": "/opt/tkzmux bin"]),
            binary: binary
        )
        #expect(result.exitCode == 0)

        let parsed = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        #expect(parsed != nil)
        guard let parsed else { return }

        let fixtureObject = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        for key in fixtureObject?.keys ?? [:].keys where key != "hooks" {
            let expected = fixtureObject?[key] as? NSObject
            let actual = parsed[key] as? NSObject
            #expect(actual == expected, "unrelated key \(key) must equal the input unchanged")
        }

        #expect((parsed["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(git status)", "Bash(git diff)"])
        #expect(parsed["model"] as? String == "claude-opus-5")
        #expect((parsed["statusLine"] as? [String: Any])?["command"] as? String == "~/.claude/statusline.sh")

        let hooks = parsed["hooks"] as? [String: Any]
        #expect(hooks != nil)
        let preToolUse = hooks?["PreToolUse"] as? [[String: Any]]
        #expect(preToolUse?.count == 1)
        let preToolHooks = (preToolUse?.first?["hooks"] as? [[String: Any]])?.first
        #expect(preToolHooks?["command"] as? String == "~/.claude/hooks/block-rm.sh")

        for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification"] {
            let groups = hooks?[event] as? [[String: Any]]
            #expect(groups?.count == 1, "expected exactly one injected group for \(event)")
            let commandHook = (groups?.first?["hooks"] as? [[String: Any]])?.first
            let command = commandHook?["command"] as? String
            #expect(command?.contains("/opt/tkzmux bin/tkzmux-hook") == true)
            #expect(command?.hasSuffix(event) == true)
        }
        let notificationGroup = (hooks?["Notification"] as? [[String: Any]])?.first
        #expect(notificationGroup?["matcher"] as? String != nil)
        let sessionEndHook = ((hooks?["SessionEnd"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        #expect(sessionEndHook?["timeout"] as? Int == 1)
    }

    @Test func settingsMergeWithNoArgYieldsExactlyFiveEvents() throws {
        let binary = try hookBinaryURL()
        let result = try runHook(
            ["settings-merge"],
            environment: cleanEnvironment(["TKZMUX_BIN": "/opt/tkzmux/bin"]),
            binary: binary
        )
        #expect(result.exitCode == 0)
        let parsed = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        #expect(hooks?.count == 5)
        #expect(Set(hooks?.keys ?? [:].keys) == ["SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Notification"])
    }

    @Test func settingsMergeWithInvalidJSONFileExitsOneEmptyStdout() throws {
        let binary = try hookBinaryURL()
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hooks/invalid_settings.json")

        let result = try runHook(
            ["settings-merge", fixtureURL.path],
            environment: cleanEnvironment(["TKZMUX_BIN": "/opt/tkzmux/bin"]),
            binary: binary
        )
        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
    }

    @Test func settingsMergeWithJSONStringArgument() throws {
        let binary = try hookBinaryURL()
        let result = try runHook(
            ["settings-merge", #"{"foo":"bar"}"#],
            environment: cleanEnvironment(["TKZMUX_BIN": "/opt/tkzmux/bin"]),
            binary: binary
        )
        #expect(result.exitCode == 0)
        let parsed = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        #expect(parsed?["foo"] as? String == "bar")
        #expect((parsed?["hooks"] as? [String: Any])?.count == 5)
    }

    /// Exercises the hand-written JSON parser's full escape handling (`\uXXXX`, a surrogate pair,
    /// the common single-char escapes) and its "numbers kept as their original text" rule —
    /// `JSONSerialization` round-trips `1.50` and `1.5` to the identical `NSNumber`, so only a
    /// substring check on the raw stdout text actually proves the source text was preserved.
    @Test func settingsMergeParsesEscapesAndPreservesNumberText() throws {
        let binary = try hookBinaryURL()
        // é = é, 😀 = 😀 as a surrogate pair — written as literal escape sequences
        // (this is a raw string: #"…"# does not itself interpret backslashes), so the hand-written
        // JSON parser, not Swift's string literal grammar, is the one that has to decode them.
        let arg = #"{"s":"caf\u00e9 \ud83d\ude00 a\tb","n":1.50,"e":1e3,"neg":-0.5}"#
        let result = try runHook(
            ["settings-merge", arg],
            environment: cleanEnvironment(["TKZMUX_BIN": "/opt/tkzmux/bin"]),
            binary: binary
        )
        #expect(result.exitCode == 0)

        let stdoutText = String(decoding: result.stdout, as: UTF8.self)
        #expect(stdoutText.contains("1.50"), "numbers must keep their original source text, not be reformatted to 1.5")
        #expect(stdoutText.contains("1e3"))
        #expect(stdoutText.contains("-0.5"))

        let parsed = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        #expect(parsed?["s"] as? String == "café \u{1F600} a\tb")
    }
}

/// Shared with HookServerTests conceptually, but each test file needs its own copy since Swift
/// Testing suites in different files don't share fileprivate helpers.
private final class FrameCollector: Sendable {
    private let storage = Mutex<[HookFrame]>([])

    func append(_ frame: HookFrame) {
        storage.withLock { $0.append(frame) }
    }

    var frames: [HookFrame] {
        storage.withLock { $0 }
    }

    func waitFor(count: Int, timeout: TimeInterval = 2) async -> [HookFrame] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = frames
            if current.count >= count { return current }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return frames
    }
}
