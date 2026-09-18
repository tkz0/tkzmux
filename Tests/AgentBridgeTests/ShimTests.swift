// ShimTests — exercises the installed `claude.sh` shim end to end via `Process`, against a fake
// real `claude` and a fake `tkzmux-hook` on a fully controlled PATH. See the M3.3 ticket for the
// exact behavioural contract.
import Foundation
import Testing

@testable import AgentBridge

/// Test plumbing shared by ShimTests / ZshWrapperTests / ShimInstallerTests: temp directories and
// a thin `Process` runner. Namespaced (rather than a separate file with top-level declarations)
// because `Tests/AgentBridgeTests` is written concurrently by another agent's test file, and
// bare top-level names like `run` or `ProcessResult` are exactly what a second author would also
// pick. No test here touches the real HOME, ~/.claude, or the real tkzmux application-support
// directory.
enum ShimTestSupport {
    struct ProcessResult {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func makeTempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkzmux-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func writeExecutable(_ contents: String, to url: URL) throws -> URL {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Runs `executable` with `arguments`, replacing the environment entirely with `environment`
    /// (never inheriting the test runner's own env — that's how a stray real `TKZMUX_*` would
    /// leak in and silently change what's under test).
    static func run(
        _ executable: URL, _ arguments: [String] = [], environment: [String: String],
        stdin: String? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try inPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "")
    }

    /// Decodes the fake `tkzmux-hook`'s NUL-separated, newline-delimited argv log (see
    /// `fakeHookScript` below) into one `[String]` per invocation.
    static func decodeArgvLog(_ url: URL) -> [[String]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        return lines.map { line in
            // Each field is NUL-terminated (`printf '%s\0'`), so splitting on 0x00 *without*
            // dropping empty subsequences preserves a genuinely empty argument -- and leaves one
            // spurious trailing empty element from the final field's own terminator, dropped below.
            var fields = line.split(separator: 0x00, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            if fields.last == "" { fields.removeLast() }
            return fields
        }
    }
}

private typealias ProcessResult = ShimTestSupport.ProcessResult
private func makeTempDirectory(_ label: String) throws -> URL {
    try ShimTestSupport.makeTempDirectory(label)
}
@discardableResult
private func writeExecutable(_ contents: String, to url: URL) throws -> URL {
    try ShimTestSupport.writeExecutable(contents, to: url)
}
private func run(
    _ executable: URL, _ arguments: [String] = [], environment: [String: String],
    stdin: String? = nil
) throws -> ProcessResult {
    try ShimTestSupport.run(executable, arguments, environment: environment, stdin: stdin)
}
private func decodeArgvLog(_ url: URL) -> [[String]] { ShimTestSupport.decodeArgvLog(url) }

private let fakeClaudeScript = """
#!/bin/bash
{
    printf '%s\\0' "$0" "$@"
    printf '\\n'
} >> "$FAKE_CLAUDE_LOG"
# Records the env the shim handed the real agent -- this is how ShimTests proves TKZMUX_AGENT was
# exported (inherited here), not just set in the shim's own shell.
printf 'TKZMUX_AGENT=%s\\n' "${TKZMUX_AGENT:-}" >> "$FAKE_CLAUDE_ENV_LOG"
"""

private let fakeHookScript = """
#!/bin/bash
{
    printf '%s\\0' "$0" "$@"
    printf '\\n'
} >> "$FAKE_HOOK_LOG"

if [[ "${1:-}" == "settings-merge" ]]; then
    if [[ "${FAKE_MERGE_FAIL:-}" == "1" ]]; then
        exit 1
    fi
    echo '{"merged":true}'
    exit 0
fi
exit 0
"""

private struct ShimFixture {
    var root: URL
    var tkzmuxBin: URL
    var realClaudeDir: URL
    var fakeClaudeLog: URL
    var fakeClaudeEnvLog: URL
    var fakeHookLog: URL
    var shimURL: URL

