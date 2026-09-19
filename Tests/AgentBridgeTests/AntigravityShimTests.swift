// AntigravityShimTests — `agy.sh` against a fake `agy` and a fake `tkzmux-hook` on a fully
// controlled PATH. Mirrors `ShimTests`, whose harness this reuses in spirit: the shim under test is
// the real bundled resource, so a change to the script that breaks pass-through fails here.

import Foundation
import Testing

@testable import AgentBridge

@Suite struct AntigravityShimTests {
    /// Records argv and, separately, the environment the shim handed the real binary — which is how
    /// this proves `TKZMUX_AGENT` was *exported* rather than merely set in the shim's own shell.
    static let fakeAgyScript = """
        #!/bin/bash
        {
            printf '%s\\0' "$0" "$@"
            printf '\\n'
        } >> "$FAKE_AGY_LOG"
        printf 'TKZMUX_AGENT=%s\\n' "${TKZMUX_AGENT:-}" >> "$FAKE_AGY_ENV_LOG"
        """

    static let fakeHookScript = """
        #!/bin/bash
        {
            printf '%s\\0' "$0" "$@"
            printf '\\n'
        } >> "$FAKE_HOOK_LOG"
        exit 0
        """

    struct Fixture {
        var root: URL
        var tkzmuxBin: URL
        var realDir: URL
        var agyLog: URL
        var agyEnvLog: URL
        var hookLog: URL
        var shimURL: URL

        func environment(sessionID: String? = "sid-1", socket: String? = "sock") -> [String: String] {
            var env: [String: String] = [
                "PATH": "\(tkzmuxBin.path):\(realDir.path)",
                "TKZMUX_BIN": tkzmuxBin.path,
                "FAKE_AGY_LOG": agyLog.path,
                "FAKE_AGY_ENV_LOG": agyEnvLog.path,
                "FAKE_HOOK_LOG": hookLog.path,
                "HOME": root.path,
            ]
            if let sessionID { env["TKZMUX_SESSION_ID"] = sessionID }
            if let socket { env["TKZMUX_SOCKET"] = socket }
            return env
        }
    }

    static func makeFixture() throws -> Fixture {
        let root = try ShimTestSupport.makeTempDirectory("agy-shim")
        let tkzmuxBin = root.appendingPathComponent("bin", isDirectory: true)
        let realDir = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: tkzmuxBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

        try ShimTestSupport.writeExecutable(fakeAgyScript, to: realDir.appendingPathComponent("agy"))
        try ShimTestSupport.writeExecutable(
            fakeHookScript, to: tkzmuxBin.appendingPathComponent("tkzmux-hook"))

        // The real bundled script, not a copy — `ShimResources.bundled()` enumerates
        // `Resources/shim/*.sh` and keys them by basename, which is also how the installer names
        // them on disk.
        let resources = try ShimResources.bundled()
        let shimURL = tkzmuxBin.appendingPathComponent("agy")
        try ShimTestSupport.writeExecutable(resources.shimScripts["agy"] ?? "", to: shimURL)

        return Fixture(
            root: root, tkzmuxBin: tkzmuxBin, realDir: realDir,
            agyLog: root.appendingPathComponent("agy.log"),
            agyEnvLog: root.appendingPathComponent("agy-env.log"),
            hookLog: root.appendingPathComponent("hook.log"),
            shimURL: shimURL)
    }

    @Test("The shim is bundled under the binary's name, not the agent's")
    func shimIsBundledAsAgy() throws {
        let resources = try ShimResources.bundled()
        // The installer derives the installed name from this key, and it has to shadow `agy` on
        // PATH — an `antigravity.sh` would install a shim nothing ever calls.
        #expect(resources.shimScripts["agy"] != nil)
        #expect(resources.shimScripts["antigravity"] == nil)
    }

