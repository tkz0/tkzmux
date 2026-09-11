// MigrationsTests — schema dispatch and the forward-compatibility guarantee (M5.1 / TKZ-29).

import Foundation
import Testing
import TkzCore

@testable import Persistence

private func makeMinimalState() -> PersistedState {
    var state = AppState()
    let group = state.addGroup(name: "G", repoRoot: "/tmp")
    _ = state.createSession(groupID: group.id, cwd: "/tmp")
    return PersistedState(state)
}

@Test func theCurrentVersionIsANoOp() throws {
    let object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: makeMinimalState())))
    #expect(object["schemaVersion"]?.intValue == 3)
    #expect(try Migrations.migrate(object) == object)
}

/// The v2 → v3 lift: the presets feature's keys leave the file, top level and per session.
@Test func aV2FileLosesItsPresetsAndPresetIDs() throws {
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: makeMinimalState())))
    object["schemaVersion"] = .number(2)
    object["presets"] = .array([
        .object(["id": .string("A"), "name": .string("p"), "command": .string("claude")])
    ])
    object["sessions"] = .array(
        try #require(object["sessions"]?.arrayValue).map { value in
            guard case .object(var fields) = value else { return value }
            fields["presetID"] = .string("A")
            return .object(fields)
        })

    let lifted = try Migrations.migrate(object)
    #expect(lifted["schemaVersion"]?.intValue == 3)
    #expect(lifted["presets"] == nil)
    let session = try #require(lifted["sessions"]?.arrayValue?.first)
    guard case .object(let fields) = session else { Issue.record("not an object"); return }
    #expect(fields["presetID"] == nil)
    #expect(fields["tabs"] != nil, "nothing else about the session is touched")

    // And a v2 file that never had presets is only renumbered.
    var bare = object
    bare["presets"] = nil
    let expected = try Migrations.migrate(object)
    #expect(try Migrations.migrate(bare) == expected)
}

@Test func theV2LiftIsIdempotent() throws {
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: makeMinimalState())))
    object["schemaVersion"] = .number(2)
    object["presets"] = .array([])
    let once = Migrations.liftV2ToV3(object)
    #expect(Migrations.liftV2ToV3(once) == once)
}

/// A v1 file chains through both lifts: it gains pane trees *and* loses its presets.
@Test func aV1FileMigratesAllTheWayToTheCurrentVersion() throws {
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: makeMinimalState())))
    object["schemaVersion"] = .number(1)
    object["presets"] = .array([])
    object["sessions"] = .array(
        try #require(object["sessions"]?.arrayValue).map { value in
            guard case .object(var fields) = value else { return value }
            fields["tabs"] = nil
            fields["activeTab"] = nil
            fields["presetID"] = .string("A")
            return .object(fields)
        })

    let lifted = try Migrations.migrate(object)
    #expect(lifted["schemaVersion"]?.intValue == PersistedState.currentSchemaVersion)
    #expect(lifted["presets"] == nil)
    let session = try #require(lifted["sessions"]?.arrayValue?.first)
    guard case .object(let fields) = session else { Issue.record("not an object"); return }
    #expect(fields["presetID"] == nil)
    #expect(fields["tabs"]?.arrayValue?.count == 1)
    // Typed decoding accepts the result — the whole point of migrating before decoding.
    let normalized = try StateFile.makeEncoder().encode(lifted)
    _ = try JSONDecoder().decode(PersistedState.self, from: normalized)
}

/// The v1 → v2 lift, and the property the whole migration was shaped around: the migrated leaf's
/// id **is** the session's, so the `<uuid>.ghsnap` written by a v1 build is still the right file.
@Test func aV1SessionGainsOneTabWhoseIDsAreItsOwn() throws {
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: makeMinimalState())))
    object["schemaVersion"] = .number(1)
    object["sessions"] = .array(
        try #require(object["sessions"]?.arrayValue).map { value in
            guard case .object(var fields) = value else { return value }
            fields["tabs"] = nil
            fields["activeTab"] = nil
            return .object(fields)
        })

    // The lift on its own, not `migrate`: this test is about v1 → v2, and `migrate` carries on
    // to the current version (`aV1FileMigratesAllTheWayToTheCurrentVersion` covers the chain).
    let lifted = Migrations.liftV1ToV2(object)
    #expect(lifted["schemaVersion"]?.intValue == 2)

    let session = try #require(lifted["sessions"]?.arrayValue?.first)
    guard case .object(let fields) = session else { Issue.record("not an object"); return }
    let id = try #require(fields["id"]?.stringValue)
    let tabs = try #require(fields["tabs"]?.arrayValue)
    #expect(tabs.count == 1)
    #expect(fields["activeTab"]?.stringValue == id)
    guard case .object(let tab) = tabs[0] else { Issue.record("not an object"); return }
    #expect(tab["id"]?.stringValue == id)
    #expect(tab["focusedLeaf"]?.stringValue == id)
    guard case .object(let root) = try #require(tab["root"]) else {
        Issue.record("not an object")
        return
    }
    #expect(root["kind"]?.stringValue == "leaf")
    #expect(root["id"]?.stringValue == id)
}

/// Re-running the lift on its own output must change nothing, or a chained migration would
/// double-wrap every row.
@Test func theV1LiftIsIdempotent() throws {
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: makeMinimalState())))
    object["schemaVersion"] = .number(1)
    let once = Migrations.liftV1ToV2(object)
    #expect(Migrations.liftV1ToV2(once) == once)
}