    var basePath: String { "\(tkzmuxBin.path):\(realClaudeDir.path)" }

    func baseEnvironment(sessionID: String? = "sid-1", socket: String? = "sock") -> [String: String] {
        var env: [String: String] = [
            "PATH": basePath,
            "TKZMUX_BIN": tkzmuxBin.path,
            "FAKE_CLAUDE_LOG": fakeClaudeLog.path,
            "FAKE_CLAUDE_ENV_LOG": fakeClaudeEnvLog.path,
            "FAKE_HOOK_LOG": fakeHookLog.path,
            "HOME": root.path,
        ]
        if let sessionID { env["TKZMUX_SESSION_ID"] = sessionID }
        if let socket { env["TKZMUX_SOCKET"] = socket }
        return env
    }
}

private func makeShimFixture() throws -> ShimFixture {
    let root = try makeTempDirectory("shim")
    let tkzmuxBin = root.appendingPathComponent("bin", isDirectory: true)
    let realClaudeDir = root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: tkzmuxBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: realClaudeDir, withIntermediateDirectories: true)

    let fakeClaudeLog = root.appendingPathComponent("claude.log")
    let fakeClaudeEnvLog = root.appendingPathComponent("claude-env.log")
    let fakeHookLog = root.appendingPathComponent("hook.log")

    try writeExecutable(fakeClaudeScript, to: realClaudeDir.appendingPathComponent("claude"))
    try writeExecutable(fakeHookScript, to: tkzmuxBin.appendingPathComponent("tkzmux-hook"))

    let resources = try ShimResources.bundled()
    let shimURL = tkzmuxBin.appendingPathComponent("claude")
    try writeExecutable(resources.shimScripts["claude"] ?? "", to: shimURL)

    return ShimFixture(
        root: root, tkzmuxBin: tkzmuxBin, realClaudeDir: realClaudeDir,
        fakeClaudeLog: fakeClaudeLog, fakeClaudeEnvLog: fakeClaudeEnvLog, fakeHookLog: fakeHookLog,
        shimURL: shimURL)
}

// MARK: 1. No session env -> pass-through, hook never called

@Test func noSessionIDPassesThroughUntouched() throws {
    let fixture = try makeShimFixture()
    let result = try run(
        fixture.shimURL, ["--model", "fable"],
        environment: fixture.baseEnvironment(sessionID: nil))
    #expect(result.status == 0)

    let claudeInvocations = decodeArgvLog(fixture.fakeClaudeLog)
    #expect(claudeInvocations.count == 1)
    #expect(claudeInvocations[0].dropFirst() == ["--model", "fable"])
    #expect(!FileManager.default.fileExists(atPath: fixture.fakeHookLog.path))
}

@Test func noSocketPassesThroughUntouched() throws {
    let fixture = try makeShimFixture()
    let result = try run(
        fixture.shimURL, ["--model", "fable"],
        environment: fixture.baseEnvironment(socket: nil))
    #expect(result.status == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.fakeHookLog.path))
}

// MARK: 2. Subcommands and flags -> pass-through

@Test func subcommandsPassThrough() throws {
    let fixture = try makeShimFixture()
    let result = try run(fixture.shimURL, ["agents"], environment: fixture.baseEnvironment())
    #expect(result.status == 0)
    let claudeInvocations = decodeArgvLog(fixture.fakeClaudeLog)
    #expect(claudeInvocations.last?.dropFirst() == ["agents"])
    #expect(!FileManager.default.fileExists(atPath: fixture.fakeHookLog.path))
}

@Test func printFlagPassesThrough() throws {
    let fixture = try makeShimFixture()
    let result = try run(fixture.shimURL, ["-p", "hi"], environment: fixture.baseEnvironment())
    #expect(result.status == 0)
    let claudeInvocations = decodeArgvLog(fixture.fakeClaudeLog)
    #expect(claudeInvocations.last?.dropFirst() == ["-p", "hi"])
    #expect(!FileManager.default.fileExists(atPath: fixture.fakeHookLog.path))
}

@Test func helpFlagPassesThrough() throws {
    let fixture = try makeShimFixture()
    let result = try run(fixture.shimURL, ["--help"], environment: fixture.baseEnvironment())
    #expect(result.status == 0)
    let claudeInvocations = decodeArgvLog(fixture.fakeClaudeLog)
    #expect(claudeInvocations.last?.dropFirst() == ["--help"])
    #expect(!FileManager.default.fileExists(atPath: fixture.fakeHookLog.path))
}

// MARK: 3. Normal invocation -> settings merged, launch announced

@Test func normalInvocationInjectsSettingsAndAnnouncesLaunch() throws {
    let fixture = try makeShimFixture()
    let result = try run(
        fixture.shimURL, ["--model", "fable"], environment: fixture.baseEnvironment())
    #expect(result.status == 0)

    let claudeInvocations = decodeArgvLog(fixture.fakeClaudeLog)
    #expect(claudeInvocations.count == 1)
    #expect(
        claudeInvocations[0].dropFirst() == ["--model", "fable", "--settings", "{\"merged\":true}"])

