// StateValidateCommand — `tkzmux-vtdump state-validate <file>` (WOR-311 S7).
//
// The check scripts/state-crash-test.sh runs on every state.json and .bak that survives a SIGKILL.
// It replaces four `plutil -extract` calls, which exist only on macOS, and checks more than they
// did: a file passes only when
//
//   1. Persistence decodes it, through `StateFile.decode` (migrations, then the typed
//      `PersistedState`), the path a launch takes, so "parses" means "the app would load it";
//   2. its own `schemaVersion`, read before any migration, is the one this build writes. The
//      survivor of a crash must be a complete old or new save by the same build, never something a
//      migration had to repair. (The plutil check compared against a literal 1, which every file
//      has failed since the schema reached v2.)
//   3. `groups`, `sessions` and `sidebar` are top-level keys.
//
// Exit 0 with a one-line summary on stdout, or 1 with the reason on stderr.

import Foundation
import Persistence

enum StateValidateCommand {
    static func run(_ argv: [String]) throws {
        let arguments = Arguments(argv, valueFlags: [])
        guard let path = arguments.positionals.first, arguments.positionals.count == 1 else {
            fail("tkzmux-vtdump state-validate: expected exactly one <file>", code: 2)
        }
        switch validate(path: path) {
        case .success(let summary):
            print("\(path): \(summary)")
        case .failure(let reason):
            fail("tkzmux-vtdump state-validate: \(path): \(reason.description)", code: 1)
        }
    }

    struct Invalid: Error, CustomStringConvertible {
        let description: String
    }

    static func validate(path: String) -> Result<String, Invalid> {
        guard let data = FileManager.default.contents(atPath: path) else {
            return .failure(Invalid(description: "cannot be read"))
        }
        let document: StateDocument
        do {
            document = try StateFile.decode(data)
        } catch {
            return .failure(Invalid(description: "does not decode: \(error)"))
        }
        guard let raw = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return .failure(Invalid(description: "is not a JSON object"))
        }
        let expected = PersistedState.currentSchemaVersion
        guard let version = raw["schemaVersion"]?.intValue else {
            return .failure(Invalid(description: "has no numeric schemaVersion"))
        }
        guard version == expected else {
            return .failure(Invalid(description: "schemaVersion \(version), this build writes \(expected)"))
        }
        for key in ["groups", "sessions", "sidebar"] where raw[key] == nil {
            return .failure(Invalid(description: "has no \(key)"))
        }
        return .success("schemaVersion \(version), \(document.state.groups.count) groups, "
            + "\(document.state.sessions.count) sessions")
    }
}