/// Three rows in, three single-leaf trees out — the lift is per session, not per file.
@Test func everyV1SessionIsLifted() throws {
    var state = AppState()
    let group = state.addGroup(name: "G", repoRoot: "/tmp")
    for _ in 0..<3 { _ = state.createSession(groupID: group.id, cwd: "/tmp") }
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: PersistedState(state))))
    object["schemaVersion"] = .number(1)
    object["sessions"] = .array(
        try #require(object["sessions"]?.arrayValue).map { value in
            guard case .object(var fields) = value else { return value }
            fields["tabs"] = nil
            fields["activeTab"] = nil
            return .object(fields)
        })

    let lifted = try Migrations.migrate(object)
    let sessions = try #require(lifted["sessions"]?.arrayValue)
    #expect(sessions.count == 3)
    for value in sessions {
        guard case .object(let fields) = value else { Issue.record("not an object"); return }
        #expect(fields["tabs"]?.arrayValue?.count == 1)
    }
}

/// A session object with no `id` cannot be given a tree; it is passed through and fails typed
/// decoding exactly as it would have before the bump.
@Test func aSessionWithNoIDIsPassedThroughUntouched() throws {
    let object: [String: JSONValue] = [
        "schemaVersion": .number(1),
        "sessions": .array([.object(["cwd": .string("/tmp")])]),
    ]
    let lifted = try Migrations.migrate(object)
    guard case .object(let fields)? = lifted["sessions"]?.arrayValue?.first else {
        Issue.record("not an object")
        return
    }
    #expect(fields["tabs"] == nil)
}

@Test func aFileWithNoSchemaVersionIsNotAStateFile() {
    #expect(throws: MigrationError.notAStateFile) {
        try Migrations.migrate(["groups": .array([])])
    }
}

@Test func aFutureVersionIsRefusedRatherThanGuessedAt() throws {
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: makeMinimalState())))
    let future = Migrations.supportedSchemaVersion + 1
    object["schemaVersion"] = .number(Double(future))
    #expect(throws: MigrationError.futureVersion(found: future, supported: Migrations.supportedSchemaVersion)) {
        try Migrations.migrate(object)
    }
}

@Test func aFutureFileBlocksTheWriterInsteadOfFallingBackToTheBackup() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-migration-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = StateFile(url: directory.appending(path: "state.json", directoryHint: .notDirectory))

    // A perfectly good current-version backup exists. It must *not* be used: the newer build wrote
    // the primary, and loading the older backup would mean writing over whatever it stored.
    try file.save(StateDocument(state: makeMinimalState()))
    try file.save(StateDocument(state: makeMinimalState()))
    var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file.url))
    object["schemaVersion"] = .number(9)
    try StateFile.makeEncoder().encode(object).write(to: file.url)

    let loaded = file.load()
    #expect(loaded.source == .futureVersion(found: 9, supported: Migrations.supportedSchemaVersion))
    #expect(loaded.document == nil)
    #expect(loaded.isWritable == false)
    #expect(loaded.quarantined.isEmpty)   // a newer build's file is not damaged; do not touch it
    #expect(loaded.notice == "state.json is from a newer tkzmux — changes won't be saved")
}

@Test func unknownTopLevelKeysSurviveARoundTrip() throws {
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: makeMinimalState())))
    object["splitLayout"] = .object(["orientation": .string("vertical"), "ratio": .number(0.5)])
    object["futureFlag"] = .bool(true)

    let document = try StateFile.decode(StateFile.makeEncoder().encode(object))
    #expect(document.extras["futureFlag"] == .bool(true))
    #expect(document.extras.count == 2)
    // Semantic equality, not bytes: key order is not a contract.
    let again = try JSONDecoder().decode([String: JSONValue].self, from: StateFile.encode(document))
    #expect(again["splitLayout"] == object["splitLayout"])
    #expect(again["futureFlag"] == .bool(true))
    #expect(again["groups"] == object["groups"])
}

@Test func knownKeysListsExactlyWhatIsEncoded() throws {
    // `knownKeys` is hand-maintained, and `encode` merges `extras` for every key *not* in it. A v2
    // that adds a field and forgets this list would therefore let a stale extra overwrite the
    // freshly-encoded value — silently, and only for users upgrading. This is the guard.
    //
    // Everything optional has to be populated: `selection` and `windowFrame` are simply absent from
    // the JSON when they are nil, so a sparser state proves only a subset.
    var state = AppState()
    let group = state.addGroup(name: "G", repoRoot: "/tmp")
    let session = state.createSession(groupID: group.id, cwd: "/tmp")
    state.select(session.id)
    state.windowFrame = CGRect(x: 1, y: 2, width: 3, height: 4)
    state.sidebarWidth = 320
    state.shortcuts = ["a": "cmd+a"]
    state.setAutoResumeOnLaunch(true)

    let object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: PersistedState(state))))
    #expect(Set(object.keys) == PersistedState.knownKeys)
}

@Test func extrasCannotShadowAKeyThisBuildOwns() throws {
    // A hostile or stale `extras` must never overwrite the real state on the way out.
    let state = makeMinimalState()
    let document = StateDocument(state: state, extras: ["sessions": .string("nope")])
    let decoded = try StateFile.decode(StateFile.encode(document))
    #expect(decoded.state == state)
    #expect(decoded.extras.isEmpty)
}