    let hookInvocations = decodeArgvLog(fixture.fakeHookLog)
    #expect(hookInvocations.count == 2)
    #expect(hookInvocations[0].dropFirst() == ["settings-merge", ""])

    let launch = hookInvocations[1].dropFirst()
    #expect(launch.first == "launch")
    #expect(launch.contains("--pid"))
    #expect(launch.contains("--cwd"))
    #expect(Array(launch.suffix(3)) == ["--", "--model", "fable"])

    // `--config-dir` (resolved by the shim itself: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`) and
    // `--agent claude` both ride on this same launch call.
    guard let configDirIndex = launch.firstIndex(of: "--config-dir") else {
        Issue.record("expected --config-dir in the launch invocation: \(launch)")
        return
    }
    #expect(launch[launch.index(after: configDirIndex)] == fixture.root.path + "/.claude")
    guard let agentIndex = launch.firstIndex(of: "--agent") else {
        Issue.record("expected --agent in the launch invocation: \(launch)")
        return
    }
    #expect(launch[launch.index(after: agentIndex)] == "claude")
}

/// The shim exports `TKZMUX_AGENT=claude` before `exec`ing the real agent -- that export, not a
/// flag, is what lets a hook process the agent spawns later know which agent it's relaying for.
@Test func shimExportsTkzmuxAgentClaudeToTheRealProcess() throws {
    let fixture = try makeShimFixture()
    let result = try run(
        fixture.shimURL, ["--model", "fable"], environment: fixture.baseEnvironment())
    #expect(result.status == 0)

    let envLines = (try? String(contentsOf: fixture.fakeClaudeEnvLog, encoding: .utf8)) ?? ""
    #expect(envLines.contains("TKZMUX_AGENT=claude"))
}

/// `--config-dir` respects an explicit `$CLAUDE_CONFIG_DIR` rather than always falling back to
/// `$HOME/.claude` -- the same fallback rule the deleted `claudeConfigDirectory()` used to enforce
/// inside the binary, now enforced by the shim instead.
@Test func shimRespectsExplicitClaudeConfigDir() throws {
    let fixture = try makeShimFixture()
    var env = fixture.baseEnvironment()
    env["CLAUDE_CONFIG_DIR"] = "/tmp/some-other-claude-dir"
    let result = try run(fixture.shimURL, ["--model", "fable"], environment: env)
    #expect(result.status == 0)

    let hookInvocations = decodeArgvLog(fixture.fakeHookLog)
    let launch = hookInvocations[1].dropFirst()
    guard let configDirIndex = launch.firstIndex(of: "--config-dir") else {
        Issue.record("expected --config-dir in the launch invocation: \(launch)")
        return
    }
    #expect(launch[launch.index(after: configDirIndex)] == "/tmp/some-other-claude-dir")
}

// MARK: 4. --settings stripped, last value wins

