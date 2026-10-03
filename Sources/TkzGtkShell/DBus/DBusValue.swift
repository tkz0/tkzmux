// DBusValue — a D-Bus value as plain Swift data, and its typed views (WOR-320 S1).
//
// The wrapper never hands GVariant pointers to its callers: arguments go in as `DBusValue`s,
// replies and signal arguments come out as `DBusValue`s, and GVariantCodec converts at the edge.
// So a value is Sendable, can be compared and stored, and cannot outlive or double-free a GVariant.
//
// Arrays and dictionaries carry their element types, because an empty one still has a type on the
// wire. Dictionaries keep their entries in order (D-Bus and GVariant both do); `vardict` sorts the
// keys of a Swift dictionary so that the same dictionary always marshals the same way.
//
// `DBusRepresentable` is the typed layer over it: `String` is `s`, `[String]` is `as`,
// `[String: DBusVariant]` is `a{sv}`, and so on, with `init(dbusValue:)` throwing
// `DBusError.typeMismatch` instead of trapping on the wrong shape.

import CGtk

public indirect enum DBusValue: Sendable, Hashable, CustomStringConvertible {
    case boolean(Bool)
    case byte(UInt8)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)
    case variant(DBusValue)
    /// `a<element>`: every value is of type `element`.
    case array(DBusType, [DBusValue])
    /// `a{<key><value>}`, in order.
    case dictionary(key: DBusType, value: DBusType, [DBusDictEntry])
    /// `(<fields>)`, at least one field.
    case structure([DBusValue])

    /// This value's complete type.
    public var type: DBusType {
        switch self {
        case .boolean: .boolean
        case .byte: .byte
        case .int16: .int16
        case .uint16: .uint16
        case .int32: .int32
        case .uint32: .uint32
        case .int64: .int64
        case .uint64: .uint64
        case .double: .double
        case .string: .string
        case .objectPath: .objectPath
        case .signature: .signature
        case .variant: .variant
        case .array(let element, _): .array(element)
        case .dictionary(let key, let value, _): .dictionary(key: key, value: value)
        case .structure(let fields): .structure(fields.map(\.type))
        }
    }

    public var description: String {
        switch self {
        case .boolean(let v): "\(v)"
        case .byte(let v): "byte \(v)"
        case .int16(let v): "int16 \(v)"
        case .uint16(let v): "uint16 \(v)"
        case .int32(let v): "int32 \(v)"
        case .uint32(let v): "uint32 \(v)"
        case .int64(let v): "int64 \(v)"
        case .uint64(let v): "uint64 \(v)"
        case .double(let v): "\(v)"
        case .string(let v): "\"\(v)\""
        case .objectPath(let v): "objectpath \(v)"
        case .signature(let v): "signature \(v)"
        case .variant(let v): "<\(v)>"
        case .array(_, let values): "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .dictionary(_, _, let entries):
            "{" + entries.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
        case .structure(let fields): "(" + fields.map(\.description).joined(separator: ", ") + ")"
        }
    }

    // MARK: Building

    /// `as`.
    public static func stringArray(_ strings: [String]) -> DBusValue {
        .array(.string, strings.map { .string($0) })
    }

    /// `a{sv}` with the keys sorted, so the same dictionary always marshals the same way.
    public static func vardict(_ entries: [String: DBusValue]) -> DBusValue {
        .dictionary(key: .string, value: .variant, entries.keys.sorted().map {
            DBusDictEntry(key: .string($0), value: .variant(entries[$0]!))
        })
    }

    /// The value of a typed Swift value.
    public init(_ value: some DBusRepresentable) {
        self = value.dbusValue
    }

    // MARK: Reading

    public var bool: Bool? { if case .boolean(let v) = self { v } else { nil } }
    public var int32: Int32? { if case .int32(let v) = self { v } else { nil } }
    public var uint32: UInt32? { if case .uint32(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var objectPath: String? { if case .objectPath(let v) = self { v } else { nil } }
    /// The value inside a variant.
    public var variantValue: DBusValue? { if case .variant(let v) = self { v } else { nil } }

    /// The strings of an `as`.
    public var stringArray: [String]? { try? [String](dbusValue: self) }

    /// An `a{sv}` as a Swift dictionary, each variant unwrapped; a repeated key keeps its last
    /// value.
    public var vardict: [String: DBusValue]? {
        guard case .dictionary(.string, .variant, let entries) = self else { return nil }
        var result: [String: DBusValue] = [:]
        for entry in entries {
            if case .string(let key) = entry.key, case .variant(let value) = entry.value {
                result[key] = value
            }
        }
        return result
    }

    /// Decodes this value as `T`, or throws `.typeMismatch`.
    public func decode<T: DBusRepresentable>(_ type: T.Type) throws(DBusError) -> T {
        try T(dbusValue: self)
    }

    // MARK: Validation

    /// Checks everything GLib would assert on, before any of it reaches GLib: the types are
    /// well-formed, every array element and dictionary entry has its declared type, strings hold
    /// no NUL, object paths and signatures are valid. A value that passes marshals without a
    /// GLib critical; one that fails is never built (GVariantCodec).
    public func validate() throws(DBusError) {
        switch self {
        case .boolean, .byte, .int16, .uint16, .int32, .uint32, .int64, .uint64, .double:
            return
        case .string(let s):
            guard !s.utf8.contains(0) else { throw .invalidValue("a string contains NUL") }
        case .objectPath(let path):
            guard !path.utf8.contains(0), g_variant_is_object_path(path) != 0 else {
                throw .invalidValue("\(path.debugDescription) is not an object path")
            }
        case .signature(let signature):
            guard !signature.utf8.contains(0), g_variant_is_signature(signature) != 0 else {
                throw .invalidValue("\(signature.debugDescription) is not a signature")
            }
        case .variant(let inner):
            try inner.validate()
        case .array(let element, let values):
            guard DBusType.array(element).isWellFormed else { throw .invalidSignature("a" + element.signature) }
            for value in values {
                guard value.type == element else {
                    throw .invalidValue("array element \(value.type) in a\(element)")
                }
                try value.validate()
            }
        case .dictionary(let key, let value, let entries):
            let type = DBusType.dictionary(key: key, value: value)
            guard type.isWellFormed else { throw .invalidSignature(type.signature) }
            for entry in entries {
                guard entry.key.type == key, entry.value.type == value else {
                    throw .invalidValue("entry {\(entry.key.type)\(entry.value.type)} in \(type)")
                }
                try entry.key.validate()
                try entry.value.validate()
            }
        case .structure(let fields):
            guard type.isWellFormed else { throw .invalidSignature(type.signature) }
            for field in fields {
                try field.validate()
            }
        }
    }
}

/// One entry of an `a{…}` dictionary.
public struct DBusDictEntry: Sendable, Hashable {
    public var key: DBusValue
    public var value: DBusValue

    public init(key: DBusValue, value: DBusValue) {
        self.key = key
        self.value = value
    }
}

/// A `v`: any value, carried with its own type.
public struct DBusVariant: Sendable, Hashable {
    public var value: DBusValue

    public init(_ value: DBusValue) {
        self.value = value
    }
}

/// An `o`.
public struct DBusObjectPath: Sendable, Hashable, CustomStringConvertible {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

// MARK: - Typed values

/// A Swift type with one D-Bus type. `init(dbusValue:)` throws `.typeMismatch` for a value of any
/// other shape, so a reply decoded through it can never trap.
public protocol DBusRepresentable: Sendable {
    static var dbusType: DBusType { get }
    var dbusValue: DBusValue { get }
    init(dbusValue: DBusValue) throws(DBusError)
}

extension DBusError {
    static func mismatch(_ expected: DBusType, _ value: DBusValue) -> DBusError {
        .typeMismatch(expected: expected.signature, actual: value.type.signature)
    }
}

extension Bool: DBusRepresentable {
    public static var dbusType: DBusType { .boolean }
    public var dbusValue: DBusValue { .boolean(self) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .boolean(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self = v
    }
}

extension UInt8: DBusRepresentable {
    public static var dbusType: DBusType { .byte }
    public var dbusValue: DBusValue { .byte(self) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .byte(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self = v
    }
}

extension Int16: DBusRepresentable {
    public static var dbusType: DBusType { .int16 }
    public var dbusValue: DBusValue { .int16(self) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .int16(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self = v
    }
}

extension UInt16: DBusRepresentable {
    public static var dbusType: DBusType { .uint16 }
    public var dbusValue: DBusValue { .uint16(self) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .uint16(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self = v
    }
}

extension Int32: DBusRepresentable {
    public static var dbusType: DBusType { .int32 }
    public var dbusValue: DBusValue { .int32(self) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .int32(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self = v
    }
}

extension UInt32: DBusRepresentable {
    public static var dbusType: DBusType { .uint32 }
    public var dbusValue: DBusValue { .uint32(self) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .uint32(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self = v
    }
}

extension Int64: DBusRepresentable {
    public static var dbusType: DBusType { .int64 }
    public var dbusValue: DBusValue { .int64(self) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .int64(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self = v
    }
}

extension UInt64: DBusRepresentable {
    public static var dbusType: DBusType { .uint64 }
    public var dbusValue: DBusValue { .uint64(self) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .uint64(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self = v
    }
}

extension Double: DBusRepresentable {
    public static var dbusType: DBusType { .double }
    public var dbusValue: DBusValue { .double(self) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .double(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self = v
    }
}

extension String: DBusRepresentable {
    public static var dbusType: DBusType { .string }
    public var dbusValue: DBusValue { .string(self) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .string(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self = v
    }
}

extension DBusObjectPath: DBusRepresentable {
    public static var dbusType: DBusType { .objectPath }
    public var dbusValue: DBusValue { .objectPath(rawValue) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .objectPath(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self.init(v)
    }
}

extension DBusVariant: DBusRepresentable {
    public static var dbusType: DBusType { .variant }
    public var dbusValue: DBusValue { .variant(value) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .variant(let v) = dbusValue else { throw .mismatch(Self.dbusType, dbusValue) }
        self.init(v)
    }
}

extension Array: DBusRepresentable where Element: DBusRepresentable {
    public static var dbusType: DBusType { .array(Element.dbusType) }
    public var dbusValue: DBusValue { .array(Element.dbusType, map(\.dbusValue)) }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .array(Element.dbusType, let values) = dbusValue else {
            throw .mismatch(Self.dbusType, dbusValue)
        }
        var result: [Element] = []
        result.reserveCapacity(values.count)
        for value in values {
            result.append(try Element(dbusValue: value))
        }
        self = result
    }
}

/// `a{kv}` for a basic key type. Marshalled with the keys sorted, like `DBusValue.vardict`; a
/// repeated key in a received dictionary keeps its last value.
extension Dictionary: DBusRepresentable where Key: DBusRepresentable & Comparable, Value: DBusRepresentable {
    public static var dbusType: DBusType { .dictionary(key: Key.dbusType, value: Value.dbusType) }
    public var dbusValue: DBusValue {
        .dictionary(key: Key.dbusType, value: Value.dbusType, keys.sorted().map {
            DBusDictEntry(key: $0.dbusValue, value: self[$0]!.dbusValue)
        })
    }
    public init(dbusValue: DBusValue) throws(DBusError) {
        guard case .dictionary(Key.dbusType, Value.dbusType, let entries) = dbusValue else {
            throw .mismatch(Self.dbusType, dbusValue)
        }
        var result: [Key: Value] = [:]
        for entry in entries {
            result[try Key(dbusValue: entry.key)] = try Value(dbusValue: entry.value)
        }
        self = result
    }
}

extension Array where Element == DBusValue {
    /// Decodes the value at `index` of a reply or signal body as `T`, or throws `.typeMismatch`
    /// (a body too short counts as one).
    public func decode<T: DBusRepresentable>(_ type: T.Type, at index: Int) throws(DBusError) -> T {
        guard indices.contains(index) else {
            throw .typeMismatch(expected: T.dbusType.signature, actual: "nothing at \(index)")
        }
        return try T(dbusValue: self[index])
    }

    /// The body signature of these values, as in a message header: `sa{sv}u`.
    public var signature: String { map(\.type.signature).joined() }
}
