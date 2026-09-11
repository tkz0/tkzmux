// UpdateIntegration — the app-side coordinator for the update card (design 2c.1, TKZ-50).
//
// The same shape as `ClaudeIntegration` and `GitIntegration`: two services that know one thing
// each — `UpdateChecker` (is there a newer release?) and `UpgradeRunner` (run brew, read the
// plist) — and one place that posts their facts into the store, so the sidebar stays a pure
// function of `AppState` and the services stay testable without a store.
//
// Cadence: the first check 15 s after launch, then every 4 h on a **wall-clock** timer — a
// `.now()`-based dispatch deadline does not advance while the Mac sleeps, and "the app has been
// running for days" is precisely the laptop-that-sleeps-nightly case — plus a check on wake and
// on activation whenever the last one is older than the interval. A failed check changes nothing
// (`.unreachable`); an up-to-date answer *clears* the card, so a withdrawn release goes away.
//
// Only release builds check (`AppVersion.isRelease`), unless `TKZMUX_UPDATE_URL` names a feed —
// the switch a dev build uses to see the card against a fixture. `swift test` has no bundle and
// therefore no release version, so nothing here runs under test unless a test asks.

import AppKit
import Foundation
import TkzCore
import os

@MainActor
public final class UpdateIntegration {
    public static let checkInterval: TimeInterval = 4 * 3600
    public static let firstCheckDelay: TimeInterval = 15

    public let store: AppStore
    public let checker: UpdateChecker
    public let runner: UpgradeRunner

    /// Injected so the tests do not open a browser or a Finder window.
    public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    public var revealLog: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// The upgrade just finished, or the card's fallback "Restart to update" was clicked: the
    /// window controller relaunches. Clicking "Update via Homebrew" was the consent (decision
    /// 2026-09-11), so no second click and no dialog stand between brew finishing and the restart.
    public var onRestartRequested: ((String) -> Void)?

    /// When the last check was *attempted* — offline attempts count, so an activation storm on a
    /// disconnected laptop costs one request per interval, not one per click.
    public private(set) var lastCheckedAt: Date?

    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var checkTask: Task<Void, Never>?
    private var started = false
    private let now: () -> Date
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "update")

    public init(
        store: AppStore,
        checker: UpdateChecker = UpdateChecker(),
        capability: UpgradeCapability = .detect(),
        runner: UpgradeRunner? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.checker = checker
        self.runner = runner ?? UpgradeRunner(capability: capability)
        self.now = now
    }

    /// Whether this process should check at all: a release, or a dev build pointed at a feed.
    nonisolated public static func shouldRun(
        version: AppVersion = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        version.isRelease || UpdateChecker.hasFeedOverride(environment)
    }

    // MARK: Lifecycle

    /// Publishes the capability, wires the runner, arms the timer and the wake/activate hooks.
    /// Idempotent. The first check is deferred, never on the launch path.
    public func start() {
        guard !started else { return }
        started = true
        let capable = runner.capability.canUpgradeInPlace
        if store.state.update.canUpgradeInPlace != capable {
            store.update { $0.setCanUpgradeInPlace(capable) }
        }
        runner.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            store.update { $0.setUpgradePhase(phase) }
            // Store first, so the card already reads "Update installed · Restart to update" and
            // stays as the manual fallback should the relaunch fail. One turn later, never inside
            // the runner's `phase` didSet: the relaunch terminates the app.
            if case .restartReady(let installed) = phase {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onRestartRequested?(installed) }
                }
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            wallDeadline: .now() + Self.firstCheckDelay, repeating: Self.checkInterval,
            leeway: .seconds(60))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        self.timer = timer
        timer.resume()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfStale() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfStale() }
        })
    }

    public func stop() {
        guard started else { return }
        started = false
        timer?.cancel()
        timer = nil
        checkTask?.cancel()
        checkTask = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        runner.stop()
    }

    // MARK: Checking

    /// One request now. Coalesces: a check already in flight is not doubled.
    public func check() {
        guard started, checkTask == nil else { return }
        lastCheckedAt = now()
        let checker = self.checker
        checkTask = Task { @MainActor [weak self] in
            let result = await checker.check()
            guard let self else { return }
            self.checkTask = nil
            self.apply(result)
        }
    }

    /// Wake / activation: only when the timer would have fired by now had the Mac stayed awake.
    public func checkIfStale() {
        guard started else { return }
        guard let last = lastCheckedAt else { return }   // the launch timer is still pending
        if now().timeIntervalSince(last) >= Self.checkInterval { check() }
    }

    func apply(_ result: UpdateChecker.CheckResult) {
        switch result {
        case .unreachable:
            logger.debug("release check unreachable; keeping the last answer")
        case .upToDate:
            if store.state.update.available != nil {
                store.update { $0.setAvailableUpdate(nil) }
            }
        case .available(let update):
            if store.state.update.available != update {
                logger.info("release \(update.version, privacy: .public) is newer than \(self.checker.running, privacy: .public)")
                store.update { $0.setAvailableUpdate(update) }
            }
        }
    }

    // MARK: Card actions

    public func perform(_ action: UpdateAction) {
        switch action {
        case .upgrade, .retry:
            // The card offered this, so the store's phase is idle, failed or not-in-Homebrew;
            // the runner may still remember an older outcome (a dismissed card reset the store,
            // not the runner). One owner: the store.
            runner.reset()
            runner.startUpgrade()
        case .restart:
            if case .restartReady(let installed) = store.state.update.phase {
                onRestartRequested?(installed)
            }
        case .showLog:
            revealLog(runner.logURL)
        case .openReleasePage:
            let target = store.state.update.available?.releaseURL ?? UpdateChecker.releasesPageURL
            if let url = URL(string: target) { openURL(url) }
        }
    }
}
