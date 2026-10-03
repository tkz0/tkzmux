// AgentFixtureReplayTests — what real Claude Code 2.1.287 and codex-cli 0.160 sent tkzmux on Linux,
// replayed through tkzmux's own pipeline on every OS (WOR-306 S6).
//
// `Fixtures/linux/<agent>/` holds the payloads `RealAgentProbeTests` captured from a real run, and
// `sequence` the order they arrived in. Each one goes back through the built `tkzmux-hook` (stdin
// for a hook event, argv for `launch` and `notify-argv`) to a real `HookServer`, and the frames
// that arrive are turned into the same `AgentTrace` sections the probe writes. They must equal the
// golden's: the hook mappers decode every Linux payload, the same way on macOS and Linux. The rest
// of a golden (descriptor, statusline, transcript) needs the live agent; the tests below check the
// fixtures behind those sections one by one.
import Foundation
import Testing
import TkzCore

@testable import AgentBridge

private enum Replay {
    static var fixtures: URL { RealAgentProbe.fixtures }

    /// The fixture spelling of a probe world (`ProbeWorld.fixtureText`), as trace placeholders.
    static var normalizer: TraceNormalizer {
        TraceNormalizer(paths: [
            ("/home/tester/project", "<project>"), ("/home/tester/.local/share/tkzmux", "<support>"),
            ("/home/tester", "<home>"),
        ])
    }

    /// `$TKZMUX_HOOK_BIN`, else the hook `swift test` built into the products directory: beside
    /// this module's resource bundle, or beside the `.xctest` the runner was handed.
    static func hookBinary() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["TKZMUX_HOOK_BIN"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        var directories = [ModuleResources.bundle.bundleURL.deletingLastPathComponent()]
        for argument in ProcessInfo.processInfo.arguments {
            guard let range = argument.range(of: ".xctest") else { continue }
            directories.append(URL(fileURLWithPath: String(argument[..<range.upperBound])).deletingLastPathComponent())
        }
        let built = directories.map { $0.appending(path: "tkzmux-hook") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        return try #require(built, "the build's tkzmux-hook in \(directories.map(\.path))")
    }

    /// A short socket directory: `sun_path` is 104 bytes on macOS.
    static func socketDirectory() throws -> URL {
        var template = Array("/tmp/tkzrp.XXXXXX".utf8CString)
        try #require(template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress!) != nil })
        return URL(fileURLWithPath: template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, isDirectory: true)
    }

    static func text(_ agent: String, _ name: String) throws -> String {
        try String(contentsOf: fixtures.appending(path: "\(agent)/\(name)"), encoding: .utf8)
    }
}

@Suite(.serialized) struct AgentFixtureReplayTests {
    @Test(arguments: [("claude", "claude-code.trace"), ("codex", "codex.trace")])
    func capturedPayloadsReplayToTheGoldenTrace(agent: String, golden: String) async throws {
        let hook = try Replay.hookBinary()
        let socketDirectory = try Replay.socketDirectory()
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let recorder = ProbeRecorder()
        let server = HookServer(socketPath: socketDirectory.appending(path: "tkzmux-1.sock")) { frame in
            recorder.append(.frame(frame))
        }
        try server.start()
        defer { server.stop() }

        var panes: [String: String] = [:]
        let sequence = try Replay.text(agent, "sequence").split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        for (index, fields) in sequence.enumerated() {
            // launch <agent> <pane> <file> | hook|notify <agent> <pane> <event> <file>
            try #require(fields.count >= 4, "sequence line \(index + 1)")
            let pane = panes[fields[2]] ?? UUID().uuidString
            panes[fields[2]] = pane
            let environment = [
                "PATH": "/usr/bin:/bin", "TKZMUX_SOCKET": server.socketPath.path,
                "TKZMUX_SESSION_ID": pane, "TKZMUX_AGENT": fields[1],
            ]
            let payload = try Replay.text(agent, fields.last!)
            switch fields[0] {
            case "launch":
                let argv = payload.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                _ = try ShimTestSupport.run(hook, Array(argv.dropLast()), environment: environment)
            case "notify":
                _ = try ShimTestSupport.run(hook, ["notify-argv", payload], environment: environment)
            default:
                _ = try ShimTestSupport.run(hook, [fields[3]], environment: environment, stdin: payload)
            }
            let arrived = await probeWait(5) { recorder.frames.count == index + 1 }
            #expect(arrived, "\(agent): no frame for sequence line \(index + 1)")
        }

        var normalizer = Replay.normalizer
        let launches = recorder.launches.map { AgentTrace.launchLine($0, normalizer: &normalizer) }
        let (hooks, notify) = AgentTrace.hookLines(
            frames: recorder.frames,
            adapters: [.claude: ClaudeAdapter(), .codex: CodexAdapter(supportDirectory: URL(fileURLWithPath: "/"))],
            normalizer: &normalizer)
        let expected = AgentTrace.sections(
            of: try String(contentsOf: Replay.fixtures.appending(path: golden), encoding: .utf8))
        #expect(!hooks.isEmpty)
        #expect(launches == expected["launch"] ?? [])
        #expect(hooks == expected["hooks"] ?? [])
        #expect(notify == expected["notify"] ?? [])
        // Every payload mapped to something the store reacts to.
        #expect(!hooks.contains { $0.contains("-> dropped") || $0.contains("-> unknown(") })
    }

    // MARK: Claude Code

