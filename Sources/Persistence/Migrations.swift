// Schema dispatch for `state.json`.
//
// Migrations run on the *raw* JSON object, before anything is typed-decoded. That is the only order
// that works: a v2 file whose `sessions[]` changed shape cannot be decoded as v1 in order to be
// migrated to v2. It also means a migration is written once, against the shape that was actually on
// disk, rather than against whatever the models look like today.
//
// v2 (TKZ-36) gives every session a pane tree; v3 drops the presets feature and the keys it
// wrote. The interesting half of this file is still the *refusal*: see
// `MigrationError.futureVersion`.

import Foundation

public enum MigrationError: Error, Equatable, Sendable {
    /// No `schemaVersion` key: not a tkzmux state file (or truncated past recognition).
    case notAStateFile
    /// The file was written by a newer tkzmux. We must neither read it (we would misread it) nor
    /// write over it (we would destroy whatever the newer build stored). The app runs, the
    /// autosaver stays latched off, and the user is told.
    case futureVersion(found: Int, supported: Int)
}

public enum Migrations {
    public static let supportedSchemaVersion = PersistedState.currentSchemaVersion

    /// Brings a raw state object up to `supportedSchemaVersion`.
    public static func migrate(_ object: [String: JSONValue]) throws -> [String: JSONValue] {
        guard let version = object["schemaVersion"]?.intValue else { throw MigrationError.notAStateFile }
        guard version <= supportedSchemaVersion else {
            throw MigrationError.futureVersion(found: version, supported: supportedSchemaVersion)
        }
        // One case per version, each raising `schemaVersion` by exactly one and re-entering, so
        // the chain composes however far back the file is.
        switch version {
        case 1: return try migrate(liftV1ToV2(object))
        case 2: return try migrate(liftV2ToV3(object))
        case 3: return object
        default: throw MigrationError.notAStateFile
        }
    }

    /// v1 → v2: every session gains a pane tree of one tab holding one leaf.
    ///
    /// The leaf's `TerminalID` and the tab's `TabID` are the session's **own** uuid. That is the
    /// whole trick: a `.ghsnap` is named after the terminal that owns it, so giving the migrated
    /// leaf the session's uuid means not one snapshot file had to be renamed at the bump, and
    /// `TerminalHost.restoreAll` can map a file back to its row with
    /// `SessionID(uuid: terminalID.uuid)` instead of a lookup table.
    ///
    /// The version bump is the point, rather than making `Session.tabs` optional: `JSONValue`
    /// deliberately preserves only *top-level* unknown keys, so a tree nested inside a session
    /// object would be silently dropped by an older build. Refusing to open the file is the only
    /// protection available.
    ///
    /// Idempotent — a session object that already has `tabs` is passed through, so re-running the
    /// lift on its own output changes nothing. One with no `id` is passed through too and fails
    /// typed decoding exactly as it would have before.
    static func liftV1ToV2(_ object: [String: JSONValue]) -> [String: JSONValue] {
        var object = object
        if case .array(let sessions)? = object["sessions"] {
            object["sessions"] = .array(sessions.map(liftSession))
        }
        object["schemaVersion"] = .number(2)
        return object
    }

    /// v2 → v3: the presets feature is gone, and so are the keys it wrote — the top-level
    /// `presets` array and each session's `presetID`.
    ///
    /// A bump rather than a silent drop, for two reasons. `StateFile` carries every top-level key
    /// it does not know as a *newer* build's and re-emits it on every save, so without the bump a
    /// stale `presets` array would ride along in the file forever. And a v2 reader decodes
    /// `presets` as a required key, so a file without it would fail typed decoding there; a v3
    /// version number makes that build refuse the file cleanly instead.
    ///
    /// Idempotent — an object with neither key is passed through unchanged.
    static func liftV2ToV3(_ object: [String: JSONValue]) -> [String: JSONValue] {
        var object = object
        object["presets"] = nil
        if case .array(let sessions)? = object["sessions"] {
            object["sessions"] = .array(sessions.map(dropPresetID))
        }
        object["schemaVersion"] = .number(3)
        return object
    }

    private static func dropPresetID(_ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = value, fields["presetID"] != nil else { return value }
        fields["presetID"] = nil
        return .object(fields)
    }

    private static func liftSession(_ value: JSONValue) -> JSONValue {
        guard case .object(var fields) = value, fields["tabs"] == nil,
            case .string(let id)? = fields["id"]
        else { return value }
        fields["tabs"] = .array([
            .object([
                "id": .string(id),
                "root": .object(["kind": .string("leaf"), "id": .string(id)]),
                "focusedLeaf": .string(id),
            ])
        ])
        fields["activeTab"] = .string(id)
        return .object(fields)
    }
}
