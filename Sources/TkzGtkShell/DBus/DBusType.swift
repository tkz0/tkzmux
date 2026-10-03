// DBusType — the D-Bus type grammar the GDBus wrapper speaks (WOR-320 S1).
//
// Every type D-Bus can carry except two: `h` (a unix fd index, meaningless without the message's
// fd list, which this wrapper does not pass) and GVariant's `m` (maybe), which has no D-Bus wire
// form. A value of either type in a received message is reported as `DBusError.unsupportedType`,
// never unpacked.
//
// The parser enforces the D-Bus limits as well as the grammar: a signature of at most 255 bytes,
// at most 32 nested arrays and 32 nested structures, dictionary keys of a basic type, and no
// empty structure. A `DBusType` built from cases instead of parsed is checked the same way when a
// value of it is marshalled (`DBusValue.validate`).

public indirect enum DBusType: Sendable, Hashable, CustomStringConvertible {
    case boolean            // b
    case byte               // y
    case int16              // n
    case uint16             // q
    case int32              // i
    case uint32             // u
    case int64              // x
    case uint64             // t
    case double             // d
    case string             // s
    case objectPath         // o
    case signature          // g
    case variant            // v
    case array(DBusType)    // a<element>
    /// `a{<key><value>}`: an array of dictionary entries. The key is a basic type.
    case dictionary(key: DBusType, value: DBusType)
    /// `(<fields>)`, at least one field.
    case structure([DBusType])

    /// The D-Bus signature of this one complete type.
    public var signature: String {
        switch self {
        case .boolean: "b"
        case .byte: "y"
        case .int16: "n"
        case .uint16: "q"
        case .int32: "i"
        case .uint32: "u"
        case .int64: "x"
        case .uint64: "t"
        case .double: "d"
        case .string: "s"
        case .objectPath: "o"
        case .signature: "g"
        case .variant: "v"
        case .array(let element): "a" + element.signature
        case .dictionary(let key, let value): "a{" + key.signature + value.signature + "}"
        case .structure(let fields): "(" + fields.map(\.signature).joined() + ")"
        }
    }

    public var description: String { signature }

    /// Whether this is a basic (fixed or string-like) type, the only kind a dictionary key may be.
    public var isBasic: Bool {
        switch self {
        case .boolean, .byte, .int16, .uint16, .int32, .uint32, .int64, .uint64, .double, .string,
             .objectPath, .signature:
            true
        case .variant, .array, .dictionary, .structure:
            false
        }
    }

    /// Parses exactly one complete type, such as `a{sv}` or `(so)`.
    public init(signature: String) throws(DBusError) {
        let types = try DBusType.parse(list: signature)
        guard types.count == 1 else {
            throw .invalidSignature(signature)
        }
        self = types[0]
    }

    /// Parses a signature of zero or more complete types, such as a message body's `sa{sv}u`.
    public static func parse(list signature: String) throws(DBusError) -> [DBusType] {
        let bytes = Array(signature.utf8)
        guard bytes.count <= maxSignatureLength else {
            throw .invalidSignature(signature)
        }
        var parser = Parser(bytes: bytes)
        var types: [DBusType] = []
        while parser.index < bytes.count {
            guard let type = parser.completeType(arrays: 0, structures: 0) else {
                throw .invalidSignature(signature)
            }
            types.append(type)
        }
        return types
    }

    /// Whether this type and everything in it is within the grammar and the limits above. A parsed
    /// type always is; one built from cases may not be (a non-basic key, an empty structure, too
    /// deep, too long).
    var isWellFormed: Bool {
        guard signature.utf8.count <= DBusType.maxSignatureLength else { return false }
        return wellFormed(arrays: 0, structures: 0)
    }

    private func wellFormed(arrays: Int, structures: Int) -> Bool {
        switch self {
        case .array(let element):
            return arrays < DBusType.maxNesting && element.wellFormed(arrays: arrays + 1, structures: structures)
        case .dictionary(let key, let value):
            // A dict entry counts as a structure for the nesting limit, as in the D-Bus spec.
            return key.isBasic && arrays < DBusType.maxNesting && structures < DBusType.maxNesting
                && value.wellFormed(arrays: arrays + 1, structures: structures + 1)
        case .structure(let fields):
            return !fields.isEmpty && structures < DBusType.maxNesting
                && fields.allSatisfy { $0.wellFormed(arrays: arrays, structures: structures + 1) }
        default:
            return true
        }
    }

    static let maxSignatureLength = 255
    static let maxNesting = 32

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func completeType(arrays: Int, structures: Int) -> DBusType? {
            guard index < bytes.count else { return nil }
            let code = bytes[index]
            index += 1
            if let basic = DBusType.basic(code) {
                return basic
            }
            switch code {
            case UInt8(ascii: "v"):
                return .variant
            case UInt8(ascii: "a"):
                guard arrays < DBusType.maxNesting, index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: "{") {
                    index += 1
                    guard structures < DBusType.maxNesting, index < bytes.count,
                          let key = DBusType.basic(bytes[index]) else { return nil }
                    index += 1
                    guard let value = completeType(arrays: arrays + 1, structures: structures + 1),
                          index < bytes.count, bytes[index] == UInt8(ascii: "}") else { return nil }
                    index += 1
                    return .dictionary(key: key, value: value)
                }
                guard let element = completeType(arrays: arrays + 1, structures: structures) else { return nil }
                return .array(element)
            case UInt8(ascii: "("):
                guard structures < DBusType.maxNesting else { return nil }
                var fields: [DBusType] = []
                while index < bytes.count, bytes[index] != UInt8(ascii: ")") {
                    guard let field = completeType(arrays: arrays, structures: structures + 1) else { return nil }
                    fields.append(field)
                }
                guard index < bytes.count, !fields.isEmpty else { return nil }
                index += 1
                return .structure(fields)
            default:
                // `h`, `m`, a stray `{`, `}` or `)`, or anything else.
                return nil
            }
        }
    }

    private static func basic(_ code: UInt8) -> DBusType? {
        switch code {
        case UInt8(ascii: "b"): .boolean
        case UInt8(ascii: "y"): .byte
        case UInt8(ascii: "n"): .int16
        case UInt8(ascii: "q"): .uint16
        case UInt8(ascii: "i"): .int32
        case UInt8(ascii: "u"): .uint32
        case UInt8(ascii: "x"): .int64
        case UInt8(ascii: "t"): .uint64
        case UInt8(ascii: "d"): .double
        case UInt8(ascii: "s"): .string
        case UInt8(ascii: "o"): .objectPath
        case UInt8(ascii: "g"): .signature
        default: nil
        }
    }
}
