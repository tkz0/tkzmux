// StateFileTests — `state.json` v1 (M5.1 / TKZ-29).
//
// Everything here writes into a fresh directory under `FileManager.default.temporaryDirectory` and
// removes it afterwards: nothing may touch `~/Library/Application Support/tkzmux`.
//
// The 50×SIGKILL crash acceptance cannot live in a test bundle — it needs a process to kill — and
// follows the `SnapshotsTests` precedent of running in the harness instead:
// `tkzmux-vtdump state-churn` driven by `scripts/state-crash-test.sh`, recorded in
// docs/manual-checks.md.

import Foundation
import Testing
import TkzCore

@testable import Persistence

// MARK: - Helpers

private func withTemporaryFile(_ body: (StateFile) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-state-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try body(StateFile(url: directory.appending(path: "state.json", directoryHint: .notDirectory)))
}

/// A state with something of every persisted kind in it.
private func makeState() -> AppState {
    var state = AppState()
    let alpha = state.addGroup(name: "Alpha", repoRoot: "~/dev/alpha", color: RGB(r: 0.2, g: 0.3, b: 0.4))
    var beta = state.addGroup(name: "Beta", repoRoot: "/tmp/beta")
    beta.isCollapsed = true
    state.groups[beta.id] = beta
    let one = state.createSession(groupID: alpha.id, cwd: "~/dev/alpha", title: "review")
    let two = state.createSession(
        groupID: beta.id, cwd: "/tmp/beta", repoRoot: "/tmp/beta",
        worktreePath: "/tmp/beta/.claude/worktrees/x", isWorktree: true, accountKey: "claude-work")
    state.select(one.id)
    _ = state.addPreset(Preset(name: "worktree", command: "claude -w", cwdMode: .worktree(name: "x")))
    _ = state.addPreset(Preset(name: "fixed", command: "claude", cwdMode: .fixed(path: "/tmp")))
    state.shortcuts = ["newSession": "cmd+t", "palette": "cmd+shift+p"]
    state.windowFrame = CGRect(x: 12, y: 34, width: 1100, height: 760)
    state.sidebarWidth = 372
    state.setSidebarVisible(false)
    state.setAutoResumeOnLaunch(true)
    // A split and a second tab, so every assertion built on this fixture covers the layout too.
    _ = state.splitPane(two.focusedTerminalID, axis: .vertical, ratio: 0.3)
    _ = state.addTab(to: two.id)
    state.selectTab(two.activeTab)
    return state
}

// MARK: - Paths

@Test func standardFileSitsBesideTheSnapshots() {
    let base = URL(fileURLWithPath: "/var/empty/AppSupport")
    let file = StateFile.standard(applicationSupport: base)
    #expect(file.url.path == "/var/empty/AppSupport/tkzmux/state.json")
    #expect(file.backupURL.lastPathComponent == "state.json.bak")
    #expect(file.directory == SnapshotStore.standard(applicationSupport: base).directory
        .deletingLastPathComponent())
}

// MARK: - Round trip

@Test func roundTripsEveryPersistedField() throws {
    try withTemporaryFile { file in
        let original = makeState()
        try file.save(StateDocument(state: PersistedState(original)))

        let loaded = file.load()
        #expect(loaded.source == .primary)
        var restored = AppState()
        let warnings = try #require(loaded.document).state.apply(to: &restored)
        #expect(warnings.isEmpty)

        #expect(restored.groups == original.groups)
        #expect(restored.sessions == original.sessions)
        #expect(restored.presets == original.presets)
        #expect(restored.selection == original.selection)
        #expect(restored.sidebarVisible == original.sidebarVisible)
        #expect(restored.sidebarWidth == original.sidebarWidth)
        #expect(restored.windowFrame == original.windowFrame)
        #expect(restored.shortcuts == original.shortcuts)
        #expect(restored.autoResumeOnLaunch == original.autoResumeOnLaunch)
    }
}

@Test func aFileWithoutPreferencesLoadsWithTheDefaults() throws {
    // Every state.json written before M5.2 has no `preferences` key; it must still load, and a
    // missing switch means off.
    var state = makeState()
    state.setAutoResumeOnLaunch(false)
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: PersistedState(state))))
    object["preferences"] = nil
    let data = try JSONEncoder().encode(object)
    let decoded = try StateFile.decode(data)
    #expect(decoded.state.preferences == PersistedPreferences())
    var restored = AppState()
    decoded.state.apply(to: &restored)
    #expect(restored.autoResumeOnLaunch == false)
    #expect(restored.sessions.count == state.sessions.count)
}

