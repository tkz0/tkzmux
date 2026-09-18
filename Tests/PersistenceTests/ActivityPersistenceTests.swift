// ActivityPersistenceTests — the activity feed's log in `state.json`: its own top-level key, no
// schema bump, unread flags that survive a relaunch, and entries for rows that did not come back
// dropped on restore.

import Foundation
import Testing
import TkzCore

@testable import Persistence

/// Two live rows with a feed entry each, one read.
private func makeState() -> (AppState, SessionID, SessionID) {
    var state = AppState()
    let group = state.addGroup(name: "Alpha", repoRoot: "~/dev/alpha")
    let one = state.createSession(groupID: group.id, cwd: "~/dev/alpha", title: "review").id
    let two = state.createSession(groupID: group.id, cwd: "~/dev/alpha/b").id
    state.setLive(LiveSessionState(status: .idle), for: one)
    state.setLive(LiveSessionState(status: .idle), for: two)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    state.applyEvent(.init(kind: .turnEnded, lastAssistantMessage: "one is done"), to: one, now: t0)
    state.applyEvent(
        .init(kind: .attention(.permission), message: "Bash?"),
        to: two, now: t0.addingTimeInterval(1))
    state.select(one, now: t0.addingTimeInterval(2))
    return (state, one, two)
}

@Test func theActivityLogRoundTripsWithItsUnreadFlags() throws {
    let (state, _, _) = makeState()
    #expect(state.activity.map(\.unread) == [false, true])

    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    var restored = AppState()
    let warnings = try StateFile.decode(data).state.apply(to: &restored)
    #expect(warnings.isEmpty)
    #expect(restored.activity == state.activity)
}

/// The activity feed needed no schema bump of its own: it is a *top-level* key, and `JSONValue`
/// preserves unknown top-level keys, so an older build handed one of these files carries the array
/// along untouched instead of dropping it. The assertion is against whatever the current version
/// is — v4 (TKZ-79's `agent` discriminator) bumped it for a reason that has nothing to do with the
/// feed, and pinning a literal here would make every future bump look like an activity regression.
@Test func theActivityKeyIsTopLevelAndNeededNoSchemaBump() throws {
    let (state, _, _) = makeState()
    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
    #expect(object["schemaVersion"] == .number(Double(PersistedState.currentSchemaVersion)))
    if case .array(let entries)? = object["activity"] {
        #expect(entries.count == 2)
    } else {
        Issue.record("activity is not a top-level array")
    }
}

@Test func aFileWithoutAnActivityKeyLoadsAnEmptyLog() throws {
    let (state, _, _) = makeState()
    let data = try StateFile.encode(StateDocument(state: PersistedState(state)))
    var object = try JSONDecoder().decode([String: JSONValue].self, from: data)
    object["activity"] = nil
    var restored = AppState()
    try StateFile.decode(JSONEncoder().encode(object)).state.apply(to: &restored)
    #expect(restored.activity.isEmpty)
    #expect(restored.sessions.count == 2)
}

@Test func entriesForRowsThatDidNotComeBackAreDroppedWithAWarning() throws {
    let (state, one, two) = makeState()
    var persisted = PersistedState(state)
    persisted.activity.append(
        ActivityEvent(
            sessionID: .generate(), kind: .stop(message: "orphan"), at: Date(),
            sessionTitle: "gone", groupName: "", unread: true))
    var restored = AppState()
    let warnings = persisted.apply(to: &restored)
    #expect(restored.activity.map(\.sessionID) == [one, two])
    #expect(warnings.contains { $0.contains("activity") })
}
