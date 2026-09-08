// Schema dispatch for `state.json`.
//
// Migrations run on the *raw* JSON object, before anything is typed-decoded. That is the only order
// that works: a v2 file whose `sessions[]` changed shape cannot be decoded as v1 in order to be
// migrated to v2. It also means a migration is written once, against the shape that was actually on
// disk, rather than against whatever the models look like today.
//
// v1 is the first version, so its migration is a no-op. The interesting half is the *refusal*:
// see `MigrationError.futureVersion`.

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
        // v1 is the first version; there is nothing below it to lift. Later versions add a case
        // here, each one raising `schemaVersion` by exactly one so the chain composes.
        switch version {
        case 1: return object
        default: throw MigrationError.notAStateFile
        }
    }
}
