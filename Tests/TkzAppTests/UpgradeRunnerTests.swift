// UpgradeRunnerTests — brew, without brew (TKZ-50).
//
// `UpdateCommandRunning` is a protocol precisely so this file can script every outcome: the fake
// records what it was asked to run, returns canned results, and can rewrite the temp bundle's
// Info.plist between steps to stand in for a real `brew upgrade`. `swift test` never spawns
// brew — only `AppDelegate` ever constructs `BrewCommandRunner`.

import Foundation
import Synchronization
import Testing
import TkzCore

@testable import TkzApp

/// Scripted stand-in for brew.
final class FakeCommandRunner: UpdateCommandRunning {
    struct Scripted {
        var result: UpdateCommandResult
        var lines: [String] = []
        /// Runs before the result is returned — the place to rewrite the plist.
        var sideEffect: (@Sendable () -> Void)? = nil
    }

    private struct State {
        var scripted: [Scripted]
        var ran: [UpdateCommand] = []
    }

    private let state: Mutex<State>

    init(_ scripted: [Scripted]) {
        state = Mutex(State(scripted: scripted))
    }

    var ran: [UpdateCommand] { state.withLock { $0.ran } }

    func run(_ command: UpdateCommand, onLine: (String) -> Void) -> UpdateCommandResult {
        let next: Scripted? = state.withLock { s in
            s.ran.append(command)
            return s.scripted.isEmpty ? nil : s.scripted.removeFirst()
        }
        guard let next else { return UpdateCommandResult(status: -1, launchError: "unscripted call") }
        for line in next.lines { onLine(line) }
        next.sideEffect?()
        return next.result
    }
}

@MainActor
@Suite(.serialized)
struct UpgradeRunnerTests {

    // MARK: Fixture bundle

    struct TempBundle {
        let root: URL
        var app: URL { root.appending(path: "Foo.app", directoryHint: .isDirectory) }
        var log: URL { root.appending(path: "update.log", directoryHint: .notDirectory) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "tkzmux-upgrade-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: app.appending(path: "Contents", directoryHint: .isDirectory), withIntermediateDirectories: true)
        }

