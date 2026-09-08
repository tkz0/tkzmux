// A minimal JSON tree, used by `StateFile` for exactly one job: preserving top-level keys that a
// *newer* version of tkzmux wrote and this build knows nothing about.
//
// The alternative — decoding straight into `PersistedState` — silently drops them, so a user who
// runs a new build once and an old build afterwards loses whatever the new build added. Keeping the
// unknown keys in a `[String: JSONValue]` bag and re-emitting them on save makes the round trip
// lossless at the top level. Nested unknown keys (inside a session or a group object) are *not*
// preserved: that would need a `JSONValue` shadow of every model, which is a lot of machinery for a
// case migrations do not need.

import Foundation

public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? c.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }

    // MARK: Convenience

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