@Test func groupsAndSessionsAreArraysInSidebarOrder() throws {
    let state = makeState()
    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    let object = try JSONDecoder().decode([String: JSONValue].self, from: data)

    guard case .array(let groups)? = object["groups"] else { Issue.record("groups is not an array"); return }
    #expect(groups.count == 2)
    #expect(groups.first?.objectValue?["name"]?.stringValue == "Alpha")
    guard case .array(let sessions)? = object["sessions"] else { Issue.record("no sessions"); return }
    #expect(sessions.count == 2)
    #expect(object["schemaVersion"]?.intValue == 2)
    // Explicit keys, not CGRect's `[[x,y],[w,h]]`.
    #expect(object["windowFrame"]?.objectValue?["width"] != nil)
}

@Test func liveStateNeverReachesTheFile() throws {
    var state = makeState()
    let id = try #require(state.orderedSessions.first?.id)
    state.setLive(LiveSessionState(pid: 4242, status: .working, attention: true), for: id)

    // The *projection* drops it too, not only the JSON: `StateAutosaver` decides whether to write
    // by comparing projections, so one that carried `live` would write on every status flip.
    #expect(PersistedState(state).sessions.allSatisfy { $0.live == nil })

    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("\"live\""))
    // Assert on the *keys*, not on the pid: a random UUID can contain any digit string, and
    // searching for "4242" made this test fail roughly one run in thirty for no reason at all.
    for key in ["\"pid\"", "\"status\"", "\"attention\"", "\"ports\""] {
        #expect(!text.contains(key))
    }

    var restored = AppState()
    try StateFile.decode(data).state.apply(to: &restored)
    // The whole restore semantic, and it is free: no `live` means idle until the first show.
    #expect(restored.sessions[id]?.status == .idle)
    #expect(restored.sessions[id]?.needsAttention == false)
}

@Test func datesSurviveExactly() throws {
    // `.iso8601` would truncate to whole seconds and quietly break every equality below.
    var state = AppState()
    let group = state.addGroup(name: "G")
    let session = state.createSession(groupID: group.id, cwd: "/tmp")
    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    var restored = AppState()
    try StateFile.decode(data).state.apply(to: &restored)
    #expect(restored.sessions[session.id]?.createdAt == session.createdAt)
    #expect(restored.sessions[session.id]?.lastActiveAt == session.lastActiveAt)
}

@Test(arguments: [CwdMode.repoRoot, .worktree(name: nil), .worktree(name: "x"), .fixed(path: "/tmp")])
func cwdModeRoundTrips(_ mode: CwdMode) throws {
    // Hand-written coding, because the synthesized enum wire form is not a contract.
    let preset = Preset(name: "p", command: "claude", cwdMode: mode)
    let data = try JSONEncoder().encode(preset)
    #expect(try JSONDecoder().decode(Preset.self, from: data) == preset)
}

// MARK: - Property test