@Test func settingsFlagsAreStrippedAndLastValueWins() throws {
    let fixture = try makeShimFixture()
    let result = try run(
        fixture.shimURL, ["--settings", "x.json", "--settings=y.json"],
        environment: fixture.baseEnvironment())
    #expect(result.status == 0)

    let claudeInvocations = decodeArgvLog(fixture.fakeClaudeLog)
    #expect(claudeInvocations[0].dropFirst() == ["--settings", "{\"merged\":true}"])

    let hookInvocations = decodeArgvLog(fixture.fakeHookLog)
    #expect(hookInvocations[0].dropFirst() == ["settings-merge", "y.json"])
}

// MARK: 5. Merge failure -> original argv untouched

@Test func mergeFailureFallsBackToOriginalArgv() throws {
    let fixture = try makeShimFixture()
    var env = fixture.baseEnvironment()
    env["FAKE_MERGE_FAIL"] = "1"
    let result = try run(fixture.shimURL, ["--model", "fable"], environment: env)
    #expect(result.status == 0)

    let claudeInvocations = decodeArgvLog(fixture.fakeClaudeLog)
    #expect(claudeInvocations.count == 1)
    #expect(claudeInvocations[0].dropFirst() == ["--model", "fable"])

    // launch must never have been called: the fallback exec happens before it.
    let hookInvocations = decodeArgvLog(fixture.fakeHookLog)
    #expect(hookInvocations.count == 1)
    #expect(hookInvocations[0].dropFirst().first == "settings-merge")
}

// MARK: 6. Hook binary missing -> pass-through

@Test func missingHookBinaryPassesThrough() throws {
    let fixture = try makeShimFixture()
    try FileManager.default.removeItem(
        at: fixture.tkzmuxBin.appendingPathComponent("tkzmux-hook"))
    let result = try run(
        fixture.shimURL, ["--model", "fable"], environment: fixture.baseEnvironment())
    #expect(result.status == 0)
    let claudeInvocations = decodeArgvLog(fixture.fakeClaudeLog)
    #expect(claudeInvocations[0].dropFirst() == ["--model", "fable"])
}

// MARK: 7. No real claude on PATH -> exit 127

@Test func noRealClaudeOnPathExits127() throws {
    let fixture = try makeShimFixture()
    try FileManager.default.removeItem(at: fixture.realClaudeDir.appendingPathComponent("claude"))
    let result = try run(
        fixture.shimURL, ["--model", "fable"], environment: fixture.baseEnvironment())
    #expect(result.status == 127)
    #expect(result.stderr.contains("claude: command not found"))
}

// MARK: 8. The shim never resolves itself as the real claude

@Test func shimDoesNotResolveItselfWhenTkzmuxBinAppearsTwiceOnPath() throws {
    let fixture = try makeShimFixture()
    var env = fixture.baseEnvironment()
    env["PATH"] = "\(fixture.tkzmuxBin.path):\(fixture.tkzmuxBin.path):\(fixture.realClaudeDir.path)"
    let result = try run(fixture.shimURL, ["--model", "fable"], environment: env)
    #expect(result.status == 0)
    let claudeInvocations = decodeArgvLog(fixture.fakeClaudeLog)
    #expect(claudeInvocations.count == 1)
    // The one and only real-claude invocation ran the fake in realClaudeDir, not the shim itself.
    #expect(claudeInvocations[0][0] == fixture.realClaudeDir.appendingPathComponent("claude").path)
}

