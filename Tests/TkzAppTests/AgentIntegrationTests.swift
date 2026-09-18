// AgentIntegrationTests — M3 / TKZ-82: the coordinator that joins hook frames and
// observations to sessions and posts derived status into the store, routed through an
// `[AgentKind: any AgentAdapter]` table rather than naming Claude directly.
//
// The first suite feeds synthetic frames straight into the `handle…` methods (no socket, no
// watcher started). Another proves the seam itself: a stub adapter registered alongside Claude's
// routes frames by `payload.agent` with no change to `AgentIntegration`. The last test starts the
// real `HookServer` on a short `/tmp` socket path and runs the built `tkzmux-hook` binary against
// it — the whole relay end to end, minus Claude.

import AppKit
import Foundation
import Synchronization
import Testing
import ClaudeBridge
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct AgentIntegrationTests {

    struct Harness {
        let store: AppStore
        let integration: AgentIntegration
        let group: GroupID
        let session: SessionID
        let directory: URL
        let liveness: FakeLiveness
    }

    /// A process tree as two tables, for the ownership walk and the pid joins. Anything not in
    /// `parents` has no parent, which is what `proc_pidinfo` says about a pid that does not exist.
    struct FakeAncestry: ProcessAncestry {
        var parents: [pid_t: pid_t] = [:]
        var names: [pid_t: String] = [:]
        func parent(of pid: pid_t) -> pid_t? { parents[pid] }
        func name(of pid: pid_t) -> String? { names[pid] }
    }

    /// Reports every pid alive unless a test names it dead. This file's pids (4242, 5000, …) never
    /// correspond to a real process, so a harness that leaves `deadPids` empty must read as "always
    /// alive" — otherwise every test that lets the 5 s tick fire would flake against the liveness
    /// sweep in `tickFired()` rather than exercising what it actually means to test.
    ///
    /// State lives in a `Mutex`, as everywhere else in this codebase — never `@unchecked Sendable`
    /// (CLAUDE.md). The tick calls `isAlive` off the main actor, so the box has to be genuinely
    /// safe rather than asserted to be.
    final class FakeLiveness: ProcessLiveness, Sendable {
        private let storage = Mutex<Set<pid_t>>([])
        var deadPids: Set<pid_t> {
            get { storage.withLock { $0 } }
            set { storage.withLock { $0 = newValue } }
        }
        func markDead(_ pid: pid_t) { storage.withLock { _ = $0.insert(pid) } }
        func isAlive(pid: pid_t, startedAt: Date?) -> Bool { storage.withLock { !$0.contains(pid) } }
    }

    /// The pid every harness integration believes it is; `FakeAncestry` trees end here.
    static let instancePID: pid_t = 777

    static func makeHarness(
        home: String? = nil, shellPid: pid_t = 1, ancestry: FakeAncestry = FakeAncestry(),
        instancePID: pid_t = AgentIntegrationTests.instancePID, liveness: FakeLiveness = FakeLiveness(),
        adapters: [AgentKind: any AgentAdapter] = [.claude: ClaudeAdapter()]
    ) -> Harness {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tkzci-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var state = AppState.startup(homeDirectory: "/tmp/nowhere")
        let group = state.orderedGroups[0].id
        let session = state.createSession(groupID: group, cwd: "/tmp/nowhere", accountKey: "claude")
        state.setLive(LiveSessionState(shellPid: shellPid, status: .idle), for: session.id)
        state.select(session.id)
        let store = AppStore(state: state)
        let integration = AgentIntegration(
            store: store, directory: directory, home: home ?? directory.path, adapters: adapters,
            installer: nil, instancePID: instancePID, ancestry: ancestry, liveness: liveness)
        return Harness(
            store: store, integration: integration, group: group, session: session.id,
            directory: directory, liveness: liveness)
    }

    static func descriptor(pid: pid_t, sessionId: String = "claude-sid", status: ClaudeSessionInfo.Status,
                           statusUpdatedAt: Date = Date()) -> ClaudeSessionInfo {
        ClaudeSessionInfo(configDir: "/tmp/nowhere/.claude", pid: pid, sessionId: sessionId,
                          status: status, statusUpdatedAt: statusUpdatedAt)
    }

    /// `ClaudeSessionWatcher` hands `AgentIntegration` an `ObservationEvent` already projected off
    /// Claude's own descriptor (see `ClaudeAdapter.makeObservationWatcher`); these two wrap that
    /// projection so a test can still hand over a `ClaudeSessionInfo` the way `descriptor(...)`
    /// builds one, rather than constructing an `AgentObservation` by hand everywhere.
    static func apply(_ integration: AgentIntegration, _ info: ClaudeSessionInfo, alive: Bool) {
        integration.handle(.updated(info.observation, alive: alive), from: .claude)
    }

    static func applyRemoved(_ integration: AgentIntegration, _ key: DescriptorKey) {
        integration.handle(.removed(pid: key.pid, configDir: key.configDir), from: .claude)
    }

    static func launch(_ id: SessionID, pid: pid_t) -> HookFrame {
        .launch(LaunchAnnouncement(
            sessionID: id, rawSid: id.rawValue, pid: pid, cwd: "/tmp/nowhere",
            configDir: "/tmp/nowhere/.claude", argv: ["--model", "haiku"]))
    }

    /// A `.hook` frame built from Claude's own wire vocabulary, the way `HookServer` would parse
    /// one off the socket — so a test only ever speaks event names and notification types, never
    /// the `AgentEvent` they map to.
    static func hook(
        _ eventName: String,
        agent: AgentKind = .claude,
        sessionID: SessionID? = nil,
        conversationId: String? = nil,
        notificationType: String? = nil,
        lastAssistantMessage: String? = nil,
        reason: String? = nil,
        transcriptPath: String? = nil,
        ppid: pid_t,
        fullMessage: String? = nil
    ) -> HookFrame {
        let payload = HookPayload(
            agent: agent,
            eventName: eventName,
            sessionId: conversationId,
            transcriptPath: transcriptPath,
            notificationType: notificationType,
            lastAssistantMessage: lastAssistantMessage,
            reason: reason)
        return .hook(payload, sessionID: sessionID, ppid: ppid, fullMessage: fullMessage)
    }

    // MARK: - Synthetic frames

    @Test("launch binds the pid; a descriptor for that pid then drives the row")
    func launchThenDescriptor() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        #expect(h.store.state.sessions[h.session]?.live?.pid == 4242)
        #expect(h.integration.pidToSession[4242] == h.session)

        Self.apply(h.integration, Self.descriptor(pid: 4242, status: .busy), alive: true)
        let live = h.store.state.sessions[h.session]?.live
        #expect(live?.status == .working)
        #expect(live?.observation?.pid == 4242)
        #expect(h.store.state.sessions[h.session]?.conversationId == "claude-sid")
        #expect(h.integration.externalDescriptors.isEmpty)
    }

    @Test("a permission prompt lights NEEDS YOU and a newer busy descriptor clears it")
    func permissionPromptRoundTrip() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        let t0 = Date()
        Self.apply(h.integration, Self.descriptor(pid: 4242, status: .busy, statusUpdatedAt: t0), alive: true)

        h.integration.handle(Self.hook(
            "Notification", sessionID: h.session, conversationId: "claude-sid",
            notificationType: "permission_prompt", ppid: 4242))
        #expect(h.store.state.sessions[h.session]?.status == .waiting(.permission))
        #expect(h.store.state.sessions[h.session]?.needsAttention == true)
        #expect(h.store.state.summaryCounts.needsYou == 1)

        // Claude's own flag while the prompt is up, then busy again once answered.
        Self.apply(h.integration, Self.descriptor(pid: 4242, status: .waiting, statusUpdatedAt: t0.addingTimeInterval(1)), alive: true)
        #expect(h.store.state.sessions[h.session]?.status == .waiting(.permission))
        Self.apply(h.integration, Self.descriptor(pid: 4242, status: .busy, statusUpdatedAt: Date().addingTimeInterval(5)), alive: true)
        #expect(h.store.state.sessions[h.session]?.status == .working)
        #expect(h.store.state.sessions[h.session]?.needsAttention == false)
    }

    @Test("Stop keeps 4 KiB in the store and the full text in the coordinator")
    func stopMessage() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        Self.apply(h.integration, Self.descriptor(pid: 4242, status: .idle), alive: true)
        let full = String(repeating: "x", count: 10_000)
        h.integration.handle(Self.hook(
            "Stop", sessionID: h.session, lastAssistantMessage: String(full.prefix(4096)),
            ppid: 4242, fullMessage: full))
        let session = h.store.state.sessions[h.session]
        #expect(session?.live?.lastStopMessage?.count == 4096)
        #expect(h.integration.lastMessage(for: h.session) == full)
        // Not attended (no window): fresh Stop is idle+done, not yet NEEDS YOU.
        #expect(session?.status == .idle)
        #expect(session?.live?.isDone == true)
    }

    @Test("a Stop on the session the user is looking at is attended immediately")
    func stopWhileAttended() {
        let h = Self.makeHarness()
        h.integration.isSessionAttended = { _ in true }
        h.integration.handle(Self.launch(h.session, pid: 4242))
        h.integration.handle(Self.hook(
            "Stop", sessionID: h.session, lastAssistantMessage: "done", ppid: 4242, fullMessage: "done"))
        let live = h.store.state.sessions[h.session]?.live
        #expect(live?.isDone == false)
        #expect(live?.attendedAt != nil)
        #expect(h.store.state.sessions[h.session]?.status == .idle)
    }

    @Test("a hook without sid falls back to the payload session_id, then to the ppid tree")
    func attributionFallbacks() {
        let h = Self.makeHarness()
        // No launch frame, no descriptor: only the shell pid (1, i.e. launchd — the walk stops there
        // without matching anything else) is known.
        let bySid = AgentEvent(kind: .turnEnded, sessionID: nil, conversationId: "resumed-sid")
        #expect(h.integration.sessionID(forHook: bySid, ppid: 0, agent: .claude) == nil)

        h.store.update { $0.sessions[h.session]?.conversationId = "resumed-sid" }
        #expect(h.integration.sessionID(forHook: bySid, ppid: 0, agent: .claude) == h.session)

        // ppid tree: a frame whose ppid *is* a bound claude pid.
        h.integration.handle(Self.launch(h.session, pid: 4242))
        let byTree = AgentEvent(kind: .turnEnded, sessionID: nil, conversationId: "unrelated")
        #expect(h.integration.sessionID(forHook: byTree, ppid: 4242, agent: .claude) == h.session)
        // A sid that is not in the store must not be trusted over the fallbacks.
        let strangerSid = AgentEvent(kind: .turnEnded, sessionID: .generate(), conversationId: "resumed-sid")
        #expect(h.integration.sessionID(forHook: strangerSid, ppid: 0, agent: .claude) == h.session)
    }

    @Test("accounts are discovered from ~/.claude-* at init, watched, and registered in the store")
    func accountDiscovery() throws {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tkzci-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        try fm.createDirectory(at: home.appending(path: ".claude/sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".claude-work/sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".claude-old"), withIntermediateDirectories: true)  // no markers
        try fm.createDirectory(at: home.appending(path: ".claude-home"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appending(path: ".claude-home/settings.json"))
        try Data().write(to: home.appending(path: ".claude-notadir"))

        let discovered: [Account] = ClaudeAdapter().discoverAccounts(home: home.path)
        #expect(discovered.map(\.key) == ["claude", "claude-home", "claude-work"])
        #expect(discovered.first?.configDir == home.path + "/.claude")
        #expect(discovered.map(\.label) == discovered.map(\.key), "no overlay file: every key is its own label")
        // Every account `discoverAccounts` finds is Claude's — it only ever looks under
        // `~/.claude*` — so each one must carry `.claude`, not whatever `Account.agent`'s default
        // happens to be.
        #expect(discovered.allSatisfy { $0.agent == .claude })

        let h = Self.makeHarness(home: home.path)
        // A persisted row on an account the file system does not show is still watched.
        h.store.update { $0.sessions[h.session]?.accountKey = "claude-elsewhere" }
        // Pinned to Claude alone rather than the default table (TKZ-86): this test is about
        // Claude's own `~/.claude-*` discovery, and must not depend on whether the machine running
        // it happens to have a real `codex` on `PATH`.
        let integration = AgentIntegration(
            store: h.store, directory: h.directory, home: home.path,
            adapters: [.claude: ClaudeAdapter()], installer: nil)
        #expect(Set(h.store.state.accounts.keys) == ["claude", "claude-home", "claude-work", "claude-elsewhere"])
        #expect(Set(integration.watchedConfigDirs) == [
            home.path + "/.claude", home.path + "/.claude-home", home.path + "/.claude-work",
            home.path + "/.claude-elsewhere",
        ])
        #expect(h.store.state.accounts["claude-elsewhere"]?.configDir == home.path + "/.claude-elsewhere")
    }

    /// `~/.claude/dash-accounts.json` is where an account's *name* comes from. Names must never be
    /// spelled out in code (CLAUDE.md), so this is the file that makes the chip read `WORK` instead
    /// of `CW` — and the file is written by another program, so a bad one must cost nothing.
    @Test("accounts take their names from the dash-accounts.json overlay, forgivingly")
    func accountLabelOverlay() throws {
        let fm = FileManager.default
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tkzci-labels-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home.appending(path: ".claude/sessions"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".claude-work/sessions"), withIntermediateDirectories: true)
        let overlay = home.appending(path: ".claude/dash-accounts.json")

        // No file at all: every key is its own label.
        #expect(ClaudeAdapter().accountLabels(home: home.path).isEmpty)

        try Data(#"{"labels": {"claude": "Private", "claude-work": "Day job", "blank": "  "}}"#.utf8)
            .write(to: overlay)
        let labels = ClaudeAdapter().accountLabels(home: home.path)
        #expect(labels == ["claude": "Private", "claude-work": "Day job"], "a blank name is no name")

        let discovered: [Account] = ClaudeAdapter().discoverAccounts(home: home.path)
        #expect(discovered.map(\.key) == ["claude", "claude-work"])
        #expect(discovered.map(\.label) == ["Private", "Day job"])
        // Which is the whole point: the chip stops being an initial.
        var session = Session(groupID: .generate(), cwd: "~", accountKey: "claude-work")
        var state = AppState()
        for account in discovered { state.setAccount(account) }
        state.sessions[session.id] = session
        #expect(SidebarRowAdapter.accountLabel(for: session, in: state) == "DAY")
        #expect(
            SidebarRowAdapter.accountTooltip(for: session, in: state)
                == "Day job (claude-work) \u{2014} \(home.path)/.claude-work")

        // An account the overlay does not mention keeps its key, and a key with no overlay entry
        // still gets a chip from the key itself.
        session.accountKey = "claude-unnamed"
        #expect(SidebarRowAdapter.accountLabel(for: session, in: state) == "UNNAM")

        // A torn write, a wrong shape and a wrong type are each "no overlay", never a crash.
        for bad in [#"{"labels": {"claude": "#, #"{"labels": [1, 2]}"#, #"{}"#, #"not json"#] {
            try Data(bad.utf8).write(to: overlay)
            #expect(ClaudeAdapter().accountLabels(home: home.path).isEmpty)
        }
        try Data(#"{"labels": {"claude": 7, "claude-work": "Day job"}}"#.utf8).write(to: overlay)
        #expect(ClaudeAdapter().accountLabels(home: home.path) == ["claude-work": "Day job"])
    }

    @Test("a launch frame or descriptor from an unknown config dir registers the account and corrects the row")
    func learnAccountFromTheProcess() {
        let h = Self.makeHarness()
        let before = Set(h.integration.watchedConfigDirs)
        #expect(h.store.state.sessions[h.session]?.accountKey == "claude")

        // The shell's environment sent Claude to a second account the app did not ask for.
        let launch = HookFrame.launch(LaunchAnnouncement(
            sessionID: h.session, rawSid: h.session.rawValue, pid: 4242, cwd: "/tmp/nowhere",
            configDir: "/tmp/nowhere/.claude-work/", argv: []))
        h.integration.handle(launch)
        #expect(h.store.state.sessions[h.session]?.accountKey == "claude-work")
        #expect(h.store.state.accounts["claude-work"]?.configDir == "/tmp/nowhere/.claude-work")
        #expect(Set(h.integration.watchedConfigDirs) == before.union(["/tmp/nowhere/.claude-work"]))

        // The descriptor is the final word: it is written where Claude actually keeps the session.
        var info = Self.descriptor(pid: 4242, status: .idle)
        info.configDir = "/tmp/nowhere/.claude-second"
        Self.apply(h.integration, info, alive: true)
        #expect(h.store.state.sessions[h.session]?.accountKey == "claude-second")
        #expect(h.integration.watchedConfigDirs.contains("/tmp/nowhere/.claude-second"))
        // A row on a non-default account gets a chip; a row on `~/.claude` never does.
        let chip = SidebarRowAdapter.accountLabel(for: h.store.state.sessions[h.session]!, in: h.store.state)
        #expect(chip == "SECON")
    }

    @Test("a restored row (no live state) is never an attribution target")
    func deadRowsAreNotTargets() {
        let h = Self.makeHarness()
        h.store.update { $0.setLive(nil, for: h.session) }
        h.integration.handle(Self.launch(h.session, pid: 4242))
        #expect(h.integration.pidToSession[4242] == nil)
        let event = AgentEvent(kind: .turnEnded, sessionID: h.session, conversationId: "claude-sid")
        #expect(h.integration.sessionID(forHook: event, ppid: 0, agent: .claude) == nil)
        h.integration.handle(Self.hook("Stop", sessionID: h.session, conversationId: "claude-sid", ppid: 0))
        #expect(h.store.state.sessions[h.session]?.live == nil)
    }

    /// A payload from an agent nobody has an adapter for — `adapters` here is the default,
    /// Claude-only table — must be dropped and logged rather than attributed to a row by whatever
    /// mapper happens to be in scope, which would misread a vocabulary it does not speak.
    @Test("a hook payload from an unregistered agent is dropped, not attributed")
    func unmappedAgentIsDropped() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        h.integration.handle(Self.hook(
            "Stop", agent: AgentKind(rawValue: "gemini"), sessionID: h.session,
            conversationId: "gemini-sid", lastAssistantMessage: "done", ppid: 4242, fullMessage: "done"))
        #expect(h.store.state.sessions[h.session]?.live?.lastEvent == nil)
        #expect(h.store.state.sessions[h.session]?.live?.lastStopMessage == nil)
    }

    // MARK: - The adapter seam itself

    /// Defined only here, never in `ClaudeBridge` or `TkzApp` — the whole point is that
    /// `AgentIntegration` needs no change to route a second agent's frames, only a second entry in
    /// its `adapters` table.
    private struct StubTranscriptProvider: TranscriptProvider {
        func locate(conversationId: String, configDir: String, fileManager: FileManager) -> String? { nil }
        func summary(path: String) throws -> TranscriptSummary { TranscriptSummary() }
        func usage(conversationId: String, path: String, reader: TranscriptUsageReader) async -> SessionUsage? { nil }
        func searchIndex(path: String, existing: TranscriptIndex?) throws -> TranscriptIndex {
            try TranscriptIndex.build(path: path, existing: existing)
        }
    }

    /// A second, wholly fictitious agent. Its `mapHook` speaks a trivial vocabulary of its own
    /// (every payload is a finished turn) precisely so a test can tell "the stub's mapper ran" apart
    /// from "Claude's mapper ran" — the two would otherwise both produce a plausible `AgentEvent`.
    private struct StubAdapter: AgentAdapter {
        static let kind = AgentKind(rawValue: "stub")
        var kind: AgentKind { Self.kind }
        var displayName: String { "Stub" }
        var binaryName: String { "stub-agent" }
        var capabilities: AgentCapabilities { [.hooks] }

        func launchCommand(_ intent: LaunchIntent) -> String? { "stub-agent" }
        func environment(configDir: String?) -> [String: String] { [:] }
        func discoverAccounts(home: String, fileManager: FileManager) -> [Account] { [] }
        func accountLabels(home: String, fileManager: FileManager) -> [String: String] { [:] }
        func mapHook(_ payload: HookPayload) -> AgentEvent? {
            AgentEvent(kind: .turnEnded, sessionID: nil, conversationId: payload.sessionId)
        }
        func mapTerminalNotification(title: String, body: String) -> AgentEvent? {
            AgentEvent(kind: .turnEnded)
        }
        func makeObservationWatcher(
            configDirs: [String], onEvent: @escaping @Sendable (ObservationEvent) -> Void
        ) -> (any AgentObservationWatcher)? { nil }
        var transcript: any TranscriptProvider { StubTranscriptProvider() }
        var hookInstall: HookInstallStrategy { .perInvocation }
        var shimScript: ShimResource { ShimResource(binaryName: "stub-agent", resourceName: "stub.sh") }
    }

    /// The acceptance criterion for the seam being real: two adapters registered, and a frame routes
    /// to the one named by `payload.agent` — Claude's own mapper for a Claude frame, the stub's for
    /// a stub frame — with no change to `AgentIntegration` beyond the `adapters` argument to
    /// `makeHarness`.
    @Test("frames route to the adapter named by payload.agent, including a stub registered only by the test")
    func framesRouteByPayloadAgent() {
        let h = Self.makeHarness(adapters: [.claude: ClaudeAdapter(), StubAdapter.kind: StubAdapter()])
        h.store.update { state in
            state.sessions[h.session]?.agent = StubAdapter.kind
            state.sessions[h.session]?.conversationId = "stub-conv"
        }

        // The stub's own mapper runs (every payload is a finished turn, whatever the event name),
        // and the fallback join respects the frame's `agent` — a `stub-conv` hook only ever matches
        // a `.stub` row.
        h.integration.handle(Self.hook(
            "AnythingAtAll", agent: StubAdapter.kind, conversationId: "stub-conv", ppid: 0))
        #expect(h.store.state.sessions[h.session]?.live?.lastEvent?.kind == .turnEnded)

        // The same conversation id under Claude's own vocabulary must not cross-attribute: a
        // `Stop` naming `stub-conv` is Claude's event shape, but the row it would join to is a
        // `.stub` row, so the agent-scoped fallback in `sessionID(forHook:ppid:agent:)` refuses it.
        h.store.update { $0.sessions[h.session]?.live?.lastEvent = nil }
        h.integration.handle(Self.hook("Stop", agent: .claude, conversationId: "stub-conv", ppid: 0))
        #expect(h.store.state.sessions[h.session]?.live?.lastEvent == nil)
    }

    // MARK: - Terminal notifications (TKZ-85)

    /// `handleTerminalNotification` is the other half of the seam `framesRouteByPayloadAgent`
    /// proves for hooks: the row's own adapter classifies, and a `nil` — Claude's own answer,
    /// always — leaves the row untouched. `MainWindowController` is what decides *whether* to call
    /// this at all (`paneHostsAgent`); once it does, routing by `session.agent` is this type's job,
    /// exercised here without a window at all.
    @Test("a terminal notification routes to the row's own adapter, and Claude's nil leaves the row alone")
    func terminalNotificationRoutesByAgent() {
        let h = Self.makeHarness(adapters: [.claude: ClaudeAdapter(), StubAdapter.kind: StubAdapter()])
        let terminal = TerminalID(uuid: h.session.uuid)
        h.store.update { $0.sessions[h.session]?.agent = StubAdapter.kind }

        // The stub maps every notification to a finished turn, whatever the title says.
        h.integration.handleTerminalNotification(
            sessionID: h.session, terminal: terminal, title: "anything at all", body: "")
        #expect(h.store.state.sessions[h.session]?.live?.lastEvent?.kind == .turnEnded)

        // Claude's own adapter maps every terminal notification to `nil` (it reports through
        // hooks), so the same call on a Claude row changes nothing.
        h.store.update { state in
            state.sessions[h.session]?.agent = .claude
            state.sessions[h.session]?.live?.lastEvent = nil
        }
        h.integration.handleTerminalNotification(
            sessionID: h.session, terminal: terminal, title: "anything at all", body: "")
        #expect(h.store.state.sessions[h.session]?.live?.lastEvent == nil)
    }

    @Test("a descriptor nobody owns is kept as external, and removal forgets it")
    func externalDescriptor() {
        let h = Self.makeHarness()
        let info = Self.descriptor(pid: 99_999, sessionId: "elsewhere", status: .busy)
        Self.apply(h.integration, info, alive: true)
        let key = DescriptorKey(configDir: info.configDir, pid: 99_999)
        #expect(h.integration.externalDescriptors[key]?.observation.conversationId == "elsewhere")
        #expect(h.store.state.sessions[h.session]?.status == .idle)
        Self.applyRemoved(h.integration, key)
        #expect(h.integration.externalDescriptors[key] == nil)
    }

    // MARK: - Instance ownership (two tkzmux sharing one support directory)

    /// The contract the multi-instance fix rests on: the server listens where the pane's
    /// environment says, for the same pid, and that name is per instance.
    @Test("the hook server and the pty environment agree on the per-instance socket")
    func hookServerAndPtyAgreeOnTheSocket() {
        let h = Self.makeHarness()
        let expected = HookSocket.url(in: h.directory, pid: Self.instancePID)
        #expect(h.integration.hookServer.socketPath.path == expected.path)
        let env = TerminalEnvironment.make(
            sessionID: "x", tkzmuxDir: h.directory, baseEnvironment: ["HOME": h.directory.path],
            home: h.directory.path, instancePID: Self.instancePID)
        #expect(env["TKZMUX_SOCKET"] == expected.path)
        let other = Self.makeHarness(instancePID: 778)
        #expect(other.integration.hookServer.socketPath.path != expected.path)
    }

    @Test("a descriptor under one of our panes joins by conversation id")
    func descriptorUnderOurPaneJoinsByClaudeSessionId() {
        // claude 5000 → pane zsh 4000 → us
        let tree = FakeAncestry(parents: [5000: 4000, 4000: 777, 777: 1], names: [777: "tkzmux"])
        let h = Self.makeHarness(ancestry: tree)
        h.store.update { $0.sessions[h.session]?.conversationId = "claude-sid" }
        Self.apply(h.integration, Self.descriptor(pid: 5000, status: .busy), alive: true)
        let live = h.store.state.sessions[h.session]?.live
        #expect(live?.status == .working)
        #expect(live?.pid == 5000)
        #expect(h.integration.externalDescriptors.isEmpty)
    }

    @Test("a descriptor whose ancestry crosses another tkzmux is external, by either fallback")
    func descriptorAcrossForeignTkzmuxIsExternal() {
        // claude 5000 → dev zsh 4000 → dev tkzmux 900 → our pane zsh 300 → us. The row hosts
        // that dev build (its shell is 300) *and* carries the same conversation id the dev
        // build restored from the shared state.json — both fallbacks would have claimed it.
        let tree = FakeAncestry(
            parents: [5000: 4000, 4000: 900, 900: 300, 300: 777, 777: 1],
            names: [900: "tkzmux", 777: "tkzmux"])
        let h = Self.makeHarness(shellPid: 300, ancestry: tree)
        h.store.update { $0.sessions[h.session]?.conversationId = "claude-sid" }
        let info = Self.descriptor(pid: 5000, status: .busy)
        Self.apply(h.integration, info, alive: true)
        let key = DescriptorKey(configDir: info.configDir, pid: 5000)
        #expect(h.integration.externalDescriptors[key] != nil)
        let live = h.store.state.sessions[h.session]?.live
        #expect(live?.status == .idle)
        #expect(live?.pid == nil)
        #expect(live?.observation == nil)
        // The bare walk refuses too: a hook from that tree with no sid is unattributed.
        let event = AgentEvent(kind: .turnEnded, sessionID: nil, conversationId: "unrelated")
        #expect(h.integration.sessionID(forHook: event, ppid: 5000, agent: .claude) == nil)
    }

    @Test("a descriptor whose ancestry reaches launchd without us is external")
    func descriptorReachingLaunchdIsExternal() {
        // Terminal.app's claude: 5000 → zsh 4000 → Terminal 200 → launchd.
        let tree = FakeAncestry(parents: [5000: 4000, 4000: 200, 200: 1], names: [777: "tkzmux"])
        let h = Self.makeHarness(ancestry: tree)
        h.store.update { $0.sessions[h.session]?.conversationId = "claude-sid" }
        let info = Self.descriptor(pid: 5000, status: .busy)
        Self.apply(h.integration, info, alive: true)
        #expect(h.integration.externalDescriptors[DescriptorKey(configDir: info.configDir, pid: 5000)] != nil)
        #expect(h.store.state.sessions[h.session]?.status == .idle)
    }

    @Test("a launch-bound descriptor is ours whatever its ancestry looks like")
    func launchBoundDescriptorIgnoresAncestry() {
        // The launch frame came over *our* socket; the walk is not consulted.
        let tree = FakeAncestry(parents: [5000: 900, 900: 777], names: [900: "tkzmux", 777: "tkzmux"])
        let h = Self.makeHarness(ancestry: tree)
        h.integration.handle(Self.launch(h.session, pid: 5000))
        Self.apply(h.integration, Self.descriptor(pid: 5000, status: .busy), alive: true)
        #expect(h.store.state.sessions[h.session]?.live?.status == .working)
        #expect(h.integration.externalDescriptors.isEmpty)
    }

    /// The bug report as a test: two instances restore the same row from one `state.json`; the
    /// dev build (888) was started from a pane of the installed one (777) and resumed the row's
    /// conversation. The same descriptor reaches both watchers. Only the dev build may bind it —
    /// the installed one used to, and its row then flipped between two Claudes.
    @Test("two instances sharing a state file do not claim each other's Claude")
    func twoInstancesDoNotClaimEachOthersClaude() {
        // claude 5000 → dev pane zsh 4000 → dev tkzmux 888 → installed pane zsh 300 → installed 777
        let tree = FakeAncestry(
            parents: [5000: 4000, 4000: 888, 888: 300, 300: 777, 777: 1],
            names: [888: "tkzmux", 777: "tkzmux"])
        var shared = AppState.startup(homeDirectory: "/tmp/nowhere")
        let session = shared.createSession(groupID: shared.orderedGroups[0].id, cwd: "/tmp/nowhere", accountKey: "claude")
        shared.sessions[session.id]?.conversationId = "claude-sid"

        var stateA = shared
        stateA.setLive(LiveSessionState(shellPid: 300, status: .idle), for: session.id)
        var stateB = shared
        stateB.setLive(LiveSessionState(shellPid: 4000, status: .idle), for: session.id)
        let storeA = AppStore(state: stateA)
        let storeB = AppStore(state: stateB)
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tkzci-\(UUID().uuidString)", directoryHint: .isDirectory)
        let a = AgentIntegration(store: storeA, directory: directory, home: directory.path, installer: nil,
                                  instancePID: 777, ancestry: tree)
        let b = AgentIntegration(store: storeB, directory: directory, home: directory.path, installer: nil,
                                  instancePID: 888, ancestry: tree)
        #expect(a.hookServer.socketPath.path != b.hookServer.socketPath.path)

        let info = Self.descriptor(pid: 5000, status: .busy)
        Self.apply(a, info, alive: true)
        Self.apply(b, info, alive: true)

        let key = DescriptorKey(configDir: info.configDir, pid: 5000)
        #expect(a.externalDescriptors[key] != nil)
        #expect(storeA.state.sessions[session.id]?.status == .idle)
        #expect(b.externalDescriptors[key] == nil)
        #expect(storeB.state.sessions[session.id]?.status == .working)
        #expect(storeB.state.sessions[session.id]?.live?.pid == 5000)
    }

    @Test("descriptor removal returns the row to a plain shell")
    func descriptorLost() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        Self.apply(h.integration, Self.descriptor(pid: 4242, status: .busy), alive: true)
        #expect(h.store.state.sessions[h.session]?.status == .working)
        Self.applyRemoved(h.integration, DescriptorKey(configDir: "/tmp/nowhere/.claude", pid: 4242))
        let live = h.store.state.sessions[h.session]?.live
        #expect(live?.observation == nil)
        #expect(live?.pid == nil)
        #expect(h.store.state.sessions[h.session]?.status == .idle)
    }

    // MARK: - Liveness poll for rows with no observation

    /// The Codex-shaped gap the tick exists for: a bound launch pid, no descriptor file ever
    /// arrives, and the process dies. Nothing else would ever learn that — there is no descriptor
    /// to lose — so the sweep must ask the liveness fake itself and clean up on a "no".
    @Test("the tick's liveness sweep catches a bound pid with no observation that has died")
    func tickLivenessSweepCatchesADeadRowWithNoObservation() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        #expect(h.store.state.sessions[h.session]?.live?.pid == 4242)
        #expect(h.store.state.sessions[h.session]?.live?.observation == nil)

        var exited: [SessionID] = []
        h.integration.onAgentExited = { exited.append($0) }
        h.liveness.deadPids.insert(4242)
        h.integration.tickFired()

        #expect(exited == [h.session])
        let live = h.store.state.sessions[h.session]?.live
        #expect(live?.pid == nil)
        #expect(live?.observation == nil)
        #expect(h.store.state.sessions[h.session]?.status == .idle)
    }

    /// A row with an observation is the watcher's to lose (`.removed` → `agentLost`), never this
    /// sweep's — so the fake is set up to answer "dead" and the tick must not even ask it.
    @Test("a row with a bound observation is never polled by the tick")
    func tickLivenessSweepSkipsRowsWithAnObservation() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        Self.apply(h.integration, Self.descriptor(pid: 4242, status: .busy), alive: true)
        #expect(h.store.state.sessions[h.session]?.live?.observation != nil)

        var exited: [SessionID] = []
        h.integration.onAgentExited = { exited.append($0) }
        h.liveness.deadPids.insert(4242)
        h.integration.tickFired()

        #expect(exited.isEmpty)
        #expect(h.store.state.sessions[h.session]?.live?.pid == 4242)
        #expect(h.store.state.sessions[h.session]?.status == .working)
    }

    /// The common case: the pid is alive, so the tick must leave the row exactly as it found it.
    @Test("the tick leaves a row with a live pid and no observation untouched")
    func tickLivenessSweepLeavesALiveRowAlone() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        var exited: [SessionID] = []
        h.integration.onAgentExited = { exited.append($0) }
        h.integration.tickFired()
        #expect(exited.isEmpty)
        #expect(h.store.state.sessions[h.session]?.live?.pid == 4242)
    }

    @Test("a status flip is a one-row change, never structural")
    func changeSetGranularity() async throws {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        // Let the launch's own delivery drain first so `last` is the status flip alone.
        try await Task.sleep(for: .milliseconds(20))
        var deliveries: [ChangeSet] = []
        let token = h.store.addObserver { deliveries.append($0) }
        defer { h.store.removeObserver(token) }
        Self.apply(h.integration, Self.descriptor(pid: 4242, status: .busy), alive: true)
        // Yield the main actor: the store delivers once per run-loop turn, and a nested
        // `RunLoop.run` inside a main-actor job does not drain the main queue.
        for _ in 0..<20 where deliveries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let last = deliveries.last
        #expect(last?.sessions == [h.session])
        #expect(last?.structure == false)
    }

    // MARK: - Transcript summary (design 2c.5)

    /// A two-line synthetic transcript: one typed prompt, one `away_summary` stamped `summaryAt`.
    private static func writeTranscript(summaryAt: Date) throws -> URL {
        let dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tkzci-transcript-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = summaryAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Fix the build"},"timestamp":"2026-09-10T08:00:00.000Z"}"#,
            #"{"type":"system","subtype":"away_summary","content":"Goal was the build; it is green. Next: ship.","timestamp":"\#(stamp)"}"#,
        ]
        let url = dir.appending(path: "t.jsonl", directoryHint: .notDirectory)
        try Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: url)
        return url
    }

    private static func load(_ h: Harness) async -> TranscriptSummary {
        await withCheckedContinuation { continuation in
            h.integration.loadTranscriptSummary(for: h.session) { continuation.resume(returning: $0) }
        }
    }

    /// The hook's Stop message is newer than an `away_summary` written before it, so it wins
    /// until Claude's next summary lands; a summary newer than the Stop is the considered recap
    /// and wins back. A row with no transcript at all still gets the Stop message as its recap.
    @Test("the recap merges the transcript's away_summary with the hook's Stop message by age")
    func transcriptSummaryMerge() async throws {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))

        // No transcript, no Stop: nothing.
        #expect(await Self.load(h).isEmpty)

        // No transcript, a Stop: the Stop message is the recap.
        h.integration.handle(Self.hook(
            "Stop", sessionID: h.session, lastAssistantMessage: "Done, tests green.",
            ppid: 4242, fullMessage: "Done, tests green."))
        var summary = await Self.load(h)
        #expect(summary.recap == "Done, tests green.")
        #expect(summary.recapSource == .stopMessage)
        #expect(summary.firstPrompt == nil)

        // A transcript whose away_summary predates the Stop: the Stop still wins, the prompt is read.
        let older = try Self.writeTranscript(summaryAt: Date().addingTimeInterval(-600))
        defer { try? FileManager.default.removeItem(at: older.deletingLastPathComponent()) }
        h.integration.transcriptPaths[h.session] = older.path
        summary = await Self.load(h)
        #expect(summary.firstPrompt == "Fix the build")
        #expect(summary.recapSource == .stopMessage)
        #expect(h.integration.cachedTranscriptSummary(for: h.session) == summary)

        // A newer away_summary: Claude's own recap wins back.
        let newer = try Self.writeTranscript(summaryAt: Date().addingTimeInterval(600))
        defer { try? FileManager.default.removeItem(at: newer.deletingLastPathComponent()) }
        h.integration.transcriptPaths[h.session] = newer.path
        summary = await Self.load(h)
        #expect(summary.recapSource == .awaySummary)
        #expect(summary.recap?.hasPrefix("Goal was the build") == true)

        // The path came from the hook frame, and the fallback locates by conversationId.
        h.integration.handle(Self.hook(
            "Stop", sessionID: h.session, lastAssistantMessage: "Done, tests green.",
            transcriptPath: "/tmp/from-hook.jsonl", ppid: 4242))
        #expect(h.integration.transcriptPath(for: h.session) == "/tmp/from-hook.jsonl")
        h.integration.forget(h.session)
        #expect(h.integration.transcriptPath(for: h.session) == nil, "no path, no conversationId → nothing to locate")
    }

    // MARK: - The real relay

    @Test("tkzmux-hook → HookServer → store, end to end")
    func realSocketRoundTrip() async throws {
        let binary = try Self.hookBinary()
        // `sun_path` is 104 bytes; NSTemporaryDirectory() is too long for a socket.
        var template = Array("/tmp/tkzci.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw TestFailure.mkdtemp }
        let path = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let directory = URL(filePath: path, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        var state = AppState.startup(homeDirectory: directory.path)
        let session = state.createSession(groupID: state.orderedGroups[0].id, cwd: directory.path, accountKey: "claude")
        state.setLive(LiveSessionState(shellPid: 1, status: .idle), for: session.id)
        let store = AppStore(state: state)
        let integration = AgentIntegration(store: store, directory: directory, home: directory.path, installer: nil)
        integration.start()
        defer { integration.stop() }
        #expect(integration.hookServer.isRunning)

        let payload = #"{"session_id":"abc","hook_event_name":"Stop","last_assistant_message":"hello from the relay"}"#
        let process = Process()
        process.executableURL = binary
        process.arguments = ["Stop"]
        process.environment = [
            "TKZMUX_SOCKET": integration.hookServer.socketPath.path,
            "TKZMUX_SESSION_ID": session.id.rawValue,
            "HOME": directory.path,
        ]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let deadline = Date().addingTimeInterval(3)
        while store.state.sessions[session.id]?.live?.lastStopMessage == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))  // yields the main actor for the hop
        }
        let live = store.state.sessions[session.id]?.live
        #expect(live?.lastStopMessage == "hello from the relay")
        #expect(live?.lastEvent?.kind == .turnEnded)
        #expect(live?.lastEvent?.conversationId == "abc")
        #expect(live?.isDone == true)
    }

    // MARK: - Default adapter table (TKZ-86)

    /// A machine with no `codex` anywhere on `PATH` must end up with exactly today's table — a
    /// Claude-only user's behaviour must not change just because this build now knows how to talk
    /// to a second agent it has never seen installed.
    @Test("the default adapter table is Claude-only when codex is not on PATH")
    func defaultAdaptersWithoutCodexOnPathMatchesToday() throws {
        let emptyBin = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentIntegrationTests-empty-bin-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: emptyBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: emptyBin) }

        let table = AgentIntegration.defaultAdapters(
            supportDirectory: FileManager.default.temporaryDirectory, path: emptyBin)
        #expect(Set(table.keys) == [.claude])
    }

    /// The other half of the same gate: once `codex` is reachable, the table grows to include it —
    /// proving the table really is conditional and not just always-Claude-only in disguise.
    @Test("the default adapter table adds Codex once codex is on PATH")
    func defaultAdaptersWithCodexOnPathIncludesCodex() throws {
        let bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentIntegrationTests-codex-bin-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: bin) }
        let binary = (bin as NSString).appendingPathComponent("codex")
        FileManager.default.createFile(atPath: binary, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)

        let table = AgentIntegration.defaultAdapters(
            supportDirectory: FileManager.default.temporaryDirectory, path: bin)
        #expect(Set(table.keys) == [.claude, .codex])
    }

    enum TestFailure: Error { case mkdtemp, binaryNotFound }

    /// The built `tkzmux-hook` next to the test bundle (the products directory). Under
    /// `swift test`'s out-of-process runner `Bundle.allBundles` has no `.xctest`, so the bundle
    /// path is taken from the `--test-bundle-path` argument instead (same trick as
    /// `HookBinaryTests`).
    static func hookBinary() throws -> URL {
        var candidates: [URL] = []
        if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appending(path: "tkzmux-hook"))
        }
        for arg in ProcessInfo.processInfo.arguments {
            guard let range = arg.range(of: ".xctest") else { continue }
            let bundlePath = String(arg[..<range.upperBound])
            candidates.append(URL(filePath: bundlePath).deletingLastPathComponent().appending(path: "tkzmux-hook"))
        }
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) { return url }
        throw TestFailure.binaryNotFound
    }
}