@Test func aThousandMutationSequencesRoundTrip() throws {
    var generator = SeededGenerator(seed: 0x5EED_1234)
    var state = AppState()
    let group = state.addGroup(name: "root", repoRoot: "/tmp")
    var groupIDs = [group.id]

    for step in 0..<1000 {
        switch Int.random(in: 0..<14, using: &generator) {
        case 0:
            groupIDs.append(state.addGroup(name: "g\(step)", repoRoot: "/tmp/\(step)").id)
        case 1:
            if let target = groupIDs.randomElement(using: &generator) {
                state.toggleGroupCollapsed(target)
            }
        case 2:
            if let target = groupIDs.randomElement(using: &generator) {
                _ = state.createSession(groupID: target, cwd: "/tmp/\(step)", title: "s\(step)")
            }
        case 3:
            if let target = state.orderedSessions.randomElement(using: &generator)?.id {
                state.renameSession(target, title: "renamed-\(step)")
            }
        case 4:
            if let target = state.orderedSessions.randomElement(using: &generator)?.id {
                state.removeSession(target)
            }
        case 5:
            if let target = state.orderedSessions.randomElement(using: &generator)?.id,
               let destination = groupIDs.randomElement(using: &generator)
            {
                state.moveSession(target, toGroup: destination, at: 0)
            }
        case 6:
            state.select(state.orderedSessions.randomElement(using: &generator)?.id)
        case 7:
            _ = state.addPreset(Preset(name: "p\(step)", command: "claude", cwdMode: .repoRoot))
        case 8:
            state.shortcuts["k\(step % 7)"] = "cmd+\(step % 9)"
            state.setSidebarVisible(step % 2 == 0)
            state.sidebarWidth = CGFloat(240 + step % 200)
            state.setAutoResumeOnLaunch(step % 3 == 0)
        case 9:
            state.windowFrame = CGRect(
                x: Double(step % 40), y: Double(step % 30),
                width: 800 + Double(step % 400), height: 600 + Double(step % 200))
        case 10:
            // Splits and closes, so the property test walks trees rather than only single leaves.
            if let session = state.orderedSessions.randomElement(using: &generator),
                let leaf = session.terminalIDs.randomElement(using: &generator)
            {
                _ = state.splitPane(
                    leaf, axis: step.isMultiple(of: 2) ? .horizontal : .vertical,
                    ratio: 0.2 + Double(step % 6) * 0.1)
            }
        case 11:
            if let session = state.orderedSessions.randomElement(using: &generator),
                let leaf = session.terminalIDs.randomElement(using: &generator)
            {
                _ = state.closePane(leaf)
            }
        case 12:
            if let session = state.orderedSessions.randomElement(using: &generator) {
                if step.isMultiple(of: 3) {
                    _ = state.addTab(to: session.id)
                } else if let tab = session.tabs.randomElement(using: &generator) {
                    _ = state.closeTab(tab.id)
                }
            }
        default:
            // Focus, zoom and a divider drag: durable, and all three must survive the file.
            if let session = state.orderedSessions.randomElement(using: &generator),
                let leaf = session.terminalIDs.randomElement(using: &generator)
            {
                state.focusPane(leaf)
                state.setRatio(above: leaf, to: 0.15 + Double(step % 7) * 0.1)
                if step.isMultiple(of: 5) { state.zoomPane(leaf, in: session.id) }
                if step.isMultiple(of: 11) { state.equalizeSplits(in: session.id) }
            }
        }

        let projected = PersistedState(state)
        let decoded = try StateFile.decode(StateFile.encode(StateDocument(state: projected))).state
        guard decoded == projected else {
            Issue.record("round trip differs at step \(step)")
            return
        }
    }
}

/// A tiny reproducible PRNG: a failing sequence must be replayable from the seed alone.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Layout (TKZ-36)

/// An old file has no `tabs` key at all. It must still load, and every row must come back with
/// exactly one pane whose id is the session's own — the property that lets a v1 `<uuid>.ghsnap`
/// keep working with no rename.
@Test func aV1SessionWithoutTabsStillLoads() throws {
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: PersistedState(makeState()))))
    object["schemaVersion"] = .number(1)
    object["sessions"] = .array(
        try #require(object["sessions"]?.arrayValue).map { value in
            guard case .object(var fields) = value else { return value }
            fields["tabs"] = nil
            fields["activeTab"] = nil
            return .object(fields)
        })

    let decoded = try StateFile.decode(StateFile.makeEncoder().encode(object))
    var state = AppState()
    let warnings = decoded.state.apply(to: &state)
    #expect(warnings.isEmpty)
    for session in state.sessions.values {
        #expect(session.terminalIDs == [TerminalID(uuid: session.id.uuid)])
        #expect(session.activeTab == TabID(uuid: session.id.uuid))
    }
}

@Test func splitsTabsAndRatiosSurviveTheFile() throws {
    let projected = PersistedState(makeState())
    let decoded = try StateFile.decode(StateFile.encode(StateDocument(state: projected))).state
    #expect(decoded == projected)

    let split = try #require(decoded.sessions.first { $0.terminalCount > 1 })
    #expect(split.tabs.count == 2)
    guard case .split(let node) = split.tabs[0].root else {
        Issue.record("the split did not survive")
        return
    }
    #expect(node.axis == .vertical)
    #expect(node.ratio == 0.3)
}

/// The repairs in `Session.normalizeLayout`, each through the real load path.
@Test func aTabFocusingAPaneItDoesNotHoldIsRepairedAndReported() throws {
    var state = makeState()
    let victim = try #require(state.sessions.values.first)
    state.sessions[victim.id]?.tabs[0].focusedLeaf = .generate()

    var restored = AppState()
    let warnings = PersistedState(state).apply(to: &restored)
    #expect(warnings.contains { $0.contains("focuses a pane it does not contain") })
    let repaired = try #require(restored.sessions[victim.id])
    #expect(repaired.tabs[0].root.contains(repaired.tabs[0].focusedLeaf))
}