    @Test("Outside a tkzmux session the shim is a pass-through and never calls the hook")
    func noSessionEnvPassesThrough() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try ShimTestSupport.run(
            fixture.shimURL, ["--model", "auto"],
            environment: fixture.environment(sessionID: nil))
        #expect(result.status == 0)
        #expect(Array(ShimTestSupport.decodeArgvLog(fixture.agyLog).first?.dropFirst() ?? []) == ["--model", "auto"])
        #expect(!FileManager.default.fileExists(atPath: fixture.hookLog.path), "hook not called")
    }

    @Test("Subcommands that never start a session pass through untouched")
    func subcommandsPassThrough() throws {
        // Every `agy` subcommand is in the list, because an interactive session is always a bare
        // `agy` with no subcommand at all — the deliberate difference from the other shims.
        for subcommand in ["models", "agents", "mcp", "plugin", "update", "install", "changelog"] {
            let fixture = try Self.makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let result = try ShimTestSupport.run(
                fixture.shimURL, [subcommand], environment: fixture.environment())
            #expect(result.status == 0, "\(subcommand)")
            #expect(
                !FileManager.default.fileExists(atPath: fixture.hookLog.path),
                "\(subcommand) must not announce a launch")
        }
    }

    /// Print mode runs one turn and exits, so there is no session for the sidebar to hold;
    /// announcing a launch would create a row that is already over. `--prompt-interactive` is
    /// deliberately not in this set — it starts a real session and is what tkzmux's own prompt
    /// launches use.
    @Test("Print mode passes through; interactive prompt mode does not")
    func printModePassesThroughButInteractiveDoesNot() throws {
        for flag in ["-p", "--print", "--prompt"] {
            let fixture = try Self.makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = try ShimTestSupport.run(
                fixture.shimURL, [flag, "hello"], environment: fixture.environment())
            #expect(
                !FileManager.default.fileExists(atPath: fixture.hookLog.path),
                "\(flag) is one-shot; no launch announcement")
        }

        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try ShimTestSupport.run(
            fixture.shimURL, ["--prompt-interactive", "hello"], environment: fixture.environment())
        #expect(
            FileManager.default.fileExists(atPath: fixture.hookLog.path),
            "--prompt-interactive starts a real session and must be announced")
    }

    @Test("--version and --help pass through")
    func versionAndHelpPassThrough() throws {
        for flag in ["--version", "--help", "-h"] {
            let fixture = try Self.makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = try ShimTestSupport.run(fixture.shimURL, [flag], environment: fixture.environment())
            #expect(!FileManager.default.fileExists(atPath: fixture.hookLog.path), "\(flag)")
        }
    }

    @Test("A normal invocation announces the launch and execs the original argv unmodified")
    func normalInvocationAnnouncesTheLaunch() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try ShimTestSupport.run(
            fixture.shimURL, ["--model", "auto"], environment: fixture.environment())
        #expect(result.status == 0)

        let hookArgv = try #require(ShimTestSupport.decodeArgvLog(fixture.hookLog).first)
        #expect(hookArgv.contains("launch"))
        // The agent the relay path routes on. Without it, `AgentIntegration.bind` would file this
        // process's config dir under the wrong agent.
        #expect(hookArgv.contains("--agent"))
        #expect(hookArgv.contains("antigravity"))
        // `~/.gemini`, not `~/.antigravity` — the config dir this agent actually uses.
        let configIndex = try #require(hookArgv.firstIndex(of: "--config-dir"))
        #expect(hookArgv[configIndex + 1] == "\(fixture.root.path)/.gemini")

        // argv reaches the real binary untouched: there is no settings file to merge here.
        let agyArgv = try #require(ShimTestSupport.decodeArgvLog(fixture.agyLog).first)
        #expect(Array(agyArgv.dropFirst()) == ["--model", "auto"])
    }

    @Test("TKZMUX_AGENT is exported, so the real process and its hooks inherit it")
    func agentIsExportedToTheRealProcess() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try ShimTestSupport.run(fixture.shimURL, [], environment: fixture.environment())
        let env = try String(contentsOf: fixture.agyEnvLog, encoding: .utf8)
        // Inherited by the child, which is the whole mechanism — a plain assignment in the shim's
        // own shell would not reach the hook processes `agy` spawns.
        #expect(env.contains("TKZMUX_AGENT=antigravity"))
    }

    @Test("A missing hook binary degrades to a pass-through rather than breaking agy")
    func missingHookBinaryPassesThrough() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.tkzmuxBin.appendingPathComponent("tkzmux-hook"))
        let result = try ShimTestSupport.run(
            fixture.shimURL, ["--model", "auto"], environment: fixture.environment())
        #expect(result.status == 0, "never break agy")
        #expect(Array(ShimTestSupport.decodeArgvLog(fixture.agyLog).first?.dropFirst() ?? []) == ["--model", "auto"])
    }

    @Test("No real agy on PATH exits 127 with a message naming the shim")
    func noRealAgyExits127() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.realDir.appendingPathComponent("agy"))
        let result = try ShimTestSupport.run(
            fixture.shimURL, [], environment: fixture.environment())
        #expect(result.status == 127)
        #expect(result.stderr.contains("tkzmux shim"))
    }
}