@Test func shimDoesNotResolveItselfViaASymlinkedTkzmuxBin() throws {
    let fixture = try makeShimFixture()
    let symlinkedBin = fixture.root.appendingPathComponent("bin-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: symlinkedBin, withDestinationURL: fixture.tkzmuxBin)

    var env = fixture.baseEnvironment()
    env["PATH"] = "\(symlinkedBin.path):\(fixture.realClaudeDir.path)"
    let result = try run(fixture.shimURL, ["--model", "fable"], environment: env)
    #expect(result.status == 0)
    let claudeInvocations = decodeArgvLog(fixture.fakeClaudeLog)
    #expect(claudeInvocations.count == 1)
    #expect(claudeInvocations[0][0] == fixture.realClaudeDir.appendingPathComponent("claude").path)
}

// MARK: - codex.sh

/// Mirrors `fakeClaudeScript`, for the fake real `codex`.
private let fakeCodexScript = """
#!/bin/bash
{
    printf '%s\\0' "$0" "$@"
    printf '\\n'
} >> "$FAKE_CODEX_LOG"
# Records the env the shim handed the real agent -- proves TKZMUX_AGENT was exported (inherited
# here), not just set in the shim's own shell.
printf 'TKZMUX_AGENT=%s\\n' "${TKZMUX_AGENT:-}" >> "$FAKE_CODEX_ENV_LOG"
"""

private struct CodexShimFixture {
    var root: URL
    var tkzmuxBin: URL
    var realCodexDir: URL
    var fakeCodexLog: URL
    var fakeCodexEnvLog: URL
    var fakeHookLog: URL
    var shimURL: URL

    var basePath: String { "\(tkzmuxBin.path):\(realCodexDir.path)" }

    func baseEnvironment(sessionID: String? = "sid-1", socket: String? = "sock") -> [String: String] {
        var env: [String: String] = [
            "PATH": basePath,
            "TKZMUX_BIN": tkzmuxBin.path,
            "FAKE_CODEX_LOG": fakeCodexLog.path,
            "FAKE_CODEX_ENV_LOG": fakeCodexEnvLog.path,
            "FAKE_HOOK_LOG": fakeHookLog.path,
            "HOME": root.path,
        ]
        if let sessionID { env["TKZMUX_SESSION_ID"] = sessionID }
        if let socket { env["TKZMUX_SOCKET"] = socket }
        return env
    }
}

/// The fake hook binary here only needs to log its argv -- `codex.sh` never calls `settings-merge`,
/// so `fakeHookScript`'s branch for it is irrelevant but harmless to reuse.
private func makeCodexShimFixture() throws -> CodexShimFixture {
    let root = try makeTempDirectory("codex-shim")
    let tkzmuxBin = root.appendingPathComponent("bin", isDirectory: true)
    let realCodexDir = root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: tkzmuxBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: realCodexDir, withIntermediateDirectories: true)

    let fakeCodexLog = root.appendingPathComponent("codex.log")
    let fakeCodexEnvLog = root.appendingPathComponent("codex-env.log")
    let fakeHookLog = root.appendingPathComponent("hook.log")

    try writeExecutable(fakeCodexScript, to: realCodexDir.appendingPathComponent("codex"))
    try writeExecutable(fakeHookScript, to: tkzmuxBin.appendingPathComponent("tkzmux-hook"))

    let resources = try ShimResources.bundled()
    let shimURL = tkzmuxBin.appendingPathComponent("codex")
    try writeExecutable(resources.shimScripts["codex"] ?? "", to: shimURL)

    return CodexShimFixture(
        root: root, tkzmuxBin: tkzmuxBin, realCodexDir: realCodexDir,
        fakeCodexLog: fakeCodexLog, fakeCodexEnvLog: fakeCodexEnvLog, fakeHookLog: fakeHookLog,
        shimURL: shimURL)
}

@Test func codexNoSessionIDPassesThroughUntouched() throws {
    let fixture = try makeCodexShimFixture()
    let result = try run(
        fixture.shimURL, ["exec", "hi"], environment: fixture.baseEnvironment(sessionID: nil))
    #expect(result.status == 0)
    let invocations = decodeArgvLog(fixture.fakeCodexLog)
    #expect(invocations.count == 1)
    #expect(invocations[0].dropFirst() == ["exec", "hi"])
    #expect(!FileManager.default.fileExists(atPath: fixture.fakeHookLog.path))
}