        func writePlist(version: String, build: String) {
            let plist: [String: Any] = [
                AppVersion.marketingVersionKey: version,
                AppVersion.buildKey: build,
            ]
            let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try! data.write(to: app.appending(path: "Contents/Info.plist", directoryHint: .notDirectory))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static let running = AppVersion(marketingVersion: "0.7.0", build: "300", ghosttyCommit: "abc")
    static let capable = UpgradeCapability(brewPath: "/opt/homebrew/bin/brew", caskroomPresent: true, isStandardInstall: true)

    static func makeRunner(_ bundle: TempBundle, fake: FakeCommandRunner, capability: UpgradeCapability = capable) -> (UpgradeRunner, DispatchQueue) {
        let queue = DispatchQueue(label: "test.update")
        let runner = UpgradeRunner(
            capability: capability, runner: fake, runningVersion: running,
            bundleURL: bundle.app, logURL: bundle.log, queue: queue)
        return (runner, queue)
    }

    /// Waits for the background job and its main-queue hops to land.
    static func settle(_ queue: DispatchQueue, until done: @MainActor () -> Bool) async throws {
        queue.sync {}
        for _ in 0..<200 {
            if done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Commands

    @Test("The two commands: PATH prefixed, brew told to be quiet, no second auto-update on upgrade")
    func commands() {
        let (update, upgrade) = UpgradeRunner.commands(brewPath: "/opt/homebrew/bin/brew", base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"])
        #expect(update.executable == "/opt/homebrew/bin/brew")
        #expect(update.arguments == ["update"])
        #expect(upgrade.arguments == ["upgrade", "--cask", "tkz0/tap/tkzmux"])
        #expect(update.environment["PATH"] == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin")
        #expect(update.environment["HOME"] == "/Users/x")
        for key in ["HOMEBREW_NO_ENV_HINTS", "HOMEBREW_NO_COLOR", "NO_COLOR", "HOMEBREW_NO_EMOJI", "HOMEBREW_NO_INSTALL_CLEANUP"] {
            #expect(update.environment[key] == "1", Comment(rawValue: key))
            #expect(upgrade.environment[key] == "1", Comment(rawValue: key))
        }
        #expect(update.environment["HOMEBREW_NO_AUTO_UPDATE"] == nil)
        #expect(upgrade.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(update.timeout == 180)
        #expect(upgrade.timeout == 300)
        // A Finder-launched app with no PATH at all still gets the system directories.
        let bare = UpgradeRunner.commands(brewPath: "/opt/homebrew/bin/brew", base: [:])
        #expect(bare.update.environment["PATH"] == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    // MARK: Phases

    @Test("update → upgrade → restartReady when the plist on disk changes")
    func happyPath() async throws {
        let bundle = try TempBundle()
        defer { bundle.remove() }
        bundle.writePlist(version: "0.7.0", build: "300")
        let fake = FakeCommandRunner([
            .init(result: UpdateCommandResult(status: 0), lines: ["Updated 1 tap (tkz0/tap)."]),
            .init(result: UpdateCommandResult(status: 0), lines: ["==> Upgrading tkzmux", "🍺  tkzmux was successfully upgraded!"],
                  sideEffect: { bundle.writePlist(version: "0.8.0", build: "310") }),
        ])
        let (runner, queue) = Self.makeRunner(bundle, fake: fake)
        var seen: [UpgradePhase] = []
        runner.onPhaseChange = { seen.append($0) }

        runner.startUpgrade()
        #expect(runner.phase == .running(step: "update"))
        try await Self.settle(queue) { runner.phase == .restartReady(installed: "0.8.0") }
        #expect(runner.phase == .restartReady(installed: "0.8.0"))
        #expect(seen == [.running(step: "update"), .running(step: "upgrade"), .restartReady(installed: "0.8.0")])
        #expect(fake.ran.map(\.arguments) == [["update"], ["upgrade", "--cask", "tkz0/tap/tkzmux"]])

        let log = try String(contentsOf: bundle.log, encoding: .utf8)
        #expect(log.contains("tkzmux 0.7.0 pid"))
        #expect(log.contains("[update] Updated 1 tap (tkz0/tap)."))
        #expect(log.contains("[upgrade] ==> Upgrading tkzmux"))
        #expect(log.contains("---- exit 0"))
        #expect(log.contains("---- installed 0.8.0 (310)"))

        // Done means done: a second click is a no-op…
        runner.startUpgrade()
        #expect(fake.ran.count == 2)
        // …until the owner resets the runner to match a store that went back to idle.
        runner.reset()
        #expect(runner.phase == .idle)
        #expect(seen.last == .idle)
    }

    @Test("reset is refused while brew is running")
    func resetWhileRunning() async throws {
        let bundle = try TempBundle()
        defer { bundle.remove() }
        bundle.writePlist(version: "0.7.0", build: "300")
        let fake = FakeCommandRunner([
            .init(result: UpdateCommandResult(status: 0)),
            .init(result: UpdateCommandResult(status: 0)),
        ])
        let (runner, queue) = Self.makeRunner(bundle, fake: fake)
        queue.suspend()
        runner.startUpgrade()
        runner.reset()
        #expect(runner.phase == .running(step: "update"))
        queue.resume()
        try await Self.settle(queue) { !runner.phase.isRunning }
        #expect(runner.phase == .notInHomebrewYet)
    }

    @Test("A clean upgrade that leaves the plist alone is `notInHomebrewYet`")
    func caskNotBumpedYet() async throws {
        let bundle = try TempBundle()
        defer { bundle.remove() }
        bundle.writePlist(version: "0.7.0", build: "300")
        let fake = FakeCommandRunner([
            .init(result: UpdateCommandResult(status: 0)),
            .init(result: UpdateCommandResult(status: 0), lines: ["Warning: tkzmux 0.7.0 is already installed"]),
        ])
        let (runner, queue) = Self.makeRunner(bundle, fake: fake)
        runner.startUpgrade()
        try await Self.settle(queue) { runner.phase == .notInHomebrewYet }
        #expect(runner.phase == .notInHomebrewYet)
        // "Try again" is allowed from here.
        runner.retry()
        #expect(runner.phase == .running(step: "update"))
        try await Self.settle(queue) { !runner.phase.isRunning }
        // The fake had nothing scripted for the third call: a launch failure, reported as such.
        #expect(runner.phase == .failed(reason: "Could not run brew: unscripted call"))
    }

    @Test("A build-only change on disk still counts as installed")
    func buildOnlyChange() async throws {
        let bundle = try TempBundle()
        defer { bundle.remove() }
        bundle.writePlist(version: "0.7.0", build: "300")
        let fake = FakeCommandRunner([
            .init(result: UpdateCommandResult(status: 0)),
            .init(result: UpdateCommandResult(status: 0), sideEffect: { bundle.writePlist(version: "0.7.0", build: "301") }),
        ])
        let (runner, queue) = Self.makeRunner(bundle, fake: fake)
        runner.startUpgrade()
        try await Self.settle(queue) { !runner.phase.isRunning }
        #expect(runner.phase == .restartReady(installed: "0.7.0"))
    }

    @Test("A non-zero `brew update` still proceeds; a non-zero upgrade fails with brew's last line")
    func updateFailureIsTolerated() async throws {
        let bundle = try TempBundle()
        defer { bundle.remove() }
        bundle.writePlist(version: "0.7.0", build: "300")
        let fake = FakeCommandRunner([
            .init(result: UpdateCommandResult(status: 1, lastLine: "Error: some other tap is broken")),
            .init(result: UpdateCommandResult(status: 1, lastLine: "Error: Cask 'tkzmux' is unreadable")),
        ])
        let (runner, queue) = Self.makeRunner(bundle, fake: fake)
        runner.startUpgrade()
        try await Self.settle(queue) { !runner.phase.isRunning }
        #expect(fake.ran.count == 2)
        #expect(runner.phase == .failed(reason: "Error: Cask 'tkzmux' is unreadable (exit 1)"))
        let log = try String(contentsOf: bundle.log, encoding: .utf8)
        #expect(log.contains("---- exit 1"))
    }

    @Test("A timed-out or unlaunchable `brew update` fails without running the upgrade")
    func updateTimeoutFails() async throws {
        let bundle = try TempBundle()
        defer { bundle.remove() }
        bundle.writePlist(version: "0.7.0", build: "300")
        let fake = FakeCommandRunner([
            .init(result: UpdateCommandResult(status: 143, timedOut: true)),
            .init(result: UpdateCommandResult(status: 0)),
        ])
        let (runner, queue) = Self.makeRunner(bundle, fake: fake)
        runner.startUpgrade()
        try await Self.settle(queue) { !runner.phase.isRunning }
        #expect(fake.ran.count == 1)
        #expect(runner.phase == .failed(reason: "brew update timed out after 180 s"))
    }

    @Test("Without the capability the runner never spawns anything")
    func notCapable() throws {
        let bundle = try TempBundle()
        defer { bundle.remove() }
        let fake = FakeCommandRunner([])
        let (runner, _) = Self.makeRunner(
            bundle, fake: fake,
            capability: UpgradeCapability(brewPath: nil, caskroomPresent: true, isStandardInstall: true))
        runner.startUpgrade()
        #expect(fake.ran.isEmpty)
        #expect(runner.phase == .failed(reason: "Homebrew is not available for this install"))
        runner.stop()   // never started: a no-op
    }

    @Test("A click while running is ignored")
    func clickWhileRunning() async throws {
        let bundle = try TempBundle()
        defer { bundle.remove() }
        bundle.writePlist(version: "0.7.0", build: "300")
        let fake = FakeCommandRunner([
            .init(result: UpdateCommandResult(status: 0)),
            .init(result: UpdateCommandResult(status: 0)),
        ])
        let (runner, queue) = Self.makeRunner(bundle, fake: fake)
        queue.suspend()
        runner.startUpgrade()
        runner.startUpgrade()
        runner.retry()
        queue.resume()
        try await Self.settle(queue) { !runner.phase.isRunning }
        #expect(fake.ran.count == 2)
    }

    @Test("The log rotates once past the cap, keeping one previous file")
    func logRotation() async throws {
        let bundle = try TempBundle()
        defer { bundle.remove() }
        bundle.writePlist(version: "0.7.0", build: "300")
        try Data(repeating: 0x41, count: Int(UpgradeRunner.logRotateBytes) + 1).write(to: bundle.log)
        let fake = FakeCommandRunner([
            .init(result: UpdateCommandResult(status: 0)),
            .init(result: UpdateCommandResult(status: 0)),
        ])
        let (runner, queue) = Self.makeRunner(bundle, fake: fake)
        runner.startUpgrade()
        try await Self.settle(queue) { !runner.phase.isRunning }
        let rotated = bundle.log.deletingPathExtension().appendingPathExtension("log.1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let fresh = try String(contentsOf: bundle.log, encoding: .utf8)
        #expect(fresh.hasPrefix("===="))
        #expect(!fresh.contains("AAAA"))
    }
}

// MARK: - Failure text

@Suite struct UpdateFailureTextTests {
    @Test("The last readable line wins, with the exit status")
    func lastLine() {
        let result = UpdateCommandResult(status: 1, lastLine: "Error: something")
        #expect(UpdateFailureText.describe(step: "upgrade", result: result, timeout: 300) == "Error: something (exit 1)")
    }

    @Test("Launch and timeout forms, and the empty fallback")
    func otherForms() {
        #expect(UpdateFailureText.describe(step: "update", result: UpdateCommandResult(status: -1, launchError: "No such file"), timeout: 180)
            == "Could not run brew: No such file")
        #expect(UpdateFailureText.describe(step: "upgrade", result: UpdateCommandResult(status: 143, timedOut: true), timeout: 300)
            == "brew upgrade timed out after 300 s")
        #expect(UpdateFailureText.describe(step: "upgrade", result: UpdateCommandResult(status: 2), timeout: 300)
            == "brew upgrade failed (exit 2)")
    }

    @Test("clean strips ANSI colour, keeps what follows the last carriage return, trims and caps")
    func clean() {
        #expect(UpdateFailureText.clean("\u{1B}[31mError:\u{1B}[0m broken  \n") == "Error: broken")
        #expect(UpdateFailureText.clean("#####    12%\r#########  50%\r############ 100%") == "############ 100%")
        #expect(UpdateFailureText.clean("   \r  ") == nil)
        #expect(UpdateFailureText.clean("") == nil)
        let long = String(repeating: "x", count: 500)
        let capped = UpdateFailureText.clean(long)
        #expect(capped?.count == UpdateFailureText.maxLength)
        #expect(capped?.hasSuffix("…") == true)
    }
}

// MARK: - Installed version

@Suite struct InstalledVersionTests {
    @Test("Reads the plist as a file, and differs on either key")
    func readsAndCompares() throws {
        let bundle = try UpgradeRunnerTests.TempBundle()
        defer { bundle.remove() }
        #expect(InstalledVersion.read(bundleURL: bundle.app) == nil)   // no plist yet
        bundle.writePlist(version: "0.8.0", build: "310")
        let installed = try #require(InstalledVersion.read(bundleURL: bundle.app))
        #expect(installed == InstalledVersion(marketingVersion: "0.8.0", build: "310"))
        let running = AppVersion(marketingVersion: "0.8.0", build: "310", ghosttyCommit: "x")
        #expect(!installed.differs(from: running))
        #expect(installed.differs(from: AppVersion(marketingVersion: "0.7.0", build: "310", ghosttyCommit: "x")))
        #expect(installed.differs(from: AppVersion(marketingVersion: "0.8.0", build: "309", ghosttyCommit: "x")))
        // Garbage on disk is "unreadable", not a crash.
        try Data("nope".utf8).write(to: bundle.app.appending(path: "Contents/Info.plist"))
        #expect(InstalledVersion.read(bundleURL: bundle.app) == nil)
    }
}

// MARK: - Capability

@Suite struct UpgradeCapabilityTests {
    @Test("All three facts must hold; each one alone flips the answer")
    func gating() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "tkzmux-cap-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appending(path: "bin", directoryHint: .isDirectory)
        let caskroom = root.appending(path: "Caskroom/tkzmux", directoryHint: .isDirectory)
        let app = root.appending(path: "Applications/tkzmux.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caskroom, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let brew = bin.appending(path: "brew", directoryHint: .notDirectory)
        try Data("#!/bin/sh\n".utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)

        let env = ["PATH": bin.path]
        let all = UpgradeCapability.detect(
            bundlePath: app.path + "/", caskroomPath: caskroom.path, standardBundlePath: app.path, environment: env)
        #expect(all.canUpgradeInPlace)
        #expect(all.brewPath == brew.path)

        let noBrew = UpgradeCapability.detect(
            bundlePath: app.path, caskroomPath: caskroom.path, standardBundlePath: app.path, environment: ["PATH": "/nonexistent"])
        // The real Homebrew prefixes are still searched, so this only holds when brew is not installed there;
        // the value type's own gate is what matters:
        #expect(!UpgradeCapability(brewPath: nil, caskroomPresent: true, isStandardInstall: true).canUpgradeInPlace)
        #expect(noBrew.caskroomPresent)

        let noCaskroom = UpgradeCapability.detect(
            bundlePath: app.path, caskroomPath: root.appending(path: "missing").path, standardBundlePath: app.path, environment: env)
        #expect(!noCaskroom.canUpgradeInPlace)
        #expect(!noCaskroom.caskroomPresent)

        let devBuild = UpgradeCapability.detect(
            bundlePath: root.appending(path: "build/tkzmux.app").path, caskroomPath: caskroom.path,
            standardBundlePath: app.path, environment: env)
        #expect(!devBuild.canUpgradeInPlace)
        #expect(!devBuild.isStandardInstall)

        // TKZMUX_UPDATE_BREW=1 waives only the bundle-path test.
        let forced = UpgradeCapability.detect(
            bundlePath: root.appending(path: "build/tkzmux.app").path, caskroomPath: caskroom.path,
            standardBundlePath: app.path, environment: ["PATH": bin.path, "TKZMUX_UPDATE_BREW": "1"])
        #expect(forced.canUpgradeInPlace)
        let forcedOff = UpgradeCapability.detect(
            bundlePath: root.appending(path: "build/tkzmux.app").path, caskroomPath: caskroom.path,
            standardBundlePath: app.path, environment: ["PATH": bin.path, "TKZMUX_UPDATE_BREW": "0"])
        #expect(!forcedOff.canUpgradeInPlace)
    }

    @Test("resolveBrewPath walks PATH and skips directories and non-executables")
    func resolve() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "tkzmux-brew-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first", directoryHint: .isDirectory)
        let second = root.appending(path: "second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first.appending(path: "brew"), withIntermediateDirectories: true)  // a directory named brew
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let plain = second.appending(path: "brew", directoryHint: .notDirectory)
        try Data("#!/bin/sh\n".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        let search = "\(first.path):\(second.path):"
        // Neither the directory nor the non-executable counts; only the real prefixes remain.
        let found = UpgradeCapability.resolveBrewPath(searchPath: search)
        #expect(found == nil || found!.hasPrefix("/opt/homebrew") || found!.hasPrefix("/usr/local"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.path)
        #expect(UpgradeCapability.resolveBrewPath(searchPath: search) == plain.path)
    }
}
