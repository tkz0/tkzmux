// UpgradeRunner — `brew update` then `brew upgrade --cask tkz0/tap/tkzmux`, in-app (TKZ-50).
//
// Started only by a click on the card; the release poller never spawns brew. Two steps, one serial
// queue, each line appended to `~/Library/Logs/tkzmux/update.log`, then the plist on disk decides
// the outcome:
//
//   | from                          | event                                     | to                  |
//   |-------------------------------|-------------------------------------------|---------------------|
//   | idle / failed / notInHomebrew | `startUpgrade()`                          | running(update)     |
//   | running(update)               | exits, *any* status                       | running(upgrade)    |
//   | running(update)               | launch failure / timeout                  | failed              |
//   | running(upgrade)              | exit 0, plist differs from running        | restartReady        |
//   | running(upgrade)              | exit 0, plist unchanged or unreadable     | notInHomebrewYet    |
//   | running(upgrade)              | non-zero / timeout / launch failure       | failed              |
//
// A non-zero `brew update` does not stop the run: it fails on any broken, unrelated tap while the
// tap we care about has usually still been pulled, and the plist check is the arbiter anyway.
// The explicit `update` is there because brew's own auto-update is throttled (24 h by default,
// 5 min for a fully qualified token) and right after a release would say "already up to date";
// the upgrade step then runs with `HOMEBREW_NO_AUTO_UPDATE=1` so it does not update twice.
//
// brew deletes the old bundle outright (never trashes it) and copies the new one in. The running
// process survives on its unlinked inodes, but anything lazily loaded from `Bundle.main` after
// that reads the *new* bundle — which is why the card pushes for a prompt restart.

import Foundation
import TkzCore
import os

@MainActor
public final class UpgradeRunner {
    public enum Step: String, Sendable, Equatable {
        case update, upgrade
    }

    nonisolated public static let updateTimeout: TimeInterval = 180
    nonisolated public static let upgradeTimeout: TimeInterval = 300
    /// Above this the log is rotated to `update.log.1` (replacing it) before a run.
    nonisolated public static let logRotateBytes: UInt64 = 1 << 20

