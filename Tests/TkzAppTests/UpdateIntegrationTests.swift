// UpdateIntegrationTests — the coordinator between the check, the store and the card (TKZ-50).
//
// Everything injected: a canned transport, a fake brew, a clock. The wall-clock timer is armed
// (15 s out) but every test stops the integration long before it fires.

import AppKit
import Foundation
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct UpdateIntegrationTests {
    static let feed = URL(string: "https://example.invalid/latest")!

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    struct Fixture {
        let store: AppStore
        let integration: UpdateIntegration
        let clock: Clock
        let fake: FakeCommandRunner
        var opened: [URL] { openedBox.urls }
        let openedBox: OpenedBox

        final class OpenedBox { var urls: [URL] = [] }
    }

    static func make(
        tag: String = "v9.9.9",
        status: Int? = 200,
        running: String = "0.7.0",
        scripted: [FakeCommandRunner.Scripted] = [],
        bundleURL: URL = URL(fileURLWithPath: "/nonexistent/tkzmux.app")
    ) -> Fixture {
        let body = try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": "https://example.invalid/\(tag)"])
        let checker = UpdateChecker(feedURL: feed, running: running, environment: [:]) { _ in (body, status) }
        let clock = Clock()
        let store = AppStore(state: .fixture)
        let fake = FakeCommandRunner(scripted)
        let capability = UpgradeCapability(brewPath: "/nonexistent/brew", caskroomPresent: true, isStandardInstall: true)
        let runner = UpgradeRunner(
            capability: capability, runner: fake,
            runningVersion: AppVersion(marketingVersion: running, build: "1", ghosttyCommit: "x"),
            bundleURL: bundleURL,
            logURL: FileManager.default.temporaryDirectory.appending(path: "tkzmux-\(UUID().uuidString).log"),
            queue: DispatchQueue(label: "test.update.integration"))
        let integration = UpdateIntegration(store: store, checker: checker, capability: capability, runner: runner, now: { clock.now })
        let box = Fixture.OpenedBox()
        integration.openURL = { box.urls.append($0) }
        integration.revealLog = { box.urls.append($0) }
        return Fixture(store: store, integration: integration, clock: clock, fake: fake, openedBox: box)
    }

    static func settle(until done: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("start publishes the capability; a check posts the release into the store")
    func checkPostsRelease() async throws {
        let f = Self.make()
        defer { f.integration.stop() }
        #expect(!f.store.state.update.canUpgradeInPlace)
        f.integration.start()
        f.store.flush()
        #expect(f.store.state.update.canUpgradeInPlace)
        #expect(f.integration.lastCheckedAt == nil)

        f.integration.check()
        #expect(f.integration.lastCheckedAt == f.clock.now)
        try await Self.settle { f.store.state.update.available != nil }
        f.store.flush()
        #expect(f.store.state.visibleUpdate == AvailableUpdate(version: "9.9.9", releaseURL: "https://example.invalid/v9.9.9"))
    }

    @Test("Up to date clears; unreachable keeps the last answer")
    func clearAndHold() {
        let f = Self.make()
        let update = AvailableUpdate(version: "9.9.9", releaseURL: "x")
        f.store.update { $0.setAvailableUpdate(update) }
        f.integration.apply(.unreachable)
        f.store.flush()
        #expect(f.store.state.update.available == update)
        f.integration.apply(.upToDate)
        f.store.flush()
        #expect(f.store.state.update.available == nil)
        f.integration.apply(.available(update))
        f.store.flush()
        #expect(f.store.state.update.available == update)
    }

    @Test("checkIfStale asks again only once the interval has passed")
    func staleness() async throws {
        let f = Self.make()
        defer { f.integration.stop() }
        f.integration.start()
        // Before the first scheduled check nothing is stale: the launch timer owns it.
        f.integration.checkIfStale()
        #expect(f.integration.lastCheckedAt == nil)

        f.integration.check()
        try await Self.settle { f.store.state.update.available != nil }
        let first = try #require(f.integration.lastCheckedAt)
        f.clock.now = first.addingTimeInterval(UpdateIntegration.checkInterval - 1)
        f.integration.checkIfStale()
        #expect(f.integration.lastCheckedAt == first)
        f.clock.now = first.addingTimeInterval(UpdateIntegration.checkInterval + 1)
        f.integration.checkIfStale()
        #expect(f.integration.lastCheckedAt == f.clock.now)
    }

    @Test("Nothing happens before start or after stop")
    func lifecycle() {
        let f = Self.make()
        f.integration.check()
        #expect(f.integration.lastCheckedAt == nil)
        f.integration.start()
        f.integration.stop()
        f.integration.check()
        #expect(f.integration.lastCheckedAt == nil)
        f.integration.stop()   // idempotent
    }

    @Test("Card actions: release page and log open through the injected openers")
    func openers() {
        let f = Self.make()
        defer { f.integration.stop() }
        f.integration.start()
        f.integration.perform(.openReleasePage)
        #expect(f.opened == [URL(string: UpdateChecker.releasesPageURL)!])
        f.store.update { $0.setAvailableUpdate(AvailableUpdate(version: "9.9.9", releaseURL: "https://example.invalid/v9.9.9")) }
        f.integration.perform(.openReleasePage)
        #expect(f.opened.last == URL(string: "https://example.invalid/v9.9.9"))
        f.integration.perform(.showLog)
        #expect(f.opened.last == f.integration.runner.logURL)
    }

    @Test("Upgrade runs the fake brew and mirrors its phases into the store; restart asks the window")
    func upgradeAndRestart() async throws {
        let f = Self.make(scripted: [
            .init(result: UpdateCommandResult(status: 0)),
            .init(result: UpdateCommandResult(status: 0)),
        ])
        defer { f.integration.stop() }
        f.integration.start()
        var restartRequests: [String] = []
        f.integration.onRestartRequested = { restartRequests.append($0) }

        f.integration.perform(.upgrade)
        try await Self.settle { !f.integration.runner.phase.isRunning }
        f.store.flush()
        // The bundle path does not exist, so the plist is "unchanged": not in Homebrew yet.
        #expect(f.store.state.update.phase == .notInHomebrewYet)
        #expect(f.fake.ran.count == 2)

        // Restart is only meaningful once something was installed.
        f.integration.perform(.restart)
        #expect(restartRequests.isEmpty)
        f.store.update { $0.setUpgradePhase(.restartReady(installed: "9.9.9")) }
        f.integration.perform(.restart)
        #expect(restartRequests == ["9.9.9"])

        // A dismissed card reset the store to idle while the runner still remembers its outcome:
        // the next click re-syncs the runner and runs brew again rather than doing nothing.
        f.store.update { $0.setUpgradePhase(.idle) }
        f.integration.perform(.upgrade)
        try await Self.settle { !f.integration.runner.phase.isRunning }
        // The fake had nothing scripted for a third call, so the update step "fails to launch"
        // and the upgrade step never follows: three runs, and a failure the card can show.
        #expect(f.fake.ran.count == 3)
        f.store.flush()
        #expect(f.store.state.update.phase == .failed(reason: "Could not run brew: unscripted call"))
    }

    @Test("An upgrade that lands asks for the restart by itself, once, after the store knows")
    func autoRestart() async throws {
        let bundle = try UpgradeRunnerTests.TempBundle()
        defer { bundle.remove() }
        bundle.writePlist(version: "0.7.0", build: "300")
        let f = Self.make(
            scripted: [
                .init(result: UpdateCommandResult(status: 0)),
                .init(result: UpdateCommandResult(status: 0), sideEffect: { bundle.writePlist(version: "9.9.9", build: "310") }),
            ],
            bundleURL: bundle.app)
        defer { f.integration.stop() }
        f.integration.start()
        var restartRequests: [String] = []
        var phaseAtRequest: [UpgradePhase] = []
        f.integration.onRestartRequested = { installed in
            f.store.flush()
            restartRequests.append(installed)
            phaseAtRequest.append(f.store.state.update.phase)
        }

        f.integration.perform(.upgrade)
        try await Self.settle { !restartRequests.isEmpty }
        // No click on the card: the finished upgrade is the request. The store already says so,
        // so the card reads "Update installed" should the relaunch not happen.
        #expect(restartRequests == ["9.9.9"])
        #expect(phaseAtRequest == [.restartReady(installed: "9.9.9")])

        // Nothing else fires it again — and the card's fallback link still works.
        try await Task.sleep(for: .milliseconds(50))
        #expect(restartRequests.count == 1)
        f.integration.perform(.restart)
        #expect(restartRequests == ["9.9.9", "9.9.9"])
    }
}

// MARK: - Restart confirmation (window controller side)

@MainActor
@Suite(.serialized)
struct UpdateRelaunchTests {
    @Test("Declining never relaunches; accepting hands the plan over with our pid and bundle")
    func confirmThenPerform() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        var asked: [RelaunchPlan] = []
        var performed: [RelaunchPlan] = []
        controller.performRelaunch = { performed.append($0) }

        controller.confirmRestartForUpdate = { plan in asked.append(plan); return false }
        controller.restartForUpdate(installed: "9.9.9")
        #expect(asked.count == 1)
        #expect(performed.isEmpty)

        controller.confirmRestartForUpdate = { plan in asked.append(plan); return true }
        controller.restartForUpdate(installed: "9.9.9")
        let plan = try #require(performed.first)
        #expect(plan.pid == getpid())
        #expect(plan.bundlePath == Bundle.main.bundlePath)
        let live = harness.store.state.sessions.values.filter { $0.live != nil }.count
        #expect(plan.liveSessionCount == live)
        #expect(asked.last == plan)
    }

    @Test("With no veto injected the relaunch is unconditional: no dialog, straight to the plan")
    func noDialogByDefault() throws {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        let controller = harness.controller
        var performed: [RelaunchPlan] = []
        controller.performRelaunch = { performed.append($0) }
        controller.confirmRestartForUpdate = nil
        controller.restartForUpdate(installed: "9.9.9")
        let plan = try #require(performed.first)
        #expect(plan.pid == getpid())
        #expect(plan.bundlePath == Bundle.main.bundlePath)
    }

    @Test("The waiter script polls our pid and opens — never `open -n`, never an exec of the binary")
    func script() {
        let script = RelaunchPlan.script
        #expect(script.contains("kill -0 \"$1\""))
        #expect(script.contains("exec /usr/bin/open \"$2\""))
        #expect(!script.contains("open -n"))
        #expect(!script.contains("Contents/MacOS"))
    }
}
