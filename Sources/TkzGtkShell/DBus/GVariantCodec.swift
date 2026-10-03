// GVariantCodec — DBusValue to GVariant and back, the only place the wrapper touches GVariant
// (WOR-320 S1).
//
// Ownership:
//   - Building returns a *floating* reference. Every GIO call the wrapper passes it to
//     (g_dbus_connection_call, _emit_signal, g_dbus_method_invocation_return_value) and every
//     container constructor below (g_variant_new_array, _tuple, _dict_entry, _variant) sinks a
//     floating argument, so a built tree is owned by exactly one consumer and never unreffed here.
//     A value is validated before the first g_variant_new_*, so a tree is never half built and
//     then abandoned (which would leak its floating children).
//   - Reading borrows: the caller keeps its reference. Each child taken with
//     g_variant_get_child_value / g_variant_get_variant is a new full reference, dropped here.
//
// Reading never traps on what a peer sent. The node's own type string decides how it is read (so
// every unpack matches the type it is of), a type outside DBusType throws, and the reply-level
// check (`readBody(_:expecting:)`) tests `g_variant_is_of_type` before reading anything.

import CGtk
import TkzLinuxShim

enum GVariantCodec {
    /// A floating tuple of `values`, a message body. Throws before building anything if a value
    /// fails `DBusValue.validate()`.
    static func makeBody(_ values: [DBusValue]) throws(DBusError) -> OpaquePointer {
        for value in values {
            try value.validate()
        }
        var children: [OpaquePointer?] = values.map { makeFloating($0) }
        return g_variant_new_tuple(&children, gsize(children.count))
    }

    /// A floating GVariant for a value that has passed `validate()`.
    static func makeFloating(_ value: DBusValue) -> OpaquePointer {
        switch value {
        case .boolean(let v): return g_variant_new_boolean(v ? 1 : 0)
        case .byte(let v): return g_variant_new_byte(v)
        case .int16(let v): return g_variant_new_int16(v)
        case .uint16(let v): return g_variant_new_uint16(v)
        case .int32(let v): return g_variant_new_int32(v)
        case .uint32(let v): return g_variant_new_uint32(v)
        case .int64(let v): return g_variant_new_int64(gint64(v))
        case .uint64(let v): return g_variant_new_uint64(guint64(v))
        case .double(let v): return g_variant_new_double(v)
        case .string(let v): return g_variant_new_string(v)
        case .objectPath(let v): return g_variant_new_object_path(v)
        case .signature(let v): return g_variant_new_signature(v)
        case .variant(let inner): return g_variant_new_variant(makeFloating(inner))
        case .array(let element, let values):
            var children: [OpaquePointer?] = values.map { makeFloating($0) }
            return withType(element.signature) { g_variant_new_array($0, &children, gsize(children.count)) }
        case .dictionary(let key, let value, let entries):
            var children: [OpaquePointer?] = entries.map {
                g_variant_new_dict_entry(makeFloating($0.key), makeFloating($0.value))
            }
            let entryType = "{" + key.signature + value.signature + "}"
            return withType(entryType) { g_variant_new_array($0, &children, gsize(children.count)) }
        case .structure(let fields):
            var children: [OpaquePointer?] = fields.map { makeFloating($0) }
            return g_variant_new_tuple(&children, gsize(children.count))
        }
    }

    /// The children of a message body (a tuple), after checking that the body is of type
    /// `expected` when one is given (`(u)`, `(sa{sv})`, `()`). Nothing is read from a body of
    /// another type.
    static func readBody(_ body: OpaquePointer, expecting expected: String?) throws(DBusError) -> [DBusValue] {
        let actual = typeString(body)
        if let expected, tkz_variant_is_of_type(body, expected) == 0 {
            throw .typeMismatch(expected: expected, actual: actual)
        }
        guard actual.hasPrefix("(") else {
            throw .typeMismatch(expected: expected ?? "a tuple", actual: actual)
        }
        return try readChildren(body)
    }

    /// The value of `variant`, which stays the caller's.
    static func read(_ variant: OpaquePointer) throws(DBusError) -> DBusValue {
        let type = typeString(variant)
        switch type.utf8.first {
        case UInt8(ascii: "b"): return .boolean(g_variant_get_boolean(variant) != 0)
        case UInt8(ascii: "y"): return .byte(g_variant_get_byte(variant))
        case UInt8(ascii: "n"): return .int16(g_variant_get_int16(variant))
        case UInt8(ascii: "q"): return .uint16(g_variant_get_uint16(variant))
        case UInt8(ascii: "i"): return .int32(g_variant_get_int32(variant))
        case UInt8(ascii: "u"): return .uint32(g_variant_get_uint32(variant))
        case UInt8(ascii: "x"): return .int64(Int64(g_variant_get_int64(variant)))
        case UInt8(ascii: "t"): return .uint64(UInt64(g_variant_get_uint64(variant)))
        case UInt8(ascii: "d"): return .double(g_variant_get_double(variant))
        case UInt8(ascii: "s"): return .string(String(cString: g_variant_get_string(variant, nil)))
        case UInt8(ascii: "o"): return .objectPath(String(cString: g_variant_get_string(variant, nil)))
        case UInt8(ascii: "g"): return .signature(String(cString: g_variant_get_string(variant, nil)))
        case UInt8(ascii: "v"):
            let inner = g_variant_get_variant(variant)!
            defer { g_variant_unref(inner) }
            return .variant(try read(inner))
        case UInt8(ascii: "("):
            return .structure(try readChildren(variant))
        case UInt8(ascii: "a"):
            // An array of `h` or `m` (or beyond the D-Bus limits) is a type DBusType cannot hold.
            let parsed: DBusType
            do { parsed = try DBusType(signature: type) } catch { throw .unsupportedType(type) }
            switch parsed {
            case .array(let element):
                return .array(element, try readChildren(variant))
            case .dictionary(let key, let value):
                var entries: [DBusDictEntry] = []
                let count = g_variant_n_children(variant)
                entries.reserveCapacity(Int(count))
                for index in 0..<count {
                    let entry = g_variant_get_child_value(variant, index)!
                    defer { g_variant_unref(entry) }
                    let k = g_variant_get_child_value(entry, 0)!
                    defer { g_variant_unref(k) }
                    let v = g_variant_get_child_value(entry, 1)!
                    defer { g_variant_unref(v) }
                    entries.append(DBusDictEntry(key: try read(k), value: try read(v)))
                }
                return .dictionary(key: key, value: value, entries)
            default:
                throw .unsupportedType(type)
            }
        default:
            // `h`, `m`, or a bare dict entry, none of which a DBusValue can hold.
            throw .unsupportedType(type)
        }
    }

    private static func readChildren(_ container: OpaquePointer) throws(DBusError) -> [DBusValue] {
        let count = g_variant_n_children(container)
        var values: [DBusValue] = []
        values.reserveCapacity(Int(count))
        for index in 0..<count {
            let child = g_variant_get_child_value(container, index)!
            defer { g_variant_unref(child) }
            values.append(try read(child))
        }
        return values
    }

    static func typeString(_ variant: OpaquePointer) -> String {
        String(cString: g_variant_get_type_string(variant))
    }

    /// Runs `body` with a GVariantType for `signature`, which `validate()` has checked.
    private static func withType<R>(_ signature: String, _ body: (OpaquePointer) -> R) -> R {
        let type = g_variant_type_new(signature)!
        defer { g_variant_type_free(type) }
        return body(type)
    }
}