    nonisolated public static var standardLogURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Logs/tkzmux", directoryHint: .isDirectory)
            .appending(path: "update.log", directoryHint: .notDirectory)
    }

    public private(set) var phase: UpgradePhase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }
    /// The owner mirrors this into the store; the runner never touches `AppStore`.
    public var onPhaseChange: ((UpgradePhase) -> Void)?

    public let capability: UpgradeCapability
    public let logURL: URL
    private let runner: any UpdateCommandRunning
    private let runningVersion: AppVersion
    private let bundleURL: URL
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "update")

    public init(
        capability: UpgradeCapability,
        runner: any UpdateCommandRunning = BrewCommandRunner(),
        runningVersion: AppVersion = .current,
        bundleURL: URL = Bundle.main.bundleURL,
        logURL: URL = UpgradeRunner.standardLogURL,
        queue: DispatchQueue = DispatchQueue(label: "se.tkz.tkzmux.update", qos: .userInitiated)
    ) {
        self.capability = capability
        self.runner = runner
        self.runningVersion = runningVersion
        self.bundleURL = bundleURL
        self.logURL = logURL
        self.queue = queue
    }

    // MARK: Commands (pure)

    /// The two commands, with the environment a Finder-launched app lacks: `/opt/homebrew/bin` on
    /// `PATH`, no colour, no hints, no cleanup, and no second auto-update on the upgrade step.
    nonisolated public static func commands(
        brewPath: String,
        base: [String: String]
    ) -> (update: UpdateCommand, upgrade: UpdateCommand) {
        var env = base
        let path = base["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:" + path
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        env["NO_COLOR"] = "1"
        env["HOMEBREW_NO_EMOJI"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        env["LC_ALL"] = "C"
        let update = UpdateCommand(
            executable: brewPath, arguments: ["update"], environment: env, timeout: updateTimeout)
        var upgradeEnv = env
        upgradeEnv["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let upgrade = UpdateCommand(
            executable: brewPath, arguments: ["upgrade", "--cask", UpgradeCapability.caskToken],
            environment: upgradeEnv, timeout: upgradeTimeout)
        return (update, upgrade)
    }

    // MARK: Lifecycle

    /// No-op unless the runner is idle, failed or waiting for Homebrew, and the capability allows.
    public func startUpgrade() {
        switch phase {
        case .running, .restartReady: return
        case .idle, .failed, .notInHomebrewYet: break
        }
        guard let brewPath = capability.brewPath, capability.canUpgradeInPlace else {
            phase = .failed(reason: "Homebrew is not available for this install")
            return
        }
        let commands = Self.commands(brewPath: brewPath, base: ProcessInfo.processInfo.environment)
        let job = Job(
            commands: commands, runner: runner, logURL: logURL, bundleURL: bundleURL,
            running: runningVersion)
        phase = .running(step: Step.update.rawValue)
        let box = WeakBox()
        box.value = self
        queue.async {
            let outcome = job.run { step in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { box.value?.phase = .running(step: step.rawValue) }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { box.value?.finish(outcome) } }
        }
    }

    public func retry() { startUpgrade() }

    /// Back to idle unless brew is running. The store owns the phase the card shows (a dismissed
    /// card resets it); this lets the owner bring the runner back in line before the next click.
    public func reset() {
        guard !phase.isRunning else { return }
        phase = .idle
    }

    /// Idempotent. Never kills a running brew: a half-copied `.app` is worse than a finished one.
    public func stop() {
        onPhaseChange = nil
    }

    private func finish(_ outcome: UpgradePhase) {
        switch outcome {
        case .failed(let reason): logger.error("upgrade failed: \(reason, privacy: .public)")
        default: logger.info("upgrade finished: \(String(describing: outcome), privacy: .public)")
        }
        phase = outcome
    }

    @MainActor private final class WeakBox {
        weak var value: UpgradeRunner?
    }

    // MARK: The blocking part

    /// Everything the background queue needs, captured before it leaves the main actor.
    private struct Job: Sendable {
        let commands: (update: UpdateCommand, upgrade: UpdateCommand)
        let runner: any UpdateCommandRunning
        let logURL: URL
        let bundleURL: URL
        let running: AppVersion

        func run(onStep: @Sendable (Step) -> Void) -> UpgradePhase {
            let log = UpdateLog(url: logURL)
            log.begin(running: running.marketingVersion)
            defer { log.close() }

            onStep(.update)
            let update = runner.run(commands.update) { log.line("[update] " + $0) }
            log.exit(update)
            if update.launchError != nil || update.timedOut {
                return .failed(reason: UpdateFailureText.describe(
                    step: Step.update.rawValue, result: update, timeout: commands.update.timeout))
            }

            onStep(.upgrade)
            let upgrade = runner.run(commands.upgrade) { log.line("[upgrade] " + $0) }
            log.exit(upgrade)
            guard upgrade.succeeded else {
                return .failed(reason: UpdateFailureText.describe(
                    step: Step.upgrade.rawValue, result: upgrade, timeout: commands.upgrade.timeout))
            }
            guard let installed = InstalledVersion.read(bundleURL: bundleURL), installed.differs(from: running)
            else {
                log.line("---- bundle unchanged at \(bundleURL.path)")
                return .notInHomebrewYet
            }
            log.line("---- installed \(installed.marketingVersion) (\(installed.build))")
            return .restartReady(installed: installed.marketingVersion)
        }
    }
}

/// Append-only log for one run. Created, used and closed on the update queue, inside `Job.run`;
/// it never crosses an isolation boundary, so it is not (and need not be) `Sendable`.
private final class UpdateLog {
    private let url: URL
    private var handle: FileHandle?

    init(url: URL) { self.url = url }

    func begin(running: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64),
            size > UpgradeRunner.logRotateBytes
        {
            let rotated = url.deletingPathExtension().appendingPathExtension("log.1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        line("==== \(stamp) tkzmux \(running) pid \(getpid())")
    }

    func line(_ text: String) {
        guard let handle, let data = (text + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    func exit(_ result: UpdateCommandResult) {
        if let error = result.launchError {
            line("---- launch failed: \(error)")
        } else {
            line("---- exit \(result.status)\(result.timedOut ? " (timed out)" : "")")
        }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