    /// Linux descriptors carry `procStart` and `pidDomain` (S3's exact guard), with the machine id
    /// zeroed here; the status the probe saw is the observation's activity.
    @Test(arguments: [("session-busy.json", AgentObservation.Activity.busy), ("session-idle.json", .idle)])
    func linuxDescriptorsDecode(file: String, activity: AgentObservation.Activity) throws {
        let info = try ClaudeSessionInfo.decode(
            Data(try Replay.text("claude", file).utf8), configDir: "/home/tester/.claude")
        #expect(info.procStart != nil)
        #expect(info.pidDomain?.hasPrefix("linux:00000000000000000000000000000000:pid:[") == true)
        #expect(info.observation.activity == activity)
        #expect(info.observation.cwd == "/home/tester/project")
    }

    /// The statusline stdin a Linux Claude Code hands the hook becomes the context sidecar
    /// `StatuslineReader` reads, in the support directory the hook was given.
    @Test func linuxStatuslineStdinBuildsTheContextSidecar() throws {
        let support = try ShimTestSupport.makeTempDirectory("replay-statusline")
        defer { try? FileManager.default.removeItem(at: support) }
        let stdin = try Replay.text("claude", "statusline-stdin.json")
        let sessionId = try #require(
            (try JSONSerialization.jsonObject(with: Data(stdin.utf8)) as? [String: Any])?["session_id"] as? String)
        _ = try ShimTestSupport.run(
            try Replay.hookBinary(), ["statusline"],
            environment: [
                "PATH": "/usr/bin:/bin", "HOME": support.path, "TKZMUX_SUPPORT_DIR": support.path,
                "CLAUDE_CONFIG_DIR": "/home/tester/.claude",
            ],
            stdin: stdin)
        let data = try Data(contentsOf: support.appending(path: "statusline/context-\(sessionId).json"))
        let sidecar = try JSONDecoder().decode(SessionSidecar.self, from: data)
        #expect(sidecar.sessionId == sessionId)
        #expect(sidecar.accountKey == "claude")
        #expect(sidecar.model?.displayName == "Opus 5.5")
        #expect(sidecar.workspace?.projectDir == "/home/tester/project")
    }

    /// The transcript directory is the cwd with every non-alphanumeric character turned into `-`,
    /// on Linux as on macOS, and `TranscriptReader.locate` finds the file there.
    @Test func linuxTranscriptPathIsFound() throws {
        let path = try #require(
            try Replay.text("claude", "paths.txt").split(separator: "\n")
                .first { $0.hasPrefix("transcript ") }?.dropFirst("transcript ".count))
        #expect(path.contains("/projects/\(TraceNormalizer.claudeSlug("/home/tester/project"))/"))
        let root = try ShimTestSupport.makeTempDirectory("replay-transcript")
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = String(path.dropFirst("/home/tester/".count))
        let file = root.appending(path: relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
        let sessionId = file.deletingPathExtension().lastPathComponent
        #expect(TranscriptReader.locate(sessionId: sessionId, configDir: root.appending(path: ".claude").path)
            == file.path)
    }

    // MARK: Codex

    /// The installer reads the `hooks.json` it wrote on Linux as its own. codex-cli 0.160 keeps its
    /// trust ledger in `config.toml` (`[hooks.state."<hooks.json>:<event>:0:0"]`), which neither
    /// reads as a hooks block nor as the disabled feature. It no longer writes the `hooks.state`
    /// file the installer's trust scan looks for, so trust stays `.unknown` (docs/linux/agents.md).
    @Test func linuxHooksJSONAndTrustLedgerDetect() throws {
        let codexHome = try ShimTestSupport.makeTempDirectory("replay-codex")
        defer { try? FileManager.default.removeItem(at: codexHome) }
        for name in ["hooks.json", "config.toml"] {
            try Replay.text("codex", name).write(to: codexHome.appending(path: name), atomically: true, encoding: .utf8)
        }
        let installer = CodexHooksInstaller(directory: URL(fileURLWithPath: "/home/tester/.local/share/tkzmux"))
        let detection = installer.detect(configDir: codexHome.path)
        #expect(detection.producer == .tkzmux)
        #expect(!detection.configTomlHasHooks)
        #expect(!detection.hooksFeatureDisabled)
        #expect(detection.trust == .unknown)
        #expect(try Replay.text("codex", "config.toml").contains("[hooks.state.\"/home/tester/.codex/hooks.json:stop:0:0\"]"))
    }

    /// Rollouts live under `sessions/<yyyy>/<mm>/<dd>/` on Linux too, and `locate` finds them by
    /// the conversation id at the end of the name.
    @Test func linuxRolloutPathsAreFound() throws {
        let rollouts = try Replay.text("codex", "paths.txt").split(separator: "\n")
            .filter { $0.hasPrefix("rollout ") }.map { String($0.dropFirst("rollout ".count)) }
        #expect(rollouts.count == 2)
        let root = try ShimTestSupport.makeTempDirectory("replay-rollout")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in rollouts {
            let file = root.appending(path: String(path.dropFirst("/home/tester/".count)))
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            let name = file.deletingPathExtension().lastPathComponent
            let conversationId = String(name.suffix(36))
            #expect(CodexTranscriptReader().locate(
                conversationId: conversationId, configDir: root.appending(path: ".codex").path,
                fileManager: .default) == file.path)
        }
    }
}
