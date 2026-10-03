// RealAgentProbeTests — real Claude Code and Codex sessions through tkzmux's own pipeline, with no
// UI (WOR-306 S6). Opt-in: `TKZMUX_REAL_AGENTS=1`, and on Linux inside a network namespace of its
// own (see `RealAgentProbe` and docs/linux/agents.md for the command).
//
// Each test runs the agent the way a tkzmux pane does: the login shell from
// `TerminalEnvironment.loginShellSpawn` on a real `Pty` with the agent as the boot command, the
// shims and wrappers from `ShimInstaller` around the release `tkzmux-hook`, a `HookServer` on the
// socket the pane is told about, `ClaudeSessionWatcher` and `StatuslineReader` on the directories
// the agents write. The probe then types a prompt, waits for the turn, quits, and turns what
// arrived into an `AgentTrace`, compared with the golden in `Fixtures/linux/`. The goldens were
// recorded on Linux; the same comparison on macOS is the Linux-equals-macOS check.
//
// `TKZMUX_REAL_AGENTS_CAPTURE=<dir>` additionally writes the payloads behind the trace, normalized,
// as the fixture files `AgentFixtureReplayTests` replays on every OS (Fixtures/linux/README.md).
import Foundation
import Testing
import TkzCore

@testable import AgentBridge
@testable import TkzTerminalCore

@Suite(.serialized, .enabled(if: RealAgentProbe.enabled, "set TKZMUX_REAL_AGENTS=1 to run real agents"))
struct RealAgentProbeTests {
    // MARK: Claude Code

    @Test func claudeCodeTraceMatchesTheGolden() async throws {
        try await runClaude(scrub: false)
    }

    /// `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` strips credentials from what Claude Code hands its
    /// hooks and statusline (measured: `ANTHROPIC_API_KEY`, cloud keys, `SSH_AUTH_SOCK`). The
    /// trace staying identical is the proof that `TKZMUX_SOCKET`, `TKZMUX_SESSION_ID` and
    /// `TKZMUX_BIN` survive it: without them no frame would arrive, or arrive unattributed.
    @Test func claudeCodeHooksSurviveTheSubprocessEnvScrub() async throws {
        try await runClaude(scrub: true)
    }

