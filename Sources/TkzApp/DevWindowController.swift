// DevWindowController — the M1.6 development window (TKZ-12), rebuilt on `TerminalHost` in M1.10
// (TKZ-16).
//
// One window, one `TerminalMetalView`, N login zsh sessions, and a "New session" / "Spawn 30"
// pair of buttons. It no longer owns the session table: a `TerminalViewHost` does, and this file
// is a *consumer* of the protocol design.md specifies. That is the point — the seam is proved by
// something real driving it before M2.2 replaces this window with the sidebar.
//
// Input is TKZ-13 (keyboard) + TKZ-14 (mouse), both fully live: a `TerminalInputController` is the
// view's `inputDelegate`, a `MouseController` is its `mouseHandler`, and both reach the visible
// session through `TerminalSession`'s input seam. Encoded key bytes and mouse reports come *back*
// from the session and go out through `TerminalViewHost.writeInput`; paste bytes do not —
// libghostty writes those through the session's own WRITE_PTY sink.
//
// ⌘C / ⌘V are driven from a local key monitor rather than the mouse router: the router only ever
// sees mouse and scroll events, and `TerminalInputController.acceptsKeyDown` declines anything with
// ⌘ held so menus keep working.
//
// ## The measurement harness (M1.10 acceptance)
//
// Everything below is driven by environment variables so the acceptance run is one command line
// and nothing about it leaks into a normal launch:
//
// | variable | effect |
// |---|---|
// | `TKZMUX_DEV_SNAPSHOT_DIR` | where `.ghsnap` files go. **Set this for every benchmark** — otherwise a 30-session harness run leaves 30 shells to restore on the user's next real launch |
// | `TKZMUX_DEV_SPAWN=N` | spawn N sessions at launch instead of 1 |
// | `TKZMUX_DEV_BUSY=K` | run `TKZMUX_DEV_BUSY_CMD` (default `yes | head -c 5M`) in the first K |
// | `TKZMUX_DEV_SWITCH_BENCH=N` | before quitting, switch sessions N times and report the distribution |
// | `TKZMUX_DEV_COMPRESS=0` | disable the idle-compression timer entirely |
// | `TKZMUX_DEV_COMPRESS_IDLE_MS` / `_TICK_MS` | shrink the 60 s idle threshold / 5 s tick so a benchmark does not have to run for minutes |
// | `TKZMUX_DEV_RESTORE=0` | do not restore snapshots at launch |
// | `TKZMUX_DEV_SNAPSHOT_ON_QUIT=0` | do not snapshot at quit |
// | `TKZMUX_DEV_HEARTBEAT_MS=8` | run a main-thread heartbeat and report its worst overshoot |
//
// `TKZMUX_DEV_AUTOQUIT_MS` (owned by `AppDelegate`) prints `diagnosticsLine()` and quits.

import AppKit
import Foundation
import Metal
import Persistence
import TkzCore
import TkzTerminalCore
import TkzTerminalRender
import TkzTerminalView
import os

