// ShimTests — exercises the installed `claude.sh` shim end to end via `Process`, against a fake
// real `claude` and a fake `tkzmux-hook` on a fully controlled PATH. See docs/design.md ->
// Claude integration -> Shim, and the TKZ-23 ticket for the exact behavioural contract.
import Foundation
import Testing

@testable import ClaudeBridge

/// Test plumbing shared by ShimTests / ZshWrapperTests / ShimInstallerTests: temp directories and
// a thin `Process` runner. Namespaced (rather than a separate file with top-level declarations)
// because `Tests/ClaudeBridgeTests` is written concurrently by another agent's test file, and
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
    var fakeHookLog: URL
    var shimURL: URL

    var basePath: String { "\(tkzmuxBin.path):\(realClaudeDir.path)" }

    func baseEnvironment(sessionID: String? = "sid-1", socket: String? = "sock") -> [String: String] {
        var env: [String: String] = [
            "PATH": basePath,
            "TKZMUX_BIN": tkzmuxBin.path,
            "FAKE_CLAUDE_LOG": fakeClaudeLog.path,
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
    let fakeHookLog = root.appendingPathComponent("hook.log")

    try writeExecutable(fakeClaudeScript, to: realClaudeDir.appendingPathComponent("claude"))
    try writeExecutable(fakeHookScript, to: tkzmuxBin.appendingPathComponent("tkzmux-hook"))

    let resources = try ShimResources.bundled()
    let shimURL = tkzmuxBin.appendingPathComponent("claude")
    try writeExecutable(resources.shimScript, to: shimURL)

    return ShimFixture(
        root: root, tkzmuxBin: tkzmuxBin, realClaudeDir: realClaudeDir,
        fakeClaudeLog: fakeClaudeLog, fakeHookLog: fakeHookLog, shimURL: shimURL)
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