@Test func codexNoSocketPassesThroughUntouched() throws {
    let fixture = try makeCodexShimFixture()
    let result = try run(
        fixture.shimURL, ["exec", "hi"], environment: fixture.baseEnvironment(socket: nil))
    #expect(result.status == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.fakeHookLog.path))
}

/// A one-off subcommand: no interactive session, so no `launch` announcement, and (since there is
/// no settings file to merge for Codex) argv reaches the real binary completely unmodified either
/// way.
@Test func codexOneOffSubcommandsPassThrough() throws {
    let fixture = try makeCodexShimFixture()
    let result = try run(fixture.shimURL, ["login"], environment: fixture.baseEnvironment())
    #expect(result.status == 0)
    let invocations = decodeArgvLog(fixture.fakeCodexLog)
    #expect(invocations.last?.dropFirst() == ["login"])
    #expect(!FileManager.default.fileExists(atPath: fixture.fakeHookLog.path))
}

@Test func codexVersionAndHelpFlagsPassThrough() throws {
    let fixture = try makeCodexShimFixture()
    for flag in ["--version", "-V", "--help", "-h"] {
        let result = try run(fixture.shimURL, [flag], environment: fixture.baseEnvironment())
        #expect(result.status == 0)
        let invocations = decodeArgvLog(fixture.fakeCodexLog)
        #expect(invocations.last?.dropFirst() == [flag])
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.fakeHookLog.path))
}

/// `resume` is deliberately NOT in the pass-through list: it starts an interactive session (it is
/// tkzmux's own resume command), so it must get the same `launch` announcement a bare `codex`
/// invocation gets.
@Test func codexResumeIsNotPassedThroughAndAnnouncesLaunch() throws {
    let fixture = try makeCodexShimFixture()
    let result = try run(
        fixture.shimURL, ["resume", "abc123"], environment: fixture.baseEnvironment())
    #expect(result.status == 0)

    let invocations = decodeArgvLog(fixture.fakeCodexLog)
    #expect(invocations.count == 1)
    #expect(invocations[0].dropFirst() == ["resume", "abc123"])

    let hookInvocations = decodeArgvLog(fixture.fakeHookLog)
    #expect(hookInvocations.count == 1)
    let launch = hookInvocations[0].dropFirst()
    #expect(launch.first == "launch")
    #expect(Array(launch.suffix(3)) == ["--", "resume", "abc123"])
}

/// `fork` is the same story as `resume`.
@Test func codexForkIsNotPassedThrough() throws {
    let fixture = try makeCodexShimFixture()
    let result = try run(fixture.shimURL, ["fork"], environment: fixture.baseEnvironment())
    #expect(result.status == 0)
    let hookInvocations = decodeArgvLog(fixture.fakeHookLog)
    #expect(hookInvocations.count == 1)
    #expect(hookInvocations[0].dropFirst().first == "launch")
}

/// A bare invocation (new interactive session, no subcommand) also gets the `launch` announcement,
/// with the right `--config-dir` and `--agent codex`, and argv reaches the real binary unmodified.
@Test func codexBareInvocationAnnouncesLaunchWithConfigDirAndAgent() throws {
    let fixture = try makeCodexShimFixture()
    let result = try run(fixture.shimURL, [], environment: fixture.baseEnvironment())
    #expect(result.status == 0)

    let invocations = decodeArgvLog(fixture.fakeCodexLog)
    #expect(invocations.count == 1)
    #expect(invocations[0].dropFirst().isEmpty)

    let hookInvocations = decodeArgvLog(fixture.fakeHookLog)
    #expect(hookInvocations.count == 1)
    let launch = hookInvocations[0].dropFirst()
    #expect(launch.first == "launch")
    #expect(launch.contains("--pid"))
    #expect(launch.contains("--cwd"))

    guard let configDirIndex = launch.firstIndex(of: "--config-dir") else {
        Issue.record("expected --config-dir in the launch invocation: \(launch)")
        return
    }
    #expect(launch[launch.index(after: configDirIndex)] == fixture.root.path + "/.codex")
    guard let agentIndex = launch.firstIndex(of: "--agent") else {
        Issue.record("expected --agent in the launch invocation: \(launch)")
        return
    }
    #expect(launch[launch.index(after: agentIndex)] == "codex")
}

