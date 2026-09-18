// TerminalNotificationTests — TKZ-85: an OSC 9 desktop notification arriving through our pty
// becomes status evidence, but only when it lands in the pane actually running the agent.
//
// The window's job (`MainWindowController.handle(_:for:)`) is the gate: `paneHostsAgent` decides
// whether a `.notification` event is even forwarded. `AgentIntegration.handleTerminalNotification`
// does the classification, through the row's own adapter — exactly the seam `AgentIntegrationTests`
// proves for hook frames, reused here for the other channel an agent can report through.
//
// The window is built by `MainWindowControllerTests.makeSplitHarness` and never ordered front —
// see that file's header for why a visible test window is a real bug here, not a style nit.

import AppKit
import AgentBridge
import Foundation
import Testing
import TkzCore
import TkzTerminalCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct TerminalNotificationTests {

    // MARK: - A fictitious agent, classifying two words

    /// Maps a title containing "approval" to a permission prompt and one containing "done" to a
    /// finished turn — just enough vocabulary to prove the routing without borrowing a real
    /// agent's wire format. Everything else about the adapter is inert, matching the other stub
    /// adapters in this target (`AgentIntegrationTests.StubAdapter`, `NewSessionMenuTests`).
    private struct StubAdapter: AgentAdapter {
        static let kind = AgentKind(rawValue: "notif-stub")
        var kind: AgentKind { Self.kind }
        var displayName: String { "Stub" }
        var binaryName: String { "notif-stub" }
        var capabilities: AgentCapabilities { [.hooks] }

        func launchCommand(_ intent: LaunchIntent) -> String? { nil }
        func environment(configDir: String?) -> [String: String] { [:] }
        func discoverAccounts(home: String, fileManager: FileManager) -> [Account] { [] }
        func accountLabels(home: String, fileManager: FileManager) -> [String: String] { [:] }
        func mapHook(_ payload: HookPayload) -> AgentEvent? { nil }
        func mapTerminalNotification(title: String, body: String) -> AgentEvent? {
            if title.contains("approval") { return AgentEvent(kind: .attention(.permission)) }
            if title.contains("done") { return AgentEvent(kind: .turnEnded) }
            return nil
        }
        func makeObservationWatcher(
            configDirs: [String], onEvent: @escaping @Sendable (ObservationEvent) -> Void
        ) -> (any AgentObservationWatcher)? { nil }
        var transcript: any TranscriptProvider { StubTranscriptProvider() }
        var hookInstall: HookInstallStrategy { .perInvocation }
        var shimScript: ShimResource { ShimResource(binaryName: binaryName, resourceName: "notif-stub.sh") }
    }

    private struct StubTranscriptProvider: TranscriptProvider {
        func locate(conversationId: String, configDir: String, fileManager: FileManager) -> String? { nil }
        func summary(path: String) throws -> TranscriptSummary { TranscriptSummary() }
        func usage(conversationId: String, path: String, reader: TranscriptUsageReader) async -> SessionUsage? { nil }
        func searchIndex(path: String, existing: TranscriptIndex?) throws -> TranscriptIndex {
            fatalError("not used by TerminalNotificationTests")
        }
    }

    // MARK: - Harness

    /// A row with a shell, split into two panes, with a live observation bound to `agentPane` —
    /// the minimum `Session.paneHostsAgent` needs to say yes for that one pane and no for the
    /// other. `AgentIntegration` is wired to `harness.controller.agents` the same way
    /// `AppDelegate` wires the real one, so the whole path under test runs exactly as the app does:
    /// `host.emit` → `MainWindowController.handle(_:for:)` → `AgentIntegration.handleTerminalNotification`.
    private struct Rig {
        let harness: MainWindowControllerTests.Harness
        let integration: AgentIntegration
        let session: SessionID
        let agentPane: TerminalID
        let otherPane: TerminalID
    }

    private static func makeRig(agent: AgentKind = StubAdapter.kind) -> Rig {
        let harness = MainWindowControllerTests.makeSplitHarness()
        let id = harness.store.state.orderedSessions[0].id
        let first = TerminalID(uuid: id.uuid)
        _ = try! harness.host.openRow(id)
        harness.mutate {
            $0.setLive(LiveSessionState(shellPid: 1, status: .idle), for: id)
            $0.select(id)
        }
        var second: TerminalID?
        harness.store.updating { second = $0.splitPane(first, axis: .horizontal) }
        harness.store.flush()
        harness.layout()
        let other = second!

        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tkzci-notif-\(UUID().uuidString)", directoryHint: .isDirectory)
        let integration = AgentIntegration(
            store: harness.store, directory: directory, home: directory.path,
            adapters: [.claude: ClaudeAdapter(), StubAdapter.kind: StubAdapter()], installer: nil)
        harness.controller.agents = integration

        harness.store.update { state in
            state.sessions[id]?.agent = agent
            // A live, alive observation bound to `first` is what makes `paneHostsAgent(first)`
            // true and `paneHostsAgent(other)` false — the split's shell pane hosts no agent.
            // `activity` is left `nil` (no evidence either way) rather than `.busy`: a busy
            // observation would outrank a `turnEnded` notification in `StatusDerivation`'s table
            // and mask exactly the effect `turnEndedNotificationSetsLastStopAt` is checking for.
            state.applyObservation(
                AgentObservation(pid: 4242, conversationId: "conv", configDir: "/tmp/nowhere/.stub"),
                alive: true, to: id)
            state.setAgentTerminal(id, first)
        }
        harness.store.flush()

        return Rig(harness: harness, integration: integration, session: id, agentPane: first, otherPane: other)
    }

    /// How long to wait for something that *should* happen.
    ///
    /// The event travels through `SpyTerminalHost`'s `AsyncStream` and a consuming `Task`, so it
    /// never lands in the same run-loop turn as `emit` (`MainWindowLaunchTests.pwdEventRetitlesTheRow`
    /// is the same shape for the same reason). That consuming task runs on the main actor, which
    /// every other `@MainActor` suite in this target contends for — Swift Testing runs suites in
    /// parallel — so the wait has to cover scheduling, not just the handful of hops it measures.
    ///
    /// Generous on purpose, and it costs nothing: `settle` returns the moment the predicate holds.
    /// At two seconds this failed intermittently in full runs and passed every time in isolation
    /// and under `--no-parallel`, which is the signature of contention rather than a broken path.
    /// Note that raising a bound is *not* the right answer to every such failure — the prompt
    /// card's watch had the same signature and was a real starvation bug that no timeout fixed.
    /// The difference is that this work genuinely belongs on the main actor and will run once
    /// scheduled; that work had no business being on the main queue at all.
    private static let settleTimeout: Duration = .seconds(15)

    /// How long to wait before concluding something did *not* happen.
    ///
    /// Short by necessity: a negative wait burns its whole budget every time, so the generous bound
    /// above would add a minute to this suite. Asserting an absence is always a bounded claim — the
    /// guarantee is "not within this window", not "never".
    private static let quietTimeout: Duration = .seconds(1)

    /// Polls a condition, flushing the store each turn.
    private static func settle(
        _ rig: Rig, timeout: Duration = settleTimeout, until predicate: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            rig.harness.store.flush()
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        rig.harness.store.flush()
        return predicate()
    }

    /// Drains for a short while and confirms the predicate never became true — the negative form.
    private static func staysQuiet(_ rig: Rig, whileNot predicate: () -> Bool) async {
        _ = await settle(rig, timeout: quietTimeout, until: predicate)
    }

    // MARK: - Tests

    @Test("a notification in the agent's own pane flips the row to NEEDS YOU")
    func notificationInOwnPaneLightsNeedsYou() async {
        let rig = Self.makeRig()
        defer { rig.harness.tearDown() }

        rig.harness.host.emit(.notification(title: "approval needed", body: "Bash"), forTerminal: rig.agentPane)
        let settled = await Self.settle(rig) {
            rig.harness.store.state.sessions[rig.session]?.status == .waiting(.permission)
        }
        #expect(settled)
        #expect(rig.harness.store.state.sessions[rig.session]?.needsAttention == true)
    }

    @Test("the same notification in a split shell pane of the same row is ignored")
    func notificationInSplitShellPaneIsIgnored() async {
        let rig = Self.makeRig()
        defer { rig.harness.tearDown() }

        rig.harness.host.emit(.notification(title: "approval needed", body: "Bash"), forTerminal: rig.otherPane)
        // There is nothing to settle *into* — the assertion is that two seconds of draining the
        // store never produces the flip a same-pane notification would.
        await Self.staysQuiet(rig) { false }

        #expect(rig.harness.store.state.sessions[rig.session]?.status != .waiting(.permission))
        #expect(rig.harness.store.state.sessions[rig.session]?.needsAttention == false)
        #expect(rig.harness.store.state.sessions[rig.session]?.live?.lastEvent == nil)
    }

    @Test("a notification on a row whose agent has no adapter is ignored")
    func notificationWithNoAdapterIsIgnored() async {
        let rig = Self.makeRig(agent: AgentKind(rawValue: "nobody-home"))
        defer { rig.harness.tearDown() }

        rig.harness.host.emit(.notification(title: "approval needed", body: "Bash"), forTerminal: rig.agentPane)
        await Self.staysQuiet(rig) { false }

        #expect(rig.harness.store.state.sessions[rig.session]?.needsAttention == false)
        #expect(rig.harness.store.state.sessions[rig.session]?.live?.lastEvent == nil)
    }

    @Test("a .turnEnded mapping sets lastStopAt, exactly as a hook's Stop does")
    func turnEndedNotificationSetsLastStopAt() async {
        let rig = Self.makeRig()
        defer { rig.harness.tearDown() }

        rig.harness.host.emit(.notification(title: "done for now", body: ""), forTerminal: rig.agentPane)
        let settled = await Self.settle(rig) {
            rig.harness.store.state.sessions[rig.session]?.live?.lastEvent?.kind == .turnEnded
        }
        #expect(settled)
        let live = rig.harness.store.state.sessions[rig.session]?.live
        #expect(live?.lastStopAt != nil)
        #expect(live?.isDone == true, "the done tint follows an unattended turnEnded exactly as it does for a hook")
    }

    @Test("the Claude adapter maps a terminal notification to nil, so a Claude row is unaffected")
    func claudeRowIsUnaffected() async {
        let rig = Self.makeRig(agent: .claude)
        defer { rig.harness.tearDown() }

        rig.harness.host.emit(.notification(title: "approval needed", body: "Bash"), forTerminal: rig.agentPane)
        await Self.staysQuiet(rig) { false }

        #expect(rig.harness.store.state.sessions[rig.session]?.needsAttention == false)
        #expect(rig.harness.store.state.sessions[rig.session]?.live?.lastEvent == nil)
    }

    @Test(".bell changes nothing — a bare BEL is not evidence about an agent")
    func bellChangesNothing() async {
        let rig = Self.makeRig()
        defer { rig.harness.tearDown() }

        rig.harness.host.emit(.bell, forTerminal: rig.agentPane)
        await Self.staysQuiet(rig) { false }

        #expect(rig.harness.store.state.sessions[rig.session]?.needsAttention == false)
        #expect(rig.harness.store.state.sessions[rig.session]?.live?.lastEvent == nil)
    }
}