    private func runClaude(scrub: Bool) async throws {
        try #require(RealAgentProbe.networkIsIsolated(), "run inside a network namespace (docs/linux/agents.md)")
        let agentDirectory = try #require(RealAgentProbe.agentDirectory("claude"), "claude is not on PATH")
        let capture = scrub ? nil : RealAgentProbe.captureRoot?.appending(path: "claude")
        let world = try ProbeWorld(label: scrub ? "claude-scrub" : "claude", capture: capture)
        let config = world.home.appending(path: ".claude").path
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        let hook = try RealAgentProbe.hookBinary()
        try world.installShims(hook: hook)
        try StatuslineInstaller(directory: world.support).install(configDir: config, accountKey: "claude")

        // Onboarding done, the made-up key approved, the project trusted: the three first-run
        // dialogs a real user answers once.
        let key = "sk-ant-api03-tkzmux-probe-" + String(repeating: "0", count: 24)
        let projects = Dictionary(
            Set([world.project.path, TraceNormalizer.realPath(world.project.path)]).map {
                ($0, ["hasTrustDialogAccepted": true])
            }, uniquingKeysWith: { first, _ in first })
        let globalConfig: [String: Any] = [
            "hasCompletedOnboarding": true, "theme": "dark",
            "customApiKeyResponses": ["approved": [String(key.suffix(20))], "rejected": [String]()],
            "projects": projects,
        ]
        try JSONSerialization.data(withJSONObject: globalConfig)
            .write(to: URL(fileURLWithPath: config).appending(path: ".claude.json"))

        let api = try FakeModelAPI(directory: world.root)
        defer { api.stop() }
        let recorder = ProbeRecorder()
        // Variables WOR-305's lists must pass through, one they must strip, and no LANG.
        let passed = [
            "WAYLAND_DISPLAY": "wayland-probe",
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=\(world.runtime.path)/bus",
            "SSH_AUTH_SOCK": "\(world.runtime.path)/ssh-agent.sock",
        ]
        let base = world.baseEnvironment(
            agentDirectory: agentDirectory,
            extra: passed.merging([
                "XDG_ACTIVATION_TOKEN": "probe-activation-token",
                "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(api.port)",
                "ANTHROPIC_API_KEY": key,
                "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
                "TKZMUX_BOOT_COMMAND": "claude",
            ], uniquingKeysWith: { $1 }))
        let server = try world.startHookServer(environment: base, recorder: recorder)
        defer { server.stop() }

        // There from the start, as in any config dir Claude Code has run in: a watcher started
        // before it exists only picks it up at its next sweep, seconds later.
        let sessionsDirectory = URL(fileURLWithPath: config).appending(path: "sessions")
        try FileManager.default.createDirectory(
            at: sessionsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rawDirectory = capture?.appending(path: "raw")
        let watcher = try #require(ClaudeAdapter().makeObservationWatcher(configDirs: [config]) { event in
            recorder.append(.observation(event))
            // Capture: the descriptor as it was at each status, for Fixtures/linux/claude.
            if let rawDirectory, case .updated(let observation, _) = event {
                let source = sessionsDirectory.appending(path: "\(observation.pid).json")
                let target = rawDirectory.appending(path: "session-\(observation.activity?.rawValue ?? "unknown").json")
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: source, to: target)
            }
        })
        watcher.start()
        defer { watcher.stop() }
        let statusline = StatuslineReader(
            directory: StatuslineReader.standardDirectory(supportDirectory: world.support)
        ) { recorder.append(.statusline($0)) }
        statusline.start()
        defer { statusline.stop() }

        // CLAUDE_CODE_* is stripped from what the pane inherits, so the agent's own variables ride
        // in the agent environment, which is merged last, like a chosen account's config dir.
        var agentEnvironment = ClaudeAdapter().environment(configDir: config)
        agentEnvironment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        if scrub { agentEnvironment["CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"] = "1" }
        let pane = try ProbePane(
            spawn: TerminalEnvironment.loginShellSpawn(
                sessionID: SessionID.generate().rawValue, cwd: world.project.path,
                size: TerminalSize(rows: 40, cols: 120), agentEnvironment: agentEnvironment,
                tkzmuxDir: world.support, baseEnvironment: base, home: world.home.path,
                shell: LoginShell(path: "/bin/bash")),
            label: "claude")

        func require(_ what: String, _ seconds: Double, _ condition: () -> Bool) async throws {
            guard await probeWait(seconds, condition) else {
                await pane.close()
                let frames = recorder.hookPayloads.map(\.payload.eventName).joined(separator: ",")
                let counts = "observations: \(recorder.observations.count), statusline: \(recorder.statusline.count)"
                Issue.record("\(what): screen:\n\(pane.screen)\nrequests: \(api.requests)\nframes: \(frames)\n\(counts)")
                throw ProbeError.timeout(what)
            }
        }

        try await require("SessionStart", 60) { recorder.count(of: "SessionStart") == 1 }
        let launch = try #require(recorder.launches.first)
        #if os(Linux)
        // The shim execs the agent, so the launch pid is Claude Code's own process.
        try checkEnvironment(of: launch.pid, passed: passed)
        #endif
        try await Task.sleep(for: .seconds(1.5))
        await pane.type("say pong")
        await pane.enter()
        try await require("Stop", 60) { recorder.count(of: "Stop") == 1 }
        try await require("the descriptor to go idle after busy", 10) {
            let activities = recorder.observations.compactMap { event -> String? in
                if case .updated(let observation, _) = event { observation.activity?.rawValue } else { nil }
            }
            return activities.firstIndex(of: "busy").map { activities[$0...].contains("idle") } ?? false
        }
        try await require("a statusline sidecar", 10) {
            recorder.statusline.contains { if case .context = $0 { true } else { false } }
        }
        await pane.type("/exit")
        await pane.enter()
        try await require("SessionEnd", 30) { recorder.count(of: "SessionEnd") == 1 }
        try await require("the descriptor to be removed", 15) {
            recorder.observations.contains { if case .removed = $0 { true } else { false } }
        }
        await pane.close()

        if capture == nil {
            // Claude Code runs a hook through `sh -c`, which execs a simple command: the hook's
            // parent is the agent, the ppid fallback's premise.
            for entry in recorder.hookPayloads { #expect(entry.ppid == launch.pid, "\(entry.payload.eventName)") }
        }

        let adapter = ClaudeAdapter()
        let start = try #require(recorder.hookPayloads.first?.payload)
        let conversationId = try #require(start.sessionId)
        let transcriptPath = adapter.transcript.locate(
            conversationId: conversationId, configDir: config, fileManager: .default)
        #expect(transcriptPath == start.transcriptPath)
        let usage = await adapter.transcript.usage(
            conversationId: conversationId, path: transcriptPath ?? "",
            reader: TranscriptUsageReader(cacheDirectory: world.root.appending(path: "usage-cache").path))

        let summary = transcriptPath.flatMap { try? adapter.transcript.summary(path: $0) }
        var normalizer = world.normalizer
        let trace = render(
            agent: "Claude Code \(RealAgentProbe.version(of: "\(agentDirectory)/claude"))",
            recorder: recorder, adapters: [.claude: adapter], normalizer: &normalizer,
            transcripts: [(conversationId, transcriptPath, summary, usage)])
        if let capture {
            try exportFixtures(
                world: world, recorder: recorder, capture: capture, trace: trace,
                extra: [
                    ("statusline-stdin.json", lastRaw(capture, suffix: "-statusline.json")),
                    ("session-busy.json", capture.appending(path: "raw/session-busy.json")),
                    ("session-idle.json", capture.appending(path: "raw/session-idle.json")),
                    ("settings.json", URL(fileURLWithPath: config).appending(path: "settings.json")),
                ],
                notes: ["transcript \(world.fixtureText(transcriptPath ?? "-"))"])
        }
        try compare(trace, golden: "claude-code.trace", world: world)
    }

    #if os(Linux)
    /// WOR-305's lists as the agent sees them: the GUI-session variables arrive unchanged, the
    /// activation token does not, and `LANG` is the fallback the pane is given when none is set.
    private func checkEnvironment(of pid: pid_t, passed: [String: String]) throws {
        let raw = try Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/environ"))
        let environment = Dictionary(
            raw.split(separator: 0).compactMap { entry -> (String, String)? in
                let text = String(decoding: entry, as: UTF8.self)
                guard let equals = text.firstIndex(of: "=") else { return nil }
                return (String(text[..<equals]), String(text[text.index(after: equals)...]))
            }, uniquingKeysWith: { _, last in last })
        for (key, value) in passed { #expect(environment[key] == value, "\(key)") }
        #expect(environment["XDG_ACTIVATION_TOKEN"] == nil)
        #expect(environment["LANG"] == TerminalEnvironment.fallbackLanguage)
        #expect(environment["TKZMUX_AGENT"] == "claude")
    }
    #endif

    // MARK: Codex

    /// Two panes on one `CODEX_HOME`, one turn each, hooks trusted the way a user trusts them (the
    /// TUI's own review prompt), `notify` pointed at `tkzmux-hook notify-argv`. codex-cli 0.160
    /// runs every session in one app-server daemon that the first TUI starts and that outlives it,
    /// and the daemon runs the hooks: the second pane's hooks carry the *first* pane's
    /// `TKZMUX_SESSION_ID`, and their parent is the daemon. The trace records exactly that.
    @Test func codexTraceMatchesTheGolden() async throws {
        try #require(RealAgentProbe.networkIsIsolated(), "run inside a network namespace (docs/linux/agents.md)")
        let agentDirectory = try #require(RealAgentProbe.agentDirectory("codex"), "codex is not on PATH")
        let capture = RealAgentProbe.captureRoot?.appending(path: "codex")
        let world = try ProbeWorld(label: "codex", capture: capture)
        let codexHome = world.home.appending(path: ".codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let hook = try RealAgentProbe.hookBinary()
        try world.installShims(hook: hook)

        let api = try FakeModelAPI(directory: world.root)
        defer { api.stop() }
        let hookCommand = world.support.appending(path: "bin/tkzmux-hook").path
        try """
            model = "gpt-probe"
            model_provider = "probe"
            notify = ["\(hookCommand)", "notify-argv"]

            [model_providers.probe]
            name = "probe"
            base_url = "http://127.0.0.1:\(api.port)/v1"
            wire_api = "responses"
            env_key = "PROBE_API_KEY"

            """.write(to: codexHome.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        let installer = CodexHooksInstaller(directory: world.support)
        try installer.install(configDir: codexHome.path, accountKey: "codex")
        #expect(installer.detect(configDir: codexHome.path).producer == .tkzmux)
        // A git repository, so Codex does not ask about running outside one.
        _ = try ShimTestSupport.run(
            URL(fileURLWithPath: "/usr/bin/env"), ["git", "init", "-q", world.project.path],
            environment: ["PATH": "/usr/bin:/bin", "HOME": world.home.path])

        let recorder = ProbeRecorder()
        let base = world.baseEnvironment(
            agentDirectory: agentDirectory, extra: ["PROBE_API_KEY": "probe"])
        let server = try world.startHookServer(environment: base, recorder: recorder)
        defer { server.stop() }

        func openPane(_ index: Int) throws -> ProbePane {
            var environment = base
            environment["TKZMUX_BOOT_COMMAND"] = "codex"
            return try ProbePane(
                spawn: TerminalEnvironment.loginShellSpawn(
                    sessionID: SessionID.generate().rawValue, cwd: world.project.path,
                    size: TerminalSize(rows: 40, cols: 120),
                    agentEnvironment: CodexAdapter(supportDirectory: world.support)
                        .environment(configDir: codexHome.path),
                    tkzmuxDir: world.support, baseEnvironment: environment, home: world.home.path,
                    shell: LoginShell(path: "/bin/bash")),
                label: "codex-\(index)")
        }
        func require(_ what: String, _ pane: ProbePane, _ seconds: Double, _ condition: () -> Bool) async throws {
            guard await probeWait(seconds, condition) else {
                await pane.close()
                let frames = recorder.hookPayloads.map(\.payload.eventName).joined(separator: ",")
                let counts = "observations: \(recorder.observations.count), statusline: \(recorder.statusline.count)"
                Issue.record("\(what): screen:\n\(pane.screen)\nrequests: \(api.requests)\nframes: \(frames)\n\(counts)")
                throw ProbeError.timeout(what)
            }
        }

        let daemonPid = { () -> pid_t? in
            let file = codexHome.appending(path: "app-server-daemon/daemon.pid")
            guard let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let pid = object["pid"] as? Int
            else { return nil }
            return pid_t(pid)
        }
        var daemonSeen: pid_t?
        defer {
            // The daemon outlives every pane; never leave one behind. Nor its `pid-update-loop`,
            // which runs from the copy of Codex the daemon installs under `CODEX_HOME/packages`
            // and outlives the daemon (measured on 0.160): anything whose command line names this
            // world goes.
            if let pid = daemonSeen ?? daemonPid() { kill(pid, SIGKILL) }
            _ = try? ShimTestSupport.run(
                URL(fileURLWithPath: "/usr/bin/env"), ["pkill", "-KILL", "-f", world.root.path + "/"],
                environment: ["PATH": "/usr/bin:/bin"])
        }

        for index in 1...2 {
            let pane = try openPane(index)
            if index == 1 {
                // First run in this folder: trust it at Codex's own prompt, as a new user does
                // (Codex writes the `[projects."<dir>"]` entry into config.toml itself), then trust
                // the hooks tkzmux installed.
                try await require("the folder trust prompt", pane, 60) { pane.screen.contains("Trust this folder?") }
                for _ in 0..<20 where pane.screen.contains("Trust this folder?") {
                    await pane.enter()
                    _ = await probeWait(1) { !pane.screen.contains("Trust this folder?") }
                }
                try await require("the hook review prompt", pane, 60) { pane.screen.contains("Hooks need review") }
                // A digit moves the selection; Enter confirms it. The prompt is drawn a moment
                // before Codex reads keys, so the digit is repeated until the selection moves.
                for _ in 0..<20 where !pane.screen.contains("› 2. Trust all and continue") {
                    await pane.type("2")
                    _ = await probeWait(0.6) { pane.screen.contains("› 2. Trust all and continue") }
                }
                try await require("\"Trust all and continue\" selected", pane, 1) {
                    pane.screen.contains("› 2. Trust all and continue")
                }
                await pane.enter()
            }
            // Codex runs SessionStart when the thread's first turn begins, not when it opens.
            try await require("the composer \(index)", pane, 60) { pane.screen.contains("Ask Codex to do anything") }
            try await Task.sleep(for: .seconds(1))
            await pane.type(index == 1 ? "say pong" : "say pong again")
            await pane.enter()
            try await require("SessionStart \(index)", pane, 60) { recorder.count(of: "SessionStart") == index }
            try await require("Stop \(index)", pane, 60) { recorder.count(of: "Stop") == index }
            // The turn's notify, and the one for the title Codex generates on a side thread.
            try await require("notify \(index)", pane, 15) { recorder.count(of: "agent-turn-complete") == 2 * index }
            await pane.type("/quit")
            await pane.enter()
            _ = await probeWait(10) { pane.screen.contains("codex resume") }
            await pane.close()
        }

        // Shutting the daemon down is what ends the sessions.
        let daemon = try #require(daemonPid(), "no app-server daemon pid")
        daemonSeen = daemon
        kill(daemon, SIGTERM)
        _ = await probeWait(10) { kill(daemon, 0) != 0 && errno == ESRCH }
        _ = await probeWait(5) { recorder.count(of: "SessionEnd") >= 2 }

        if capture == nil {
            for entry in recorder.hookPayloads where entry.payload.eventName != "agent-turn-complete" {
                #expect(entry.ppid == daemon, "\(entry.payload.eventName): parent is not the daemon")
            }
        }

        let adapter = CodexAdapter(supportDirectory: world.support)
        let starts = recorder.hookPayloads.filter { $0.payload.eventName == "SessionStart" }.map(\.payload)
        var transcripts: [(id: String, path: String?, summary: TranscriptSummary?, usage: SessionUsage?)] = []
        for start in starts {
            let conversationId = try #require(start.sessionId)
            let path = adapter.transcript.locate(
                conversationId: conversationId, configDir: codexHome.path, fileManager: .default)
            #expect(path == start.transcriptPath)
            let usage = await adapter.transcript.usage(
                conversationId: conversationId, path: path ?? "",
                reader: TranscriptUsageReader(cacheDirectory: world.root.appending(path: "usage-cache").path))
            transcripts.append((conversationId, path, path.flatMap { try? adapter.transcript.summary(path: $0) }, usage))
        }

        // What trusting wrote: Codex keeps its ledger in config.toml, keyed by hooks.json's path.
        let configText = try String(contentsOf: codexHome.appending(path: "config.toml"), encoding: .utf8)
        #expect(configText.contains("[hooks.state.\"\(codexHome.path)/hooks.json:stop:0:0\"]")
            || configText.contains("[hooks.state.\"\(TraceNormalizer.realPath(codexHome.path))/hooks.json:stop:0:0\"]"))

        var normalizer = world.normalizer
        let trace = render(
            agent: RealAgentProbe.version(of: "\(agentDirectory)/codex"),
            recorder: recorder, adapters: [.codex: adapter], normalizer: &normalizer,
            transcripts: transcripts)
        if let capture {
            try exportFixtures(
                world: world, recorder: recorder, capture: capture, trace: trace,
                extra: [
                    ("hooks.json", codexHome.appending(path: "hooks.json")),
                    ("config.toml", codexHome.appending(path: "config.toml")),
                ],
                notes: transcripts.map { "rollout \(world.fixtureText($0.path ?? "-"))" })
        }
        try compare(trace, golden: "codex.trace", world: world)
    }

    /// The installer's reading of `[features] hooks = false` agrees with Codex's own
    /// (`codex features list`) for each spelling. The installer only reports it; it never writes
    /// the flag, and nothing tells a user to set it to `true`.
    @Test func codexHooksFeatureFlagAgreesWithTheInstaller() throws {
        try #require(RealAgentProbe.networkIsIsolated(), "run inside a network namespace (docs/linux/agents.md)")
        let agentDirectory = try #require(RealAgentProbe.agentDirectory("codex"), "codex is not on PATH")
        let world = try ProbeWorld(label: "codex-features", capture: nil)
        let codexHome = world.home.appending(path: ".codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let installer = CodexHooksInstaller(directory: world.support)
        let variants = [
            "",
            "[features]\nhooks = false\n",
            "[features]\nhooks = true\n",
            "features.hooks = false\n",
            "features = { hooks = false }\n",
            "[features]\n  hooks=false # off for now\n",
            "[features]\nother = false\n[tui]\nhooks = false\n",
        ]
        for text in variants {
            try text.write(to: codexHome.appending(path: "config.toml"), atomically: true, encoding: .utf8)
            let result = try ShimTestSupport.run(
                URL(fileURLWithPath: "\(agentDirectory)/codex"), ["features", "list"],
                environment: ["PATH": "\(agentDirectory):/usr/bin:/bin", "HOME": world.home.path,
                              "CODEX_HOME": codexHome.path])
            let row = result.stdout.split(separator: "\n").first { $0.hasPrefix("hooks ") }
            let codexSaysOff = try #require(row, "no hooks row:\n\(result.stdout)\(result.stderr)").hasSuffix("false")
            #expect(installer.detect(configDir: codexHome.path).hooksFeatureDisabled == codexSaysOff, "\(text)")
        }
        try? FileManager.default.removeItem(at: world.root)
    }

    // MARK: Trace

    private func render(
        agent: String, recorder: ProbeRecorder, adapters: [AgentKind: any AgentAdapter],
        normalizer: inout TraceNormalizer,
        transcripts: [(id: String, path: String?, summary: TranscriptSummary?, usage: SessionUsage?)]
    ) -> String {
        let launches = recorder.launches.map { AgentTrace.launchLine($0, normalizer: &normalizer) }
        let (hooks, notify) = AgentTrace.hookLines(
            frames: recorder.frames, adapters: adapters, normalizer: &normalizer)
        let observations = AgentTrace.collapsed(
            recorder.observations.map { AgentTrace.observationLine($0, normalizer: &normalizer) })
        var seen: Set<String> = []
        let statusline = recorder.statusline.map { AgentTrace.statuslineLine($0, normalizer: &normalizer) }
            .filter { seen.insert($0).inserted }
        var transcriptLines: [String] = []
        for entry in transcripts {
            let conversation = normalizer.id(entry.id, kind: "conversation")
            transcriptLines += AgentTrace.transcriptLines(
                summary: entry.summary, usage: entry.usage, path: entry.path, conversation: conversation,
                normalizer: normalizer)
        }
        var sections: [(name: String, lines: [String])] = [("launch", launches), ("hooks", hooks)]
        if !notify.isEmpty { sections.append(("notify", notify)) }
        if !observations.isEmpty { sections.append(("observation", observations)) }
        if !statusline.isEmpty { sections.append(("statusline", statusline)) }
        sections.append(("transcript", transcriptLines))
        return AgentTrace.render(
            header: [
                "\(agent), recorded by RealAgentProbeTests against fake-model-api.py.",
                "Regenerate: docs/linux/agents.md, Real-agent probe. Comments are not compared.",
            ],
            sections: sections)
    }

    /// Section by section against the golden. A mismatch keeps the run's directory (and says
    /// where); a match removes it.
    private func compare(_ trace: String, golden name: String, world: ProbeWorld) throws {
        let actualFile = world.root.appending(path: name)
        try trace.write(to: actualFile, atomically: true, encoding: .utf8)
        guard let golden = try? String(contentsOf: RealAgentProbe.fixtures.appending(path: name), encoding: .utf8)
        else {
            Issue.record("no golden Fixtures/linux/\(name); this run's trace is \(actualFile.path):\n\(trace)")
            return
        }
        let expected = AgentTrace.sections(of: golden)
        let actual = AgentTrace.sections(of: trace)
        var matched = true
        for section in Set(expected.keys).union(actual.keys).sorted() where actual[section] != expected[section] {
            matched = false
            Issue.record("[\(section)] differs from Fixtures/linux/\(name); this run's trace is \(actualFile.path):\n\(trace)")
        }
        if matched, RealAgentProbe.environment["TKZMUX_REAL_AGENTS_KEEP"] != "1" {
            try? FileManager.default.removeItem(at: world.root)
        }
    }

    // MARK: Capture

    private func lastRaw(_ capture: URL, suffix: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: capture.appending(path: "raw").path)) ?? []
        return names.filter { $0.hasSuffix(suffix) }.sorted().last.map { capture.appending(path: "raw/\($0)") }
    }

    /// Writes `<capture>/fixtures`: every payload the hook received, renamed by event, in the
    /// fixture spelling; the `sequence` that replays them in arrival order; the trace.
    private func exportFixtures(
        world: ProbeWorld, recorder: ProbeRecorder, capture: URL, trace: String,
        extra: [(name: String, source: URL?)], notes: [String]
    ) throws {
        let fileManager = FileManager.default
        let output = capture.appending(path: "fixtures")
        try? fileManager.removeItem(at: output)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        var raw = ((try? fileManager.contentsOfDirectory(atPath: capture.appending(path: "raw").path)) ?? []).sorted()

        func take(_ suffix: String) -> String? {
            guard let index = raw.firstIndex(where: { $0.hasSuffix(suffix) }) else { return nil }
            return raw.remove(at: index)
        }
        func write(_ source: String, as name: String) throws {
            let text = try String(contentsOf: capture.appending(path: "raw/\(source)"), encoding: .utf8)
            try world.fixtureText(text).write(to: output.appending(path: name), atomically: true, encoding: .utf8)
        }

        var panes: [String: String] = [:]
        func pane(_ sid: String?) -> String {
            guard let sid else { return "-" }
            if let known = panes[sid] { return known }
            panes[sid] = "pane-\(panes.count + 1)"
            return panes[sid]!
        }
        var counts: [String: Int] = [:]
        func name(_ base: String, _ ext: String) -> String {
            counts[base, default: 0] += 1
            return counts[base]! == 1 ? "\(base).\(ext)" : "\(base)-\(counts[base]!).\(ext)"
        }

        var sequence: [String] = []
        for frame in recorder.frames {
            switch frame {
            case .launch(let launch):
                guard let source = take("-launch.argv") else { continue }
                let file = name("launch", "argv")
                try write(source, as: file)
                sequence.append("launch \(launch.agent.rawValue) \(pane(launch.rawSid)) \(file)")
            case .hook(let payload, let sid, _, _):
                let notify = payload.eventName == "agent-turn-complete"
                guard let source = take(notify ? "-notify-argv.json" : "-\(payload.eventName).json") else { continue }
                let file = name(notify ? "notify-\(payload.eventName)" : "hook-\(payload.eventName)", "json")
                try write(source, as: file)
                sequence.append(
                    "\(notify ? "notify" : "hook") \(payload.agent.rawValue) \(pane(sid?.rawValue)) \(payload.eventName) \(file)")
            }
        }
        try (sequence.joined(separator: "\n") + "\n")
            .write(to: output.appending(path: "sequence"), atomically: true, encoding: .utf8)
        for (name, source) in extra {
            guard let source, let text = try? String(contentsOf: source, encoding: .utf8) else { continue }
            try world.fixtureText(text).write(to: output.appending(path: name), atomically: true, encoding: .utf8)
        }
        try (notes.joined(separator: "\n") + "\n")
            .write(to: output.appending(path: "paths.txt"), atomically: true, encoding: .utf8)
        try trace.write(to: output.appending(path: "trace"), atomically: true, encoding: .utf8)
    }
}
