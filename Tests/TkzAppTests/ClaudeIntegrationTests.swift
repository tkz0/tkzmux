// ClaudeIntegrationTests — M3 (TKZ-21…TKZ-24): the coordinator that joins hook frames and
// descriptors to sessions and posts derived status into the store.
//
// The first suite feeds synthetic frames straight into the `handle…` methods (no socket, no
// watcher started). The last test starts the real `HookServer` on a short `/tmp` socket path and
// runs the built `tkzmux-hook` binary against it — the whole relay end to end, minus Claude.

import AppKit
import Foundation
import Testing
import ClaudeBridge
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct ClaudeIntegrationTests {

    struct Harness {
        let store: AppStore
        let integration: ClaudeIntegration
        let group: GroupID
        let session: SessionID
        let directory: URL
    }

    static func makeHarness(home: String? = nil) -> Harness {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tkzci-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var state = AppState.startup(homeDirectory: "/tmp/nowhere")
        let group = state.orderedGroups[0].id
        let session = state.createSession(groupID: group, cwd: "/tmp/nowhere", accountKey: "claude")
        state.setLive(LiveSessionState(shellPid: 1, status: .idle), for: session.id)
        state.select(session.id)
        let store = AppStore(state: state)
        let integration = ClaudeIntegration(
            store: store, directory: directory, home: home ?? directory.path, installer: nil)
        return Harness(store: store, integration: integration, group: group, session: session.id, directory: directory)
    }

    static func descriptor(pid: pid_t, sessionId: String = "claude-sid", status: ClaudeSessionInfo.Status,
                           statusUpdatedAt: Date = Date()) -> ClaudeSessionInfo {
        ClaudeSessionInfo(configDir: "/tmp/nowhere/.claude", pid: pid, sessionId: sessionId,
                          status: status, statusUpdatedAt: statusUpdatedAt)
    }

    static func launch(_ id: SessionID, pid: pid_t) -> HookFrame {
        .launch(LaunchAnnouncement(
            sessionID: id, rawSid: id.rawValue, pid: pid, cwd: "/tmp/nowhere",
            configDir: "/tmp/nowhere/.claude", argv: ["--model", "haiku"]))
    }

    // MARK: - Synthetic frames

    @Test("launch binds the pid; a descriptor for that pid then drives the row")
    func launchThenDescriptor() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        #expect(h.store.state.sessions[h.session]?.live?.pid == 4242)
        #expect(h.integration.pidToSession[4242] == h.session)

        h.integration.handle(DescriptorEvent.updated(Self.descriptor(pid: 4242, status: .busy), alive: true))
        let live = h.store.state.sessions[h.session]?.live
        #expect(live?.status == .working)
        #expect(live?.descriptor?.pid == 4242)
        #expect(h.store.state.sessions[h.session]?.claudeSessionId == "claude-sid")
        #expect(h.integration.externalDescriptors.isEmpty)
    }

    @Test("a permission prompt lights NEEDS YOU and a newer busy descriptor clears it")
    func permissionPromptRoundTrip() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        let t0 = Date()
        h.integration.handle(DescriptorEvent.updated(Self.descriptor(pid: 4242, status: .busy, statusUpdatedAt: t0), alive: true))

        let prompt = HookEvent(kind: .notification, sessionID: h.session, claudeSessionId: "claude-sid",
                               notificationType: .permissionPrompt, receivedAt: t0.addingTimeInterval(1))
        h.integration.handle(HookFrame.hook(prompt, ppid: 4242, fullMessage: nil, cwd: nil))
        #expect(h.store.state.sessions[h.session]?.status == .waiting(.permission))
        #expect(h.store.state.sessions[h.session]?.needsAttention == true)
        #expect(h.store.state.summaryCounts.needsYou == 1)

        // Claude's own flag while the prompt is up, then busy again once answered.
        h.integration.handle(DescriptorEvent.updated(Self.descriptor(pid: 4242, status: .waiting, statusUpdatedAt: t0.addingTimeInterval(1)), alive: true))
        #expect(h.store.state.sessions[h.session]?.status == .waiting(.permission))
        h.integration.handle(DescriptorEvent.updated(Self.descriptor(pid: 4242, status: .busy, statusUpdatedAt: Date().addingTimeInterval(5)), alive: true))
        #expect(h.store.state.sessions[h.session]?.status == .working)
        #expect(h.store.state.sessions[h.session]?.needsAttention == false)
    }

    @Test("Stop keeps 4 KiB in the store and the full text in the coordinator")
    func stopMessage() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        h.integration.handle(DescriptorEvent.updated(Self.descriptor(pid: 4242, status: .idle), alive: true))
        let full = String(repeating: "x", count: 10_000)
        let stop = HookEvent(kind: .stop, sessionID: h.session, lastAssistantMessage: String(full.prefix(4096)))
        h.integration.handle(HookFrame.hook(stop, ppid: 4242, fullMessage: full, cwd: nil))
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
        let stop = HookEvent(kind: .stop, sessionID: h.session, lastAssistantMessage: "done")
        h.integration.handle(HookFrame.hook(stop, ppid: 4242, fullMessage: "done", cwd: nil))
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
        let bySid = HookEvent(kind: .stop, sessionID: nil, claudeSessionId: "resumed-sid")
        #expect(h.integration.sessionID(forHook: bySid, ppid: 0) == nil)

        h.store.update { $0.sessions[h.session]?.claudeSessionId = "resumed-sid" }
        #expect(h.integration.sessionID(forHook: bySid, ppid: 0) == h.session)

        // ppid tree: a frame whose ppid *is* a bound claude pid.
        h.integration.handle(Self.launch(h.session, pid: 4242))
        let byTree = HookEvent(kind: .stop, sessionID: nil, claudeSessionId: "unrelated")
        #expect(h.integration.sessionID(forHook: byTree, ppid: 4242) == h.session)
        // A sid that is not in the store must not be trusted over the fallbacks.
        let strangerSid = HookEvent(kind: .stop, sessionID: .generate(), claudeSessionId: "resumed-sid")
        #expect(h.integration.sessionID(forHook: strangerSid, ppid: 0) == h.session)
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

        let discovered = ClaudeIntegration.discoverAccounts(home: home.path)
        #expect(discovered.map(\.key) == ["claude", "claude-home", "claude-work"])
        #expect(discovered.first?.configDir == home.path + "/.claude")
        #expect(discovered.map(\.label) == discovered.map(\.key), "no overlay file: every key is its own label")

        let h = Self.makeHarness(home: home.path)
        // A persisted row on an account the file system does not show is still watched.
        h.store.update { $0.sessions[h.session]?.accountKey = "claude-elsewhere" }
        let integration = ClaudeIntegration(store: h.store, directory: h.directory, home: home.path, installer: nil)
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
        #expect(ClaudeIntegration.accountLabels(home: home.path).isEmpty)

        try Data(#"{"labels": {"claude": "Private", "claude-work": "Day job", "blank": "  "}}"#.utf8)
            .write(to: overlay)
        let labels = ClaudeIntegration.accountLabels(home: home.path)
        #expect(labels == ["claude": "Private", "claude-work": "Day job"], "a blank name is no name")

        let discovered = ClaudeIntegration.discoverAccounts(home: home.path)
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
            #expect(ClaudeIntegration.accountLabels(home: home.path).isEmpty)
        }
        try Data(#"{"labels": {"claude": 7, "claude-work": "Day job"}}"#.utf8).write(to: overlay)
        #expect(ClaudeIntegration.accountLabels(home: home.path) == ["claude-work": "Day job"])
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
        h.integration.handle(DescriptorEvent.updated(info, alive: true))
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
        let hook = HookEvent(kind: .stop, sessionID: h.session, claudeSessionId: "claude-sid")
        #expect(h.integration.sessionID(forHook: hook, ppid: 0) == nil)
        h.integration.handle(HookFrame.hook(hook, ppid: 0, fullMessage: nil, cwd: nil))
        #expect(h.store.state.sessions[h.session]?.live == nil)
    }

    @Test("a descriptor nobody owns is kept as external, and removal forgets it")
    func externalDescriptor() {
        let h = Self.makeHarness()
        let info = Self.descriptor(pid: 99_999, sessionId: "elsewhere", status: .busy)
        h.integration.handle(DescriptorEvent.updated(info, alive: true))
        let key = DescriptorKey(configDir: info.configDir, pid: 99_999)
        #expect(h.integration.externalDescriptors[key]?.info.sessionId == "elsewhere")
        #expect(h.store.state.sessions[h.session]?.status == .idle)
        h.integration.handle(DescriptorEvent.removed(key))
        #expect(h.integration.externalDescriptors[key] == nil)
    }

    @Test("descriptor removal returns the row to a plain shell")
    func descriptorLost() {
        let h = Self.makeHarness()
        h.integration.handle(Self.launch(h.session, pid: 4242))
        h.integration.handle(DescriptorEvent.updated(Self.descriptor(pid: 4242, status: .busy), alive: true))
        #expect(h.store.state.sessions[h.session]?.status == .working)
        h.integration.handle(DescriptorEvent.removed(DescriptorKey(configDir: "/tmp/nowhere/.claude", pid: 4242)))
        let live = h.store.state.sessions[h.session]?.live
        #expect(live?.descriptor == nil)
        #expect(live?.pid == nil)
        #expect(h.store.state.sessions[h.session]?.status == .idle)
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
        h.integration.handle(DescriptorEvent.updated(Self.descriptor(pid: 4242, status: .busy), alive: true))
        // Yield the main actor: the store delivers once per run-loop turn, and a nested
        // `RunLoop.run` inside a main-actor job does not drain the main queue.
        for _ in 0..<20 where deliveries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let last = deliveries.last
        #expect(last?.sessions == [h.session])
        #expect(last?.structure == false)
    }

    // MARK: - The real relay

    @Test("tkzmux-hook → HookServer → store, end to end")
    func realSocketRoundTrip() async throws {
        let binary = try Self.hookBinary()
        // `sun_path` is 104 bytes; NSTemporaryDirectory() is too long for a socket.
        var template = Array("/tmp/tkzci.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw TestFailure.mkdtemp }
        let directory = URL(filePath: String(cString: template), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        var state = AppState.startup(homeDirectory: directory.path)
        let session = state.createSession(groupID: state.orderedGroups[0].id, cwd: directory.path, accountKey: "claude")
        state.setLive(LiveSessionState(shellPid: 1, status: .idle), for: session.id)
        let store = AppStore(state: state)
        let integration = ClaudeIntegration(store: store, directory: directory, home: directory.path, installer: nil)
        integration.start()
        defer { integration.stop() }
        #expect(integration.hookServer.isRunning)

        let payload = #"{"session_id":"abc","hook_event_name":"Stop","last_assistant_message":"hello from the relay"}"#
        let process = Process()
        process.executableURL = binary
        process.arguments = ["Stop"]
        process.environment = [
            "TKZMUX_SOCKET": directory.appending(path: "tkzmux.sock").path,
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
        #expect(live?.lastHook?.kind == .stop)
        #expect(live?.lastHook?.claudeSessionId == "abc")
        #expect(live?.isDone == true)
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
