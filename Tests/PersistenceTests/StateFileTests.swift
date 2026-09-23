// StateFileTests — `state.json` v1 (M5.1).
//
// Everything here writes into a fresh directory under `FileManager.default.temporaryDirectory` and
// removes it afterwards: nothing may touch `~/Library/Application Support/tkzmux`.
//
// The 50×SIGKILL crash acceptance cannot live in a test bundle — it needs a process to kill — and
// follows the `SnapshotsTests` precedent of running in the harness instead:
// `tkzmux-vtdump state-churn` driven by `scripts/state-crash-test.sh`.

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
    // A per-group agent, non-default like every other value here, so a round trip that dropped
    // `Group.agent` would fail on the `groups ==` assertion rather than pass by coincidence.
    state.setGroupAgent(beta.id, agent: .codex)
    let one = state.createSession(groupID: alpha.id, cwd: "~/dev/alpha", title: "review")
    let two = state.createSession(
        groupID: beta.id, cwd: "/tmp/beta", repoRoot: "/tmp/beta",
        worktreePath: "/tmp/beta/.claude/worktrees/x", isWorktree: true, accountKey: "claude-work")
    state.select(one.id)
    // A conversation to resume, so the round trip and the on-disk-key test below both see it.
    state.sessions[one.id]?.conversationId = "conv-1"
    state.shortcuts = ["newSession": "cmd+t", "palette": "cmd+shift+p"]
    state.windowFrame = CGRect(x: 12, y: 34, width: 1100, height: 760)
    state.sidebarWidth = 372
    state.setSidebarVisible(false)
    state.setAutoResumeOnLaunch(true)
    // The non-default value, so a round trip that silently dropped it would fail loudly rather
    // than coincidentally matching `PersistedPreferences`'s own default.
    state.setShowSessionSpend(false)
    state.setCheckOriginPeriodically(true)
    // Defaults on, so off is the value a dropped round trip would fail on.
    state.setNotifyOnDone(false)
    state.setBadgeDockIcon(false)
    // Defaults off, like `statuslineOffered` — the non-default value, so a dropped round trip
    // fails loudly (TKZ-87).
    state.setHooksOffered(.codex)
    // A muted row rides on `Session` itself; the `sessions ==` assertion below covers it.
    state.setNotificationsMuted(two.id, true)
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
        // `sessions ==` above already covers these, but the schema v4 fields are new enough
        // (TKZ-79) to earn an assertion of their own rather than ride along silently.
        #expect(restored.sessions.values.allSatisfy { $0.agent == .claude })
        // `groups ==` above already covers this; spelled out because `Group.agent` is new and,
        // being optional, would round-trip "successfully" as `nil` on both sides if it were
        // dropped from the encoder.
        #expect(restored.groups.values.contains { $0.agent == .codex })
        let resumable = try #require(original.orderedSessions.first { $0.conversationId == "conv-1" })
        #expect(restored.sessions[resumable.id]?.conversationId == "conv-1")
            #expect(restored.selection == original.selection)
        #expect(restored.sidebarVisible == original.sidebarVisible)
        #expect(restored.sidebarWidth == original.sidebarWidth)
        #expect(restored.windowFrame == original.windowFrame)
        #expect(restored.shortcuts == original.shortcuts)
        #expect(restored.autoResumeOnLaunch == original.autoResumeOnLaunch)
        #expect(restored.showSessionSpend == original.showSessionSpend)
        #expect(restored.checkOriginPeriodically == original.checkOriginPeriodically)
        #expect(restored.notifyOnDone == original.notifyOnDone)
        #expect(restored.badgeDockIcon == original.badgeDockIcon)
        #expect(restored.hooksOffered == original.hooksOffered)
    }
}

/// `Session.conversationId` is written under its own name now: schema v4 (TKZ-79) renamed the
/// on-disk key from `claudeSessionId`, and `Migrations.liftV3ToV4` is what moves an existing v3
/// file's value across, not an alias on `Session.CodingKeys`.
@Test func conversationIdIsStoredUnderTheV4Key() throws {
    let original = makeState()
    let one = try #require(original.orderedSessions.first { $0.conversationId == "conv-1" })
    let data = try StateFile.encode(StateDocument(state: PersistedState(original)))
    var object = try JSONDecoder().decode([String: JSONValue].self, from: data)

    guard case .array(var sessions)? = object["sessions"] else { Issue.record("no sessions"); return }
    let index = try #require(sessions.firstIndex { $0.objectValue?["id"]?.stringValue == one.id.rawValue })
    var row = try #require(sessions[index].objectValue)
    #expect(row["conversationId"]?.stringValue == "conv-1")
    #expect(row["claudeSessionId"] == nil)

    // And the other direction: the v4 key, as the current release writes it, lands in the field.
    row["conversationId"] = .string("conv-from-disk")
    sessions[index] = .object(row)
    object["sessions"] = .array(sessions)
    var restored = AppState()
    let warnings = try StateFile.decode(JSONEncoder().encode(object)).state.apply(to: &restored)
    #expect(warnings.isEmpty)
    #expect(restored.sessions[one.id]?.conversationId == "conv-from-disk")
}