/// `--config-dir` respects an explicit `$CODEX_HOME` rather than always falling back to
/// `$HOME/.codex`.
@Test func codexShimRespectsExplicitCodexHome() throws {
    let fixture = try makeCodexShimFixture()
    var env = fixture.baseEnvironment()
    env["CODEX_HOME"] = "/tmp/some-other-codex-dir"
    let result = try run(fixture.shimURL, [], environment: env)
    #expect(result.status == 0)

    let hookInvocations = decodeArgvLog(fixture.fakeHookLog)
    let launch = hookInvocations[0].dropFirst()
    guard let configDirIndex = launch.firstIndex(of: "--config-dir") else {
        Issue.record("expected --config-dir in the launch invocation: \(launch)")
        return
    }
    #expect(launch[launch.index(after: configDirIndex)] == "/tmp/some-other-codex-dir")
}

/// The shim exports `TKZMUX_AGENT=codex` before `exec`ing the real agent.
@Test func codexShimExportsTkzmuxAgentCodexToTheRealProcess() throws {
    let fixture = try makeCodexShimFixture()
    let result = try run(fixture.shimURL, [], environment: fixture.baseEnvironment())
    #expect(result.status == 0)
    let envLines = (try? String(contentsOf: fixture.fakeCodexEnvLog, encoding: .utf8)) ?? ""
    #expect(envLines.contains("TKZMUX_AGENT=codex"))
}

@Test func codexMissingHookBinaryPassesThrough() throws {
    let fixture = try makeCodexShimFixture()
    try FileManager.default.removeItem(at: fixture.tkzmuxBin.appendingPathComponent("tkzmux-hook"))
    let result = try run(fixture.shimURL, [], environment: fixture.baseEnvironment())
    #expect(result.status == 0)
    let invocations = decodeArgvLog(fixture.fakeCodexLog)
    #expect(invocations.count == 1)
}

@Test func codexNoRealCodexOnPathExits127() throws {
    let fixture = try makeCodexShimFixture()
    try FileManager.default.removeItem(at: fixture.realCodexDir.appendingPathComponent("codex"))
    let result = try run(fixture.shimURL, [], environment: fixture.baseEnvironment())
    #expect(result.status == 127)
    #expect(result.stderr.contains("codex: command not found"))
}

@Test func codexShimDoesNotResolveItselfWhenTkzmuxBinAppearsTwiceOnPath() throws {
    let fixture = try makeCodexShimFixture()
    var env = fixture.baseEnvironment()
    env["PATH"] = "\(fixture.tkzmuxBin.path):\(fixture.tkzmuxBin.path):\(fixture.realCodexDir.path)"
    let result = try run(fixture.shimURL, [], environment: env)
    #expect(result.status == 0)
    let invocations = decodeArgvLog(fixture.fakeCodexLog)
    #expect(invocations.count == 1)
    #expect(invocations[0][0] == fixture.realCodexDir.appendingPathComponent("codex").path)
}

@Test func codexShimDoesNotResolveItselfViaASymlinkedTkzmuxBin() throws {
    let fixture = try makeCodexShimFixture()
    let symlinkedBin = fixture.root.appendingPathComponent("bin-link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: symlinkedBin, withDestinationURL: fixture.tkzmuxBin)

    var env = fixture.baseEnvironment()
    env["PATH"] = "\(symlinkedBin.path):\(fixture.realCodexDir.path)"
    let result = try run(fixture.shimURL, [], environment: env)
    #expect(result.status == 0)
    let invocations = decodeArgvLog(fixture.fakeCodexLog)
    #expect(invocations.count == 1)
    #expect(invocations[0][0] == fixture.realCodexDir.appendingPathComponent("codex").path)
}