@Test func anUnknownActiveTabIsRepairedAndReported() throws {
    var state = makeState()
    let victim = try #require(state.sessions.values.first)
    state.sessions[victim.id]?.activeTab = .generate()

    var restored = AppState()
    let warnings = PersistedState(state).apply(to: &restored)
    #expect(warnings.contains { $0.contains("unknown active tab") })
    let repaired = try #require(restored.sessions[victim.id])
    #expect(repaired.tabs.contains { $0.id == repaired.activeTab })
}

/// A terminal id is a `.ghsnap` basename, so uniqueness is file-wide, not per row.
@Test func aTerminalIDReusedInTwoRowsIsRegeneratedAndReported() throws {
    var state = makeState()
    let ids = state.sessions.keys.sorted()
    let shared = TerminalID.generate()
    for id in ids.prefix(2) {
        let tab = Tab.single(shared)
        state.sessions[id]?.tabs = [tab]
        state.sessions[id]?.activeTab = tab.id
    }

    var restored = AppState()
    let warnings = PersistedState(state).apply(to: &restored)
    #expect(warnings.contains { $0.contains("appears twice") })
    let all = restored.sessions.values.flatMap(\.terminalIDs)
    #expect(Set(all).count == all.count)
}

@Test func anOutOfRangeRatioIsClampedAndReported() throws {
    var state = makeState()
    let victim = try #require(state.sessions.values.first { $0.terminalCount > 1 })
    guard case .split(var node) = victim.tabs[0].root else {
        Issue.record("the fixture lost its split")
        return
    }
    // Reach past `PaneSplit.init`'s own clamp, the way a hand-edited file would.
    node.ratio = 40
    state.sessions[victim.id]?.tabs[0].root = .split(node)

    var restored = AppState()
    let warnings = PersistedState(state).apply(to: &restored)
    #expect(warnings.contains { $0.contains("out-of-range split ratio") })
    guard case .split(let clamped)? = restored.sessions[victim.id]?.tabs[0].root else { return }
    #expect(PaneSplit.ratioRange.contains(clamped.ratio))
}

// MARK: - Restore hygiene

@Test func aDanglingSelectionIsDroppedAndReported() throws {
    let state = makeState()
    let ghost = SessionID.generate()
    var persisted = PersistedState(state)
    persisted.selection = ghost

    var restored = AppState()
    let warnings = persisted.apply(to: &restored)
    #expect(restored.selection == nil)
    #expect(warnings.contains { $0.contains(ghost.rawValue) })
}

@Test func aSessionInAnUnknownGroupIsDroppedAndReported() throws {
    var state = makeState()
    var persisted = PersistedState(state)
    let orphan = state.createSession(groupID: GroupID.generate(), cwd: "/tmp")
    persisted.sessions.append(orphan)

    var restored = AppState()
    let warnings = persisted.apply(to: &restored)
    #expect(restored.sessions[orphan.id] == nil)
    #expect(warnings.contains { $0.contains(orphan.id.rawValue) })
}

@Test func anEmptyFileLeavesTheStartupGroupAlone() {
    var restored = AppState.startup(homeDirectory: "/Users/someone")
    let groups = restored.groups
    PersistedState().apply(to: &restored)
    // A first run and a run after the file was wiped must look the same: one home group, not none.
    #expect(restored.groups == groups)
}

// MARK: - Atomicity and recovery

@Test func theBackupIsWrittenOnTheSecondSaveOnly() throws {
    try withTemporaryFile { file in
        var state = makeState()
        try file.save(StateDocument(state: PersistedState(state)))
        // Nothing to rotate on the first write: `link` fails with ENOENT and the save still works.
        #expect(!FileManager.default.fileExists(atPath: file.backupURL.path))

        let first = try Data(contentsOf: file.url)
        state.setSidebarVisible(true)
        try file.save(StateDocument(state: PersistedState(state)))
        #expect(try Data(contentsOf: file.backupURL) == first)
        #expect(try Data(contentsOf: file.url) != first)
        // The staging file never survives a save.
        #expect(!FileManager.default.fileExists(atPath: file.stagedBackupURL.path))
    }
}

@Test func aCorruptPrimaryLoadsTheBackupAndQuarantinesTheCorruption() throws {
    try withTemporaryFile { file in
        let state = makeState()
        try file.save(StateDocument(state: PersistedState(state)))
        try file.save(StateDocument(state: PersistedState(state)))  // now there is a .bak
        try Data("{ not json".utf8).write(to: file.url)

        let loaded = file.load()
        #expect(loaded.source == .backup)
        #expect(loaded.document?.state == PersistedState(state))
        #expect(loaded.notice == "Restored sidebar from backup")
        #expect(loaded.quarantined.count == 1)
        #expect(loaded.quarantined.first?.lastPathComponent.hasPrefix("state.json.corrupt-") == true)
        // The corrupt primary must be *gone*, not merely unread: the next save hard-links the
        // primary onto `.bak`, so leaving it would destroy the only readable copy.
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }
}