@Test func theDoneNotificationSwitchRoundTripsAndDefaultsOn() throws {
    let data = try StateFile.encode(StateDocument(state: PersistedState(makeState())))
    var restored = AppState()
    try StateFile.decode(data).state.apply(to: &restored)
    #expect(restored.notifyOnDone == false)

    // A preferences block written before the switch existed has the key missing;
    // missing must mean *on*, like `showSessionSpend` and unlike the other switches.
    var object = try JSONDecoder().decode([String: JSONValue].self, from: data)
    object["preferences"] = .object(["checkOriginPeriodically": .bool(true)])
    var fresh = AppState()
    fresh.setNotifyOnDone(false)
    try StateFile.decode(JSONEncoder().encode(object)).state.apply(to: &fresh)
    #expect(fresh.notifyOnDone == true)
}

@Test func theDockBadgeSwitchRoundTripsAndDefaultsOn() throws {
    let data = try StateFile.encode(StateDocument(state: PersistedState(makeState())))
    var restored = AppState()
    try StateFile.decode(data).state.apply(to: &restored)
    #expect(restored.badgeDockIcon == false)

    // Missing from a file written before TKZ-67 ⇒ on, like `notifyOnDone`.
    var object = try JSONDecoder().decode([String: JSONValue].self, from: data)
    object["preferences"] = .object(["notifyOnDone": .bool(false)])
    var fresh = AppState()
    fresh.setBadgeDockIcon(false)
    try StateFile.decode(JSONEncoder().encode(object)).state.apply(to: &fresh)
    #expect(fresh.badgeDockIcon == true)
}

@Test func theOriginCheckSwitchRoundTripsAndDefaultsOff() throws {
    var state = makeState()
    state.setCheckOriginPeriodically(true)
    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    var restored = AppState()
    try StateFile.decode(data).state.apply(to: &restored)
    #expect(restored.checkOriginPeriodically == true)

    // A preferences block written before the switch existed has the key missing, not the whole
    // object missing: the per-field `decodeIfPresent` fallback in
    // `PersistedPreferences.init(from:)`, not `PersistedState`'s whole-object default.
    var object = try JSONDecoder().decode([String: JSONValue].self, from: data)
    object["preferences"] = .object(["autoResumeOnLaunch": .bool(true)])
    var fresh = AppState()
    try StateFile.decode(JSONEncoder().encode(object)).state.apply(to: &fresh)
    #expect(fresh.checkOriginPeriodically == false)
}

/// `hooksOffered` copies `statuslineOffered`'s plumbing exactly (TKZ-87): no schema bump, a file
/// written before it existed decodes the key as absent, and absent must mean "nobody has been
/// asked" so the sheet is still offered the first time an account needs it.
@Test func theHooksOfferedSetRoundTripsAndDefaultsEmpty() throws {
    var state = makeState()
    state.setHooksOffered(.codex)
    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    var restored = AppState()
    try StateFile.decode(data).state.apply(to: &restored)
    #expect(restored.hooksOffered == [.codex])

    // A preferences block written before the flag existed has the key missing, not the whole
    // object missing — the same per-field `decodeIfPresent` fallback every other switch in
    // `PersistedPreferences.init(from:)` uses.
    var object = try JSONDecoder().decode([String: JSONValue].self, from: data)
    object["preferences"] = .object(["autoResumeOnLaunch": .bool(true)])
    var fresh = AppState()
    fresh.setHooksOffered(.codex)
    try StateFile.decode(JSONEncoder().encode(object)).state.apply(to: &fresh)
    #expect(fresh.hooksOffered.isEmpty)
}

/// The lift. A file written while this was a single `codexHooksOffered: Bool` has to keep meaning
/// what it meant — otherwise upgrading re-asks a question the user already answered.
@Test func aLegacyCodexHooksOfferedBooleanLiftsIntoTheSet() throws {
    let data = try StateFile.encode(StateDocument(state: PersistedState(makeState())))
    var object = try JSONDecoder().decode([String: JSONValue].self, from: data)
    // Exactly what an older build wrote: the boolean, and no `hooksOffered` key at all.
    object["preferences"] = .object(["codexHooksOffered": .bool(true)])

    var restored = AppState()
    try StateFile.decode(JSONEncoder().encode(object)).state.apply(to: &restored)
    #expect(restored.hooksOffered == [.codex])

    // `false` lifts to empty, not to a set containing something.
    object["preferences"] = .object(["codexHooksOffered": .bool(false)])
    var declined = AppState()
    try StateFile.decode(JSONEncoder().encode(object)).state.apply(to: &declined)
    #expect(declined.hooksOffered.isEmpty)
}