@MainActor
public final class DevWindowController: NSObject, NSWindowDelegate {
    public let window: NSWindow
    public let terminalView: TerminalMetalView
    private let renderContext: TerminalRenderContext
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "devwindow")

    /// The session table, the ptys, the snapshots and the idle compressor.
    public let host: TerminalViewHost

    /// Keyboard, IME and the mouse router (TKZ-13).
    public let inputController = TerminalInputController()

    /// Mouse reporting, selection, wheel, OSC 8 links and the clipboard (TKZ-14). Held strongly:
    /// `inputController.mouseHandler` is weak.
    public let mouseController = MouseController()

    /// The ⌘C / ⌘V monitor installed by `wireInput`, removed in `shutdown`.
    private var commandKeyMonitor: Any?

    private let harness = DevHarnessOptions()
    private var heartbeat: (any DispatchSourceTimer)?
    private var metricsSampler: (any DispatchSourceTimer)?
    private var heartbeatWorstOvershoot: Double = 0
    private var heartbeatSamples = 0
    private var heartbeatLast: DispatchTime?
    private var launchMetrics = HostProcessMetrics.sample()
    /// Taken `TKZMUX_DEV_SETTLE_MS` after the spawn phase; the baseline the *sustained* CPU and the
    /// memory delta are measured against.
    private var settleMetrics: HostProcessMetrics?
    private var restoreReport: TerminalViewHost.RestoreSweep?
    private var quitReport: TerminalViewHost.SnapshotSweep?
    private var switchReport: SwitchBenchReport?
    private var lastSample: HostProcessMetrics?

    public init(renderContext: TerminalRenderContext) {
        self.renderContext = renderContext

        let view = TerminalMetalView(
            renderContext: renderContext, frame: NSRect(x: 0, y: 0, width: 1000, height: 680))
        view.autoresizingMask = [.width, .height]
        self.terminalView = view

        let snapshots = harness.snapshotDirectory.map { SnapshotStore(directory: $0) }
            ?? SnapshotStore.standard()
        let compressor: TerminalIdleCompressor? = harness.compressionEnabled
            ? TerminalIdleCompressor(
                policy: IdleCompressionPolicy(
                    idleThreshold: harness.idleThreshold, stepInterval: .milliseconds(0)),
                tickInterval: harness.compressionTick,
                saveSnapshot: { id, session in
                    // Snapshot *before* compressing (docs/perf.md → *rehydration is real*).
                    // Runs on the compressor's own `.utility` queue; `SnapshotStore` is a value.
                    guard let data = try? session.snapshot(),
                          let report = try? snapshots.save(data, for: id) else { return 0 }
                    return report.byteCount
                })
            : nil
        self.host = TerminalViewHost(
            view: view, snapshots: snapshots, compressor: compressor)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "tkzmux — dev terminal"
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        window.contentView = view
        window.minSize = NSSize(width: 320, height: 200)
        self.window = window

        super.init()

        window.delegate = self
        window.initialFirstResponder = view
        installTitlebarAccessory()

        view.onGridResize = { [weak self] size in
            self?.host.resizeVisible(size)
        }
        host.onDidShow = { [weak self] id in self?.didShow(id) }

        wireInput()
        startEventPump()
        compressor?.start()
    }

    // MARK: - Input (TKZ-13)

    /// Installs the keyboard and mouse controllers and points their output seams at this window.
    ///
    /// Nothing sets `inputController.encodeKey` or `insertPastedText`: with those nil the controller
    /// calls the view's visible `TerminalSession` directly, which is where the encoders and the lock
    /// live. Only the *transport* is wired here.
    private func wireInput() {
        terminalView.inputDelegate = inputController
        inputController.writeInput = { [weak self] data in self?.host.writeInput(data) }
        // DEC 1004: Claude Code sets it (verified in the claude-boot fixture), so focus in/out is a
        // real report rather than a no-op.
        inputController.isFocusReportingEnabled = { [weak self] in
            guard let self, let id = self.host.visibleID else { return false }
            return self.host.session(for: id)?.mode(1004) ?? false
        }

        // The mouse router. `terminalForView` already defaults to the view's visible session, so
        // only the byte sink needs wiring: mouse *reports* are returned to the caller and written
        // here, while a paste never comes through `sendBytes` at all.
        inputController.mouseHandler = mouseController
        mouseController.attach(to: terminalView)
        mouseController.sendBytes = { [weak self] bytes in self?.host.writeInput(Data(bytes)) }

        installCommandKeyMonitor()
    }

    /// ⌘C / ⌘V for the terminal view.
    private func installCommandKeyMonitor() {
        commandKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleCommandKey(event) else { return event }
            return nil
        }
    }

    /// Returns true when the event was consumed. ⌘C with no selection and ⌘V with an empty
    /// pasteboard both decline, so the event falls through to AppKit as it would have anyway.
    private func handleCommandKey(_ event: NSEvent) -> Bool {
        guard event.window === window, window.firstResponder === terminalView else { return false }
        // Caps Lock is a lock, not a chord: ⌘V with it on is still ⌘V.
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            return mouseController.copySelection(in: terminalView)
        case "v":
            // The paste is written by libghostty through the session's WRITE_PTY sink; there are no
            // bytes to forward here, and forwarding any would paste twice.
            return mouseController.pasteFromPasteboard(in: terminalView)
        default:
            return false
        }
    }

    // MARK: - Window

    public func showWindow() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(terminalView)
        launchMetrics = HostProcessMetrics.sample()

        if harness.restoreOnLaunch {
            let sweep = host.restoreAll(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
            if !sweep.restored.isEmpty || !sweep.failed.isEmpty { restoreReport = sweep }
            if let last = host.sessionIDs.last { host.show(last) }
        }
        if let spawn = harness.spawnCount {
            spawnSessions(spawn, busy: harness.busyCount)
        } else if host.sessionCount == 0 {
            newSession()
        }
        startHeartbeatIfRequested()
        startMetricsSamplerIfRequested()
        scheduleSettleSample()
    }

    /// Re-baselines the metrics once the spawn burst is over, and resets the heartbeat's worst
    /// case with it — the spawn phase runs 30 `posix_spawn`s on the main thread and would otherwise
    /// dominate a number that is meant to describe the idle app.
    private func scheduleSettleSample() {
        guard let settle = harness.settleInterval else { return }
        let seconds = Double(settle.components.seconds) + Double(settle.components.attoseconds) / 1e18
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                self.settleMetrics = HostProcessMetrics.sample()
                self.heartbeatWorstOvershoot = 0
                self.heartbeatSamples = 0
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        shutdown()
    }

    /// Snapshots every session, detaches the surface and hangs up every shell. Called when the
    /// window closes and when the app terminates, so quitting never leaves an orphaned zsh behind
    /// and never loses a session's scrollback.
    public func shutdown() {
        if let commandKeyMonitor {
            NSEvent.removeMonitor(commandKeyMonitor)
            self.commandKeyMonitor = nil
        }
        heartbeat?.cancel()
        heartbeat = nil
        metricsSampler?.cancel()
        metricsSampler = nil
        mouseController.detach()
        if harness.snapshotOnQuit, quitReport == nil, host.sessionCount > 0 {
            quitReport = host.snapshotAll()
        }
        host.closeAll(signal: SIGHUP)
    }

    private func installTitlebarAccessory() {
        let newButton = NSButton(title: "New session", target: self, action: #selector(newSessionClicked(_:)))
        newButton.bezelStyle = .rounded
        newButton.controlSize = .small
        newButton.frame = NSRect(x: 8, y: 2, width: 104, height: 22)

        let spawnButton = NSButton(
            title: "Spawn 30", target: self, action: #selector(spawn30Clicked(_:)))
        spawnButton.bezelStyle = .rounded
        spawnButton.controlSize = .small
        spawnButton.frame = NSRect(x: 116, y: 2, width: 78, height: 22)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 202, height: 28))
        container.addSubview(newButton)
        container.addSubview(spawnButton)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func newSessionClicked(_ sender: Any?) { newSession() }

    /// The acceptance harness, on a button: 30 zsh sessions, five of them fed 5 MB, then idle.
    @objc private func spawn30Clicked(_ sender: Any?) { spawnSessions(30, busy: 5) }

    // MARK: - Sessions

    /// Spawns a login zsh under the full tkzmux environment and switches to it.
    @discardableResult
    public func newSession() -> SessionID? {
        let id = SessionID.generate()
        do {
            _ = try host.open(
                id,
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                env: [:],
                size: terminalView.gridSizeForBounds())
            host.show(id)
            return id
        } catch {
            logger.error("failed to spawn a dev session: \(String(describing: error), privacy: .public)")
            presentSpawnFailure(error)
            return nil
        }
    }

    /// `count` sessions, the first `busy` of which run `busyCommand` and then idle.
    ///
    /// This is the M1.10 acceptance harness. Nothing blocks: the busy sessions ingest on their own
    /// IO queues while the window stays interactive, which is the property being demonstrated.
    ///
    /// The busy command is deliberately **delayed**. A login zsh calls `tcsetattr(TCSAFLUSH)` while
    /// it sets up its line editor, which discards anything already sitting in the tty's input
    /// queue — so a command written in the same turn as the spawn is silently swallowed. Measured:
    /// with no delay all 30 snapshots came back the same ~17 KiB size, i.e. a bare prompt.
    @discardableResult
    public func spawnSessions(_ count: Int, busy: Int) -> [SessionID] {
        var spawned: [SessionID] = []
        for _ in 0..<count {
            guard let id = newSession() else { break }
            spawned.append(id)
        }
        if let first = spawned.first { host.show(first) }
        let busyIDs = Array(spawned.prefix(busy))
        if !busyIDs.isEmpty {
            let command = harness.busyCommand
            let delay = harness.busyDelay
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated {
                    for id in busyIDs { self.host.run(id, command: command) }
                }
            }
        }
        return spawned
    }

    /// Re-pushes what the view cannot know after a session switch.
    private func didShow(_ id: SessionID?) {
        if let id, let session = host.session(for: id) {
            // `MouseController.syncGeometry` only pushes on *change*, and the geometry has not
            // changed — the session has. Without this a second session keeps the option-derived
            // guess (no padding, screen size = grid size) and every mouse report lands on the
            // wrong cell.
            session.setMousePixelGeometry(mouseController.pixelGeometry(of: terminalView))
        }
        window.makeFirstResponder(terminalView)
        updateTitle()
    }

    /// Drains the host's merged event stream. Only the things a *window* owns are handled here;
    /// the host already keeps titles and liveness for itself.
    private func startEventPump() {
        let events = host.events
        Task { @MainActor [weak self] in
            for await (id, event) in events {
                guard let self else { return }
                self.handle(event, for: id)
            }
        }
    }

    private func handle(_ event: TerminalEvent, for id: SessionID) {
        switch event {
        case .title:
            updateTitle()
        case .bell:
            NSSound.beep()
        case .clipboardWrite(let text):
            // OSC 52 lands here and **only** here. `MouseController.handle(_: TerminalEvent)` is the
            // same sink for a host that does not own the event stream; wiring both would set the
            // pasteboard twice for one write.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .exited:
            host.discard(id)
            updateTitle()
        default:
            break
        }
    }

    private func updateTitle() {
        guard let id = host.visibleID,
              let index = host.sessionIDs.firstIndex(of: id) else {
            window.title = "tkzmux — dev terminal (no session)"
            return
        }
        let title = host.title(of: id) ?? "zsh"
        window.title = "tkzmux — \(title) [\(index + 1)/\(host.sessionCount)]"
    }

    private func presentSpawnFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not start a shell"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Session-switch benchmark

    public struct SwitchBenchReport: Sendable {
        public var switches: Int
        /// `show(_:)` alone, in milliseconds.
        public var showMin: Double
        public var showMedian: Double
        public var showP99: Double
        public var showMax: Double
        /// `show(_:)` + the first frame's CPU rebuild + offscreen encode, in milliseconds.
        public var frameMin: Double
        public var frameMedian: Double
        public var frameP99: Double
        public var frameMax: Double
        /// How many of those first frames reported `DIRTY_FULL`. Anything less than `switches`
        /// means a switch did not really rebuild and the timing is meaningless.
        public var fullRebuilds: Int
        /// Total glyphs in the last rebuilt frame — a non-zero value proves the rebuild had content.
        public var lastGlyphCount: Int
        /// Individual switches whose `show` exceeded one frame at 120 Hz (8.3 ms).
        public var showOverBudget: Int
        /// Individual switches whose `show` + first-frame rebuild exceeded 8.3 ms. This is the
        /// acceptance criterion's own count, not a summary statistic.
        public var frameOverBudget: Int
    }

    /// Switches between every session `iterations` times, timing `show(_:)` and the first frame
    /// after it.
    ///
    /// The first frame is forced with an **offscreen** render, because the display link parks when
    /// the window is occluded (which it always is in a headless run) and `show` on its own would be
    /// a few microseconds of bookkeeping that proves nothing. `dirty == .full` on every one of them
    /// is the sanity check that the surface really detached and re-attached.
    @discardableResult
    public func runSwitchBenchmark(iterations: Int) -> SwitchBenchReport? {
        let ids = host.sessionIDs
        guard ids.count >= 2, iterations > 0 else { return nil }
        let grid = terminalView.gridSizeForBounds()
        let pixels = renderContext.renderer.drawableSize(columns: Int(grid.cols), rows: Int(grid.rows))
        guard let texture = renderContext.renderer.makeOffscreenTexture(
            width: max(1, pixels.width), height: max(1, pixels.height)) else { return nil }

        var showTimes: [Double] = []
        var frameTimes: [Double] = []
        var fullRebuilds = 0
        var lastGlyphCount = 0
        showTimes.reserveCapacity(iterations)
        frameTimes.reserveCapacity(iterations)

        for index in 0..<iterations {
            let id = ids[index % ids.count]
            host.resetShowDurations()
            let start = ContinuousClock.now
            host.show(id)
            let afterShow = ContinuousClock.now
            var dirtyIsFull = false
            do {
                let outcome = try renderContext.renderer.render(surface: terminalView.surface, to: texture)
                dirtyIsFull = outcome.update.dirty == .full
                lastGlyphCount = outcome.glyphCount
            } catch {
                logger.error("bench render failed: \(String(describing: error), privacy: .public)")
            }
            let afterFrame = ContinuousClock.now
            if dirtyIsFull { fullRebuilds += 1 }
            showTimes.append(DevWindowController.milliseconds(start.duration(to: afterShow)))
            frameTimes.append(DevWindowController.milliseconds(start.duration(to: afterFrame)))
        }

        let show = showTimes.sorted()
        let frame = frameTimes.sorted()
        let report = SwitchBenchReport(
            switches: iterations,
            showMin: show.first ?? 0,
            showMedian: DevWindowController.percentile(show, 0.5),
            showP99: DevWindowController.percentile(show, 0.99),
            showMax: show.last ?? 0,
            frameMin: frame.first ?? 0,
            frameMedian: DevWindowController.percentile(frame, 0.5),
            frameP99: DevWindowController.percentile(frame, 0.99),
            frameMax: frame.last ?? 0,
            fullRebuilds: fullRebuilds,
            lastGlyphCount: lastGlyphCount,
            showOverBudget: show.count { $0 > DevWindowController.frameBudgetMilliseconds },
            frameOverBudget: frame.count { $0 > DevWindowController.frameBudgetMilliseconds })
        switchReport = report
        return report
    }

    /// One frame at 120 Hz.
    static let frameBudgetMilliseconds = 1000.0 / 120.0

    private static func milliseconds(_ duration: Duration) -> Double {
        (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000
    }

    /// `sorted` must already be sorted ascending.
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    // MARK: - Main-thread heartbeat

    /// A timer on the main queue that records how late it is delivered.
    ///
    /// This is the honest *proxy* for "does the idle-compression timer drop frames". A real
    /// dropped-frame count needs a running display link, and the link correctly parks when the
    /// window is occluded — which is every headless run. What this measures instead is whether
    /// anything blocks the main thread past a frame budget while background sessions compress. It
    /// is a proxy, and docs/perf.md says so.
    private func startHeartbeatIfRequested() {
        guard let interval = harness.heartbeatInterval else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .nanoseconds(0))
        heartbeatLast = DispatchTime.now()
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = DispatchTime.now()
                if let last = self.heartbeatLast {
                    let gap = Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1e6
                    let expected = Double(interval.components.seconds) * 1000
                        + Double(interval.components.attoseconds) / 1e15
                    self.heartbeatWorstOvershoot = max(self.heartbeatWorstOvershoot, gap - expected)
                    self.heartbeatSamples += 1
                }
                self.heartbeatLast = now
            }
        }
        timer.resume()
        heartbeat = timer
    }

    /// `TKZMUX_DEV_SAMPLE_MS`: writes one `TKZMUX_SAMPLE …` line to stderr every interval.
    ///
    /// The single line `diagnosticsLine()` prints at quit is a *post-everything* reading; the
    /// tables in docs/perf.md need the time series (footprint before and after a compression pass,
    /// CPU over a window that excludes the spawn burst) and this is where it comes from.
    private func startMetricsSamplerIfRequested() {
        guard let interval = harness.metricsSampleInterval else { return }
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let metrics = HostProcessMetrics.sample()
                var line = "TKZMUX_SAMPLE t=\(String(format: "%.1f", metrics.wallSeconds - self.launchMetrics.wallSeconds))s"
                line += " sessions=\(self.host.sessionCount)"
                line += " rss=\(DevWindowController.mib(metrics.residentBytes))"
                line += " footprint=\(DevWindowController.mib(metrics.footprintBytes))"
                line += " reusable=\(DevWindowController.mib(metrics.reusableBytes))"
                line += " threads=\(metrics.threadCount)"
                line += " cpu=\(String(format: "%.4f", metrics.cpuPercent(since: self.lastSample ?? self.launchMetrics)))%"
                if let c = self.host.compressor?.stats {
                    line += " passes=\(c.passes) steps=\(c.steps) snapshots=\(c.snapshotsWritten)"
                    line += " maxPass=\(String(format: "%.2f", c.maxPassSeconds * 1000))ms"
                }
                line += " heartbeatWorst=\(String(format: "%.2f", self.heartbeatWorstOvershoot))ms"
                FileHandle.standardError.write(Data((line + "\n").utf8))
                self.lastSample = metrics
            }
        }
        timer.resume()
        metricsSampler = timer
    }

    // MARK: - Dev instrumentation

    /// A one-line report of what the engine actually did. Printed by `TKZMUX_DEV_AUTOQUIT_MS`.
    ///
    /// `sessions=N` is load-bearing: `scripts/make-app.sh`'s launch smoke test greps for it.
    public func diagnosticsLine() -> String {
        if let iterations = harness.switchBenchIterations { _ = runSwitchBenchmark(iterations: iterations) }
        let stats = renderContext.renderer.stats
        let metrics = HostProcessMetrics.sample()
        var line = """
            sessions=\(host.sessionCount) visible=\(host.visibleID.flatMap { host.sessionIDs.firstIndex(of: $0) }.map(String.init) ?? "-") \
            grid=\(terminalView.currentGridSize.cols)x\(terminalView.currentGridSize.rows) \
            gridResizes=\(terminalView.gridResizeCount) framesRendered=\(terminalView.framesRendered) \
            glyphs=\(terminalView.surface.glyphCount) \
            framesEncoded=\(stats.framesEncoded) framesSkipped=\(stats.framesSkipped) \
            drawableRequests=\(stats.drawableRequests) drawablesAcquired=\(stats.drawablesAcquired) \
            window[visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) key=\(window.isKeyWindow)] \
            link[\(terminalView.frameDriver.transitionSummary)] \
            mem[rss=\(DevWindowController.mib(metrics.residentBytes)) footprint=\(DevWindowController.mib(metrics.footprintBytes)) \
            reusable=\(DevWindowController.mib(metrics.reusableBytes)) threads=\(metrics.threadCount) \
            cpu=\(String(format: "%.4f", metrics.cpuPercent(since: launchMetrics)))% over \
            \(String(format: "%.1f", metrics.wallSeconds - launchMetrics.wallSeconds))s]
            """
        if let settleMetrics {
            line += " settled[rss=\(DevWindowController.mib(settleMetrics.residentBytes))"
            line += " footprint=\(DevWindowController.mib(settleMetrics.footprintBytes))"
            line += " reusable=\(DevWindowController.mib(settleMetrics.reusableBytes))"
            line += " threads=\(settleMetrics.threadCount)"
            line += " sustainedCpu=\(String(format: "%.4f", metrics.cpuPercent(since: settleMetrics)))%"
            line += " over \(String(format: "%.1f", metrics.wallSeconds - settleMetrics.wallSeconds))s]"
        }
        let rows = host.scrollbackRows().sorted(by: >)
        line += " scrollbackRows[max=\(rows.first ?? 0) top5=\(rows.prefix(5).map(String.init).joined(separator: ","))"
        line += " total=\(rows.reduce(0, +))]"
        // The spawned processes, which `mem[...]` above cannot see: this is where a runaway
        // `swift test` or a fat Claude Code session shows up. docs/perf.md → *Session process
        // memory*.
        let subtrees = host.sessionMemory()
        let subtreeTotal = subtrees.reduce(UInt64(0)) { $0 + $1.sample.footprintBytes }
        let procs = subtrees.reduce(0) { $0 + $1.sample.processCount }
        line += " sessionMem[total=\(DevWindowController.mib(subtreeTotal)) procs=\(procs)"
        if let worst = subtrees.max(by: { $0.sample.footprintBytes < $1.sample.footprintBytes }),
            worst.sample.footprintBytes > 0
        {
            line += " worstSession=\(DevWindowController.mib(worst.sample.footprintBytes))"
        }
        // The biggest single *descendant* across all sessions — the runaway, when there is one.
        // `largestName` deliberately excludes each session's own shell; see `SessionMemorySample`.
        if let hog = subtrees.max(by: { $0.sample.largestBytes < $1.sample.largestBytes }),
            hog.sample.largestBytes > 0
        {
            line += " worstProc=\(hog.sample.largestName):\(DevWindowController.mib(hog.sample.largestBytes))"
        }
        line += "]"
        if let compressor = host.compressor {
            let c = compressor.stats
            line += " compress[tracked=\(c.tracked) ticks=\(c.ticks) passes=\(c.passes) steps=\(c.steps)"
            line += " snapshots=\(c.snapshotsWritten) total=\(String(format: "%.1f", c.compressSeconds * 1000))ms"
            line += " maxPass=\(String(format: "%.2f", c.maxPassSeconds * 1000))ms]"
        } else {
            line += " compress[disabled]"
        }
        if let interval = harness.heartbeatInterval {
            line += " heartbeat[interval=\(DevWindowController.milliseconds(interval))ms"
            line += " samples=\(heartbeatSamples)"
            line += " worstOvershoot=\(String(format: "%.2f", heartbeatWorstOvershoot))ms]"
        }
        if let restoreReport {
            line += " restore[n=\(restoreReport.restored.count) failed=\(restoreReport.failed.count)"
            line += " bytes=\(restoreReport.totalBytes)"
            line += " elapsed=\(String(format: "%.1f", restoreReport.elapsed * 1000))ms]"
        }
        if let switchReport {
            line += " switch[n=\(switchReport.switches) full=\(switchReport.fullRebuilds)"
            line += " over8.3ms[show=\(switchReport.showOverBudget) frame=\(switchReport.frameOverBudget)]"
            line += " glyphs=\(switchReport.lastGlyphCount)"
            line += " show=\(String(format: "%.3f/%.3f/%.3f/%.3f", switchReport.showMin, switchReport.showMedian, switchReport.showP99, switchReport.showMax))ms"
            line += " frame=\(String(format: "%.3f/%.3f/%.3f/%.3f", switchReport.frameMin, switchReport.frameMedian, switchReport.frameP99, switchReport.frameMax))ms]"
        }
        // Snapshot-on-quit happens in `shutdown()`, which runs *after* this line is printed, so
        // report it eagerly here when the harness asked for it — the numbers are the same sweep.
        if harness.snapshotOnQuit, quitReport == nil, host.sessionCount > 0 {
            let sweep = host.snapshotAll()
            quitReport = sweep
            line += " quitSnapshot[saved=\(sweep.saved.count) skipped=\(sweep.skipped.count)"
            line += " failed=\(sweep.failed.count) bytes=\(sweep.totalBytes)"
            line += " elapsed=\(String(format: "%.1f", sweep.elapsed * 1000))ms]"
        }
        return line
    }

    private static func mib(_ bytes: UInt64) -> String {
        String(format: "%.1fMiB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - Harness options

/// The environment-variable surface of the dev harness, parsed once.
///
/// Every default is "behave like a normal launch". A benchmark opts in explicitly, and — most
/// importantly — points `TKZMUX_DEV_SNAPSHOT_DIR` somewhere disposable so a 30-session run does not
/// leave 30 shells waiting in the user's real snapshot store.
struct DevHarnessOptions: Sendable {
    var snapshotDirectory: URL?
    var spawnCount: Int?
    var busyCount: Int
    var busyCommand: String
    /// How long to wait after spawning before typing `busyCommand` — see `spawnSessions`.
    var busyDelay: Duration
    var switchBenchIterations: Int?
    var compressionEnabled: Bool
    var idleThreshold: Duration
    var compressionTick: Duration
    var restoreOnLaunch: Bool
    var snapshotOnQuit: Bool
    var heartbeatInterval: Duration?
    /// How long after the spawn phase to take the "idle baseline" sample that the sustained-CPU
    /// number is measured against. Without it the percentage folds in spawning 30 shells and
    /// ingesting 25 MB, which is not what "CPU while idle" means.
    var settleInterval: Duration?
    /// `TKZMUX_DEV_SAMPLE_MS` — period of the `TKZMUX_SAMPLE` stderr time series.
    var metricsSampleInterval: Duration?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        func int(_ key: String) -> Int? {
            guard let raw = environment["TKZMUX_DEV_\(key)"], let value = Int(raw) else { return nil }
            return value
        }
        func flag(_ key: String, default fallback: Bool) -> Bool {
            guard let raw = environment["TKZMUX_DEV_\(key)"] else { return fallback }
            return !(raw == "0" || raw.lowercased() == "false" || raw.isEmpty)
        }
        snapshotDirectory = environment["TKZMUX_DEV_SNAPSHOT_DIR"].map { URL(filePath: $0) }
        spawnCount = int("SPAWN").map { max(0, $0) }
        busyCount = int("BUSY") ?? 0
        // 5 MB of `y\n` through a real pty: the acceptance corpus. `head -c` stops `yes` itself.
        // The ticket spells this `yes | head -c 5M`; BSD `head` rejects the `M` suffix
        // (`head: illegal byte count`), so the byte count is written out. Same 5 MB.
        busyCommand = environment["TKZMUX_DEV_BUSY_CMD"] ?? "yes | head -c 5000000"
        busyDelay = .milliseconds(int("BUSY_DELAY_MS") ?? 2000)
        switchBenchIterations = int("SWITCH_BENCH").map { max(0, $0) }
        compressionEnabled = flag("COMPRESS", default: true)
        idleThreshold = .milliseconds(int("COMPRESS_IDLE_MS") ?? 60_000)
        compressionTick = .milliseconds(int("COMPRESS_TICK_MS") ?? 5_000)
        restoreOnLaunch = flag("RESTORE", default: true)
        snapshotOnQuit = flag("SNAPSHOT_ON_QUIT", default: true)
        heartbeatInterval = int("HEARTBEAT_MS").map { Duration.milliseconds(max(1, $0)) }
        metricsSampleInterval = int("SAMPLE_MS").map { Duration.milliseconds(max(100, $0)) }
        settleInterval = int("SETTLE_MS").map { Duration.milliseconds(max(0, $0)) }
            ?? (spawnCount == nil ? nil : .seconds(12))
    }
}
