// AntigravityHooksInstallerTests — detect / plan / install / uninstall, and above all the shape.
//
// The single most valuable test here is `writesTheShapeThatActuallyFires`. `agy` accepts a
// malformed hooks.json, logs one warning to its own log file, and then runs with no hooks at all —
// so a bug in the emitted shape is invisible everywhere except in Antigravity's log. Both the shape
// that fired and the shape that was silently rejected are committed as fixtures, and this suite
// pins the installer to the first and against the second.

import Foundation
import Testing

@testable import AgentBridge

@Suite struct AntigravityHooksInstallerTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/antigravity")

    static func makeInstaller(_ support: URL) -> AntigravityHooksInstaller {
        AntigravityHooksInstaller(directory: support)
    }

    static func tempDirectory(_ label: String) throws -> URL {
        try ShimTestSupport.makeTempDirectory(label)
    }

    static func readJSON(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: The shape

    /// `PreToolUse`/`PostToolUse` take the grouped `{matcher, hooks}` wrapper; `PreInvocation`,
    /// `PostInvocation` and `Stop` take a flat list of handlers. Getting this backwards is what
    /// produced, from a real `agy`:
    ///
    ///     invalid hook "tkzmux-probe": command hook must specify 'command'
    ///
    /// and a session that ran with no hooks and no other sign of trouble.
    @Test("The emitted file uses the per-event shape that actually fires")
    func writesTheShapeThatActuallyFires() throws {
        let support = try Self.tempDirectory("antigravity-support")
        let configDir = try Self.tempDirectory("antigravity-config")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: configDir)
        }

        let installer = Self.makeInstaller(support)
        try installer.install(configDir: configDir.path, accountKey: "antigravity", fileManager: .default)

        let root = try Self.readJSON(AntigravityHooksInstaller.hooksPath(configDir: configDir.path))
        let spec = try #require(root["tkzmux"] as? [String: Any])

        // Flat events: the array holds handler objects directly, each with its own `command`.
        for event in ["PreInvocation", "PostInvocation", "Stop"] {
            let array = try #require(spec[event] as? [[String: Any]], "\(event)")
            #expect(array.count == 1, "\(event)")
            let handler = try #require(array.first, "\(event)")
            #expect(handler["command"] is String, "\(event): a flat event's entry IS the handler")
            #expect(handler["hooks"] == nil, "\(event) must not carry the grouped wrapper")
            #expect(handler["matcher"] == nil, "\(event) ignores matchers")
        }

        // Grouped events: a matcher, and the handlers one level down.
        for event in ["PreToolUse", "PostToolUse"] {
            let array = try #require(spec[event] as? [[String: Any]], "\(event)")
            let group = try #require(array.first, "\(event)")
            #expect(group["matcher"] as? String == "*", "\(event)")
            let hooks = try #require(group["hooks"] as? [[String: Any]], "\(event)")
            #expect(hooks.first?["command"] is String, "\(event)")
            #expect(group["command"] == nil, "\(event): the command belongs inside `hooks`")
        }

        // Only the five events Antigravity actually supports; nothing that would sit in the user's
        // file doing nothing.
        #expect(Set(spec.keys) == Set(AntigravityHooksInstaller.managedEvents))
        #expect(spec["SessionStart"] == nil)
        #expect(spec["PostTurn"] == nil)
    }

    /// The emitted shape matches the fixture captured from the run that actually fired, and differs
    /// from the one that was rejected — so a refactor cannot regress to valid-JSON-that-does-nothing.
    @Test("The emitted shape matches the verified fixture and not the rejected one")
    func matchesTheVerifiedFixture() throws {
        let support = try Self.tempDirectory("antigravity-support-fixture")
        let configDir = try Self.tempDirectory("antigravity-config-fixture")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: configDir)
        }
        let installer = Self.makeInstaller(support)
        try installer.install(configDir: configDir.path, accountKey: "antigravity", fileManager: .default)
        let spec = try #require(
            try Self.readJSON(AntigravityHooksInstaller.hooksPath(configDir: configDir.path))["tkzmux"]
                as? [String: Any])

        let verified = try #require(
            try Self.readJSON(Self.fixtures.appendingPathComponent("hooks-json-verified.json").path)["tkzmux"]
                as? [String: Any])
        #expect(Set(spec.keys) == Set(verified.keys))
        // Structure, not commands: the fixture's paths are a different machine's.
        for event in verified.keys {
            let mineGrouped = (spec[event] as? [[String: Any]])?.first?["hooks"] != nil
            let theirsGrouped = (verified[event] as? [[String: Any]])?.first?["hooks"] != nil
            #expect(mineGrouped == theirsGrouped, "\(event) grouping must match the verified file")
        }

        let rejected = try #require(
            try Self.readJSON(Self.fixtures.appendingPathComponent("hooks-json-rejected.json").path)[
                "tkzmux-probe"] as? [String: Any])
        // The rejected file wraps a flat event. If the installer ever emitted that, this fails.
        let rejectedStop = try #require(rejected["Stop"] as? [[String: Any]])
        #expect(rejectedStop.first?["hooks"] != nil, "the fixture is the wrapped-flat-event mistake")
        let mineStop = try #require(spec["Stop"] as? [[String: Any]])
        #expect(mineStop.first?["hooks"] == nil, "and the installer must not make it")
    }

    // MARK: Detect

    @Test("Detection reports none, then tkzmux, across an install")
    func detectionFollowsTheInstall() throws {
        let support = try Self.tempDirectory("antigravity-support-detect")
        let configDir = try Self.tempDirectory("antigravity-config-detect")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: configDir)
        }
        let installer = Self.makeInstaller(support)
        #expect(installer.detect(configDir: configDir.path).producer == .none)
        #expect(!installer.isInstalled(configDir: configDir.path, fileManager: .default))

        try installer.install(configDir: configDir.path, accountKey: "antigravity", fileManager: .default)
        #expect(installer.detect(configDir: configDir.path).producer == .tkzmux)
        #expect(installer.isInstalled(configDir: configDir.path, fileManager: .default))
    }

    @Test("A relay pointing at another support directory reads as stale, not as ours")
    func aRelayFromAnotherBuildIsStale() throws {
        let support = try Self.tempDirectory("antigravity-support-stale")
        let other = try Self.tempDirectory("antigravity-support-other")
        let configDir = try Self.tempDirectory("antigravity-config-stale")
        defer {
            for url in [support, other, configDir] { try? FileManager.default.removeItem(at: url) }
        }
        try Self.makeInstaller(other).install(
            configDir: configDir.path, accountKey: "antigravity", fileManager: .default)

        // A second checkout, an older install, a `.build` binary — the paths reported are exactly
        // what a repair would repoint.
        guard case .stale(let paths) = Self.makeInstaller(support).detect(configDir: configDir.path).producer
        else {
            Issue.record("expected .stale")
            return
        }
        #expect(!paths.isEmpty)
        #expect(paths.allSatisfy { $0.contains(other.lastPathComponent) })
    }

    @Test("Someone else's hook reads as other, and install leaves it alone")
    func anotherToolsHookIsPreserved() throws {
        let support = try Self.tempDirectory("antigravity-support-other-tool")
        let configDir = try Self.tempDirectory("antigravity-config-other-tool")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: configDir)
        }
        let path = AntigravityHooksInstaller.hooksPath(configDir: configDir.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let theirs = #"{"lint-checker":{"Stop":[{"type":"command","command":"./lint.sh"}]}}"#
        try Data(theirs.utf8).write(to: URL(fileURLWithPath: path))

        let installer = Self.makeInstaller(support)
        #expect(installer.detect(configDir: configDir.path).producer == .other)

        try installer.install(configDir: configDir.path, accountKey: "antigravity", fileManager: .default)
        let root = try Self.readJSON(path)
        // Namespaced by hook name, so ours is added beside theirs and nothing is replaced.
        #expect(root["lint-checker"] != nil, "the user's own hook survives")
        #expect(root["tkzmux"] != nil)
    }

    // MARK: Plan / uninstall

    @Test("The plan shows the real before and after, and writes nothing")
    func planWritesNothing() throws {
        let support = try Self.tempDirectory("antigravity-support-plan")
        let configDir = try Self.tempDirectory("antigravity-config-plan")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: configDir)
        }
        let installer = Self.makeInstaller(support)
        let plan = try installer.plan(configDir: configDir.path, accountKey: "antigravity")
        #expect(plan.before == nil, "no file yet")
        #expect(plan.after.contains("tkzmux"))
        #expect(plan.hooksPath.hasSuffix("config/hooks.json"))
        #expect(
            !FileManager.default.fileExists(atPath: plan.hooksPath),
            "planning must not write — consent comes first")
    }

    @Test("Uninstall removes our key and keeps everyone else's")
    func uninstallRemovesOnlyOurs() throws {
        let support = try Self.tempDirectory("antigravity-support-uninstall")
        let configDir = try Self.tempDirectory("antigravity-config-uninstall")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: configDir)
        }
        let path = AntigravityHooksInstaller.hooksPath(configDir: configDir.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(#"{"lint-checker":{"Stop":[{"command":"./lint.sh"}]}}"#.utf8)
            .write(to: URL(fileURLWithPath: path))

        let installer = Self.makeInstaller(support)
        try installer.install(configDir: configDir.path, accountKey: "antigravity", fileManager: .default)
        try installer.uninstall(configDir: configDir.path, accountKey: "antigravity", fileManager: .default)

        let root = try Self.readJSON(path)
        #expect(root["tkzmux"] == nil)
        #expect(root["lint-checker"] != nil)
    }

    /// The undo record must never be traded down from one naming a real previous value to one
    /// naming an absence — that is how a user's own file is lost forever.
    @Test("A second install does not overwrite the record of what was there first")
    func theUndoRecordKeepsTheOriginal() throws {
        let support = try Self.tempDirectory("antigravity-support-record")
        let configDir = try Self.tempDirectory("antigravity-config-record")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: configDir)
        }
        let path = AntigravityHooksInstaller.hooksPath(configDir: configDir.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let original = #"{"lint-checker":{"Stop":[{"command":"./lint.sh"}]}}"#
        try Data(original.utf8).write(to: URL(fileURLWithPath: path))

        let installer = Self.makeInstaller(support)
        try installer.install(configDir: configDir.path, accountKey: "antigravity", fileManager: .default)
        try installer.uninstall(configDir: configDir.path, accountKey: "antigravity", fileManager: .default)
        try installer.install(configDir: configDir.path, accountKey: "antigravity", fileManager: .default)

        let record = try Self.readJSON(
            support.appendingPathComponent("antigravity-hooks/previous-antigravity.json").path)
        let before = try #require(record["hooksJson"] as? String)
        #expect(before.contains("lint-checker"), "still the original, not the post-uninstall state")
    }

    @Test("A hooks.json this installer cannot parse is refused rather than rewritten")
    func unparseableFileIsRefused() throws {
        let support = try Self.tempDirectory("antigravity-support-bad")
        let configDir = try Self.tempDirectory("antigravity-config-bad")
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: configDir)
        }
        let path = AntigravityHooksInstaller.hooksPath(configDir: configDir.path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: path))

        // Rewriting a file we do not understand is how a user loses their own hooks.
        #expect(throws: AntigravityHooksInstallerError.self) {
            try Self.makeInstaller(support).plan(configDir: configDir.path, accountKey: "antigravity")
        }
    }
}