/// And the downgrade direction: the legacy key is still written, so a build that predates the set
/// reads the right answer for the agent it knows about rather than asking again.
@Test func theLegacyBooleanIsStillWrittenForOneRelease() throws {
    var state = makeState()
    state.setHooksOffered(.codex)
    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
    guard case .object(let preferences)? = object["preferences"] else {
        Issue.record("no preferences block")
        return
    }
    #expect(preferences["codexHooksOffered"] == .bool(true))
    #expect(preferences["hooksOffered"] == .array([.string("codex")]))

    // An agent the old build never heard of must not set the legacy boolean — that would tell it
    // the user had answered a question about Codex that they never saw. Built from a bare state,
    // because `makeState()` deliberately answers for Codex.
    var other = AppState()
    other.setHooksOffered(.antigravity)
    let otherData = try StateFile.encode(StateDocument(state: PersistedState(other)))
    let otherObject = try JSONDecoder().decode([String: JSONValue].self, from: otherData)
    guard case .object(let otherPreferences)? = otherObject["preferences"] else {
        Issue.record("no preferences block")
        return
    }
    #expect(otherPreferences["codexHooksOffered"] == .bool(false))
    #expect(otherPreferences["hooksOffered"] == .array([.string("antigravity")]))
}

/// The reason the flag became a set: answering for one agent must not answer for another.
@Test func decliningForOneAgentLeavesAnotherUnasked() throws {
    var state = makeState()
    state.setHooksOffered(.codex)
    var restored = AppState()
    try StateFile.decode(try StateFile.encode(StateDocument(state: PersistedState(state))))
        .state.apply(to: &restored)
    #expect(restored.hooksOffered.contains(.codex))
    #expect(!restored.hooksOffered.contains(.antigravity), "a second agent is still to be asked")
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
    #expect(restored.dismissedUpdateVersion == nil)
    // A file predating this switch has no key for it either; missing must default to *on*, unlike
    // every other switch in this block, which defaults off.
    #expect(restored.showSessionSpend == true)
    #expect(restored.notifyOnDone == true)
    #expect(restored.badgeDockIcon == true)
    #expect(restored.hooksOffered.isEmpty)
    #expect(restored.sessions.count == state.sessions.count)
}

@Test func dismissedUpdateVersionRoundTripsAndTheRestOfUpdateDoesNot() throws {
    // The `✕` on the update card is forever, so the version goes to disk; the fetched
    // release and the upgrade phase are process state and must not.
    try withTemporaryFile { file in
        var original = makeState()
        original.dismissUpdate(version: "0.8.0")
        original.setAvailableUpdate(AvailableUpdate(version: "0.9.0", releaseURL: "https://example.invalid"))
        original.setUpgradePhase(.running(step: "update"))
        original.setCanUpgradeInPlace(true)
        try file.save(StateDocument(state: PersistedState(original)))

        var restored = AppState()
        try #require(file.load().document).state.apply(to: &restored)
        #expect(restored.dismissedUpdateVersion == "0.8.0")
        #expect(restored.update == UpdateState())

        // A preferences block written before the update card has no key at all: nil, not "".
        var object = try JSONDecoder().decode(
            [String: JSONValue].self, from: StateFile.encode(StateDocument(state: PersistedState(original))))
        object["preferences"] = .object(["autoResumeOnLaunch": .bool(true)])
        let decoded = try StateFile.decode(try JSONEncoder().encode(object))
        #expect(decoded.state.preferences.dismissedUpdateVersion == nil)
        #expect(decoded.state.preferences.autoResumeOnLaunch)
    }
}

@Test func theThemePresetRoundTripsAndDefaultsWhenAbsent() throws {
    try withTemporaryFile { file in
        var original = makeState()
        original.setThemePreset(.light)
        try file.save(StateDocument(state: PersistedState(original)))

        var restored = AppState()
        try #require(file.load().document).state.apply(to: &restored)
        #expect(restored.themePreset == .light)
    }

    // A preferences block written before the toggle existed has no key at all, and the default
    // preset stands.
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: PersistedState(makeState()))))
    object["preferences"] = .object(["autoResumeOnLaunch": .bool(true)])
    let decoded = try StateFile.decode(try JSONEncoder().encode(object))
    #expect(decoded.state.preferences.themePreset == nil)
    var restored = AppState()
    _ = decoded.state.apply(to: &restored)
    #expect(restored.themePreset == Theme.default.preset)
}

/// A preset name a newer build wrote must warn and keep the default — never throw, which would
/// take the whole file down with it. That is why the field is a raw `String` on the wire.
@Test func anUnknownThemePresetWarnsAndKeepsTheDefault() throws {
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: PersistedState(makeState()))))
    object["preferences"] = .object(["themePreset": .string("solarizedFlamingo")])
    let decoded = try StateFile.decode(try JSONEncoder().encode(object))
    #expect(decoded.state.preferences.themePreset == "solarizedFlamingo")

    var restored = AppState()
    let warnings = decoded.state.apply(to: &restored)
    #expect(restored.themePreset == Theme.default.preset)
    #expect(warnings.contains { $0.contains("solarizedFlamingo") })
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
    #expect(object["schemaVersion"]?.intValue == 4)
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
            state.sidebarWidth = CGFloat(200 + step % 300)
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

// MARK: - Layout

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