@Test func savingAfterABackupRecoveryKeepsTheGoodCopy() throws {
    try withTemporaryFile { file in
        let state = makeState()
        try file.save(StateDocument(state: PersistedState(state)))
        try file.save(StateDocument(state: PersistedState(state)))
        try Data("{ not json".utf8).write(to: file.url)

        let recovered = try #require(file.load().document)
        // The state the user gets back must still be there after the app writes again — this is the
        // sequence that a naive `unlink(.bak); link(...)` rotation loses.
        try file.save(recovered)
        #expect(file.load().source == .primary)
        #expect(file.load().document?.state == PersistedState(state))
    }
}

@Test func anUnreadablePrimaryIsQuarantinedToo() throws {
    try withTemporaryFile { file in
        let state = makeState()
        try file.save(StateDocument(state: PersistedState(state)))
        try file.save(StateDocument(state: PersistedState(state)))
        // Present but unreadable — a mode change, a half-restored backup. `Data(contentsOf:)`
        // fails exactly as it does for a corrupt file, and leaving it in place would let the next
        // save hard-link it over the only good copy.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.url.path)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: file.url.path) }

        let loaded = file.load()
        #expect(loaded.source == .backup)
        #expect(loaded.quarantined.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }
}

@Test func aMissingPrimaryWithABackupIsRecoveryNotCorruption() throws {
    try withTemporaryFile { file in
        let state = makeState()
        try file.save(StateDocument(state: PersistedState(state)))
        try file.save(StateDocument(state: PersistedState(state)))
        try FileManager.default.removeItem(at: file.url)

        let loaded = file.load()
        #expect(loaded.source == .backup)
        // There was nothing to quarantine: an absent file is not a damaged one.
        #expect(loaded.quarantined.isEmpty)
    }
}

@Test func bothCorruptStartsEmptyAndKeepsTheEvidence() throws {
    try withTemporaryFile { file in
        try Data("garbage".utf8).write(to: file.url)
        try Data("also garbage".utf8).write(to: file.backupURL)

        let loaded = file.load()
        #expect(loaded.source == .empty)
        #expect(loaded.document == nil)
        #expect(loaded.quarantined.count == 2)
        #expect(loaded.notice != nil)
        for kept in loaded.quarantined {
            #expect(FileManager.default.fileExists(atPath: kept.path))
        }
    }
}

@Test func noFileAtAllIsSilent() throws {
    try withTemporaryFile { file in
        let loaded = file.load()
        #expect(loaded.source == .empty)
        #expect(loaded.quarantined.isEmpty)
        #expect(loaded.notice == nil)   // a first run is not an incident
        #expect(loaded.isWritable)
    }
}

@Test func launchSweepsWhatACrashMidSaveLeftBehind() throws {
    try withTemporaryFile { file in
        let state = makeState()
        try file.save(StateDocument(state: PersistedState(state)))

        // What `scripts/state-crash-test.sh` measured: a SIGKILL between the `link` and the final
        // `rename` strands these. Harmless, but nothing else would ever remove them.
        try Data("stale".utf8).write(to: file.stagedBackupURL)
        try Data("stale".utf8).write(
            to: file.directory.appending(path: ".state.999.tmp", directoryHint: .notDirectory))

        #expect(file.load().source == .primary)
        #expect(!FileManager.default.fileExists(atPath: file.stagedBackupURL.path))
        let left = try FileManager.default.contentsOfDirectory(atPath: file.directory.path)
        #expect(!left.contains { $0.hasSuffix(".tmp") })
        // …and the real file is untouched.
        #expect(file.load().document?.state == PersistedState(state))
    }
}

@Test func twoQuarantinesInTheSameSecondDoNotCollide() throws {
    try withTemporaryFile { file in
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("garbage".utf8).write(to: file.url)
        try Data("garbage".utf8).write(to: file.backupURL)
        let first = file.load(now: now)
        try Data("garbage".utf8).write(to: file.url)
        let second = file.load(now: now)
        #expect(first.quarantined.count == 2)
        #expect(second.quarantined.count == 1)
        #expect(!first.quarantined.contains(second.quarantined[0]))
    }
}
