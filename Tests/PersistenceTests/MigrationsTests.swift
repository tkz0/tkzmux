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

@Test func v1IsANoOp() throws {
    let object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: makeMinimalState())))
    #expect(try Migrations.migrate(object) == object)
}

@Test func aFileWithNoSchemaVersionIsNotAStateFile() {
    #expect(throws: MigrationError.notAStateFile) {
        try Migrations.migrate(["groups": .array([])])
    }
}

@Test func aFutureVersionIsRefusedRatherThanGuessedAt() throws {
    var object = try JSONDecoder().decode(
        [String: JSONValue].self, from: StateFile.encode(StateDocument(state: makeMinimalState())))
    object["schemaVersion"] = .number(2)
    #expect(throws: MigrationError.futureVersion(found: 2, supported: 1)) {
        try Migrations.migrate(object)
    }
}

@Test func aFutureFileBlocksTheWriterInsteadOfFallingBackToTheBackup() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-migration-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = StateFile(url: directory.appending(path: "state.json", directoryHint: .notDirectory))

    // A perfectly good v1 backup exists. It must *not* be used: the newer build wrote the primary,
    // and loading the older backup would mean writing v1 straight over whatever v2 stored.
    try file.save(StateDocument(state: makeMinimalState()))
    try file.save(StateDocument(state: makeMinimalState()))
    var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file.url))
    object["schemaVersion"] = .number(9)
    try StateFile.makeEncoder().encode(object).write(to: file.url)

    let loaded = file.load()
    #expect(loaded.source == .futureVersion(found: 9, supported: 1))
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
    _ = state.addPreset(Preset(name: "p", command: "claude"))
    state.shortcuts = ["a": "cmd+a"]

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
