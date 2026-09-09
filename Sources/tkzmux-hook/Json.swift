// A small hand-written JSON value, parser and serializer for `settings-merge` (and the string
// escaping used elsewhere in this target). No Foundation: `String(decoding:as:)`, `String(cString:)`
// and `print` are Swift standard library, not Foundation, so this stays inside the hygiene rule.
import Darwin

/// An ordered JSON object/array representation. Object keys keep insertion order (the contract
/// allows key order to change on merge, but preserving it keeps diffs small and merge logic simple).
/// Numbers are kept as their original source text so a round trip never reformats them.
struct JSONPair {
    var key: String
    var value: JSONValue
}

enum JSONValue {
    case object([JSONPair])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

extension JSONValue {
    var asObject: [JSONPair]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }

    var asArray: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Numbers are stored as their source text; this is the only place they become a `Double`.
    var asNumber: Double? {
        if case .number(let raw) = self { return Double(raw) }
        return nil
    }

    func get(_ key: String) -> JSONValue? {
        asObject?.first(where: { $0.key == key })?.value
    }
}

// MARK: - Parser

/// Byte-level recursive-descent parser. Returns nil on any malformed input (including trailing
/// garbage after the top-level value) so the caller can turn that into an exit-1 with no output.
struct JSONParser {
    private let bytes: [UInt8]
    private var i = 0

    init(_ s: String) { self.bytes = Array(s.utf8) }
    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parse() -> JSONValue? {
        skipWhitespace()
        guard let v = parseValue() else { return nil }
        skipWhitespace()
        guard i == bytes.count else { return nil }
        return v
    }

    private mutating func skipWhitespace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    private mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard i < bytes.count else { return nil }
        switch bytes[i] {
        case 0x7B: return parseObject()
        case 0x5B: return parseArray()
        case 0x22: return parseRawString().map(JSONValue.string)
        case 0x74: return parseLiteral("true", .bool(true))
        case 0x66: return parseLiteral("false", .bool(false))
        case 0x6E: return parseLiteral("null", .null)
        default: return parseNumber()
        }
    }

    private mutating func parseLiteral(_ text: String, _ value: JSONValue) -> JSONValue? {
        let lit = Array(text.utf8)
        guard i + lit.count <= bytes.count else { return nil }
        guard Array(bytes[i..<i + lit.count]) == lit else { return nil }
        i += lit.count
        return value
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = i
        if i < bytes.count, bytes[i] == 0x2D { i += 1 } // -
        var sawDigit = false
        while i < bytes.count, isDigit(bytes[i]) { i += 1; sawDigit = true }
        guard sawDigit else { i = start; return nil }
        if i < bytes.count, bytes[i] == 0x2E { // .
            i += 1
            var sawFracDigit = false
            while i < bytes.count, isDigit(bytes[i]) { i += 1; sawFracDigit = true }
            guard sawFracDigit else { i = start; return nil }
        }
        if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 { // e/E
            i += 1
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            var sawExpDigit = false
            while i < bytes.count, isDigit(bytes[i]) { i += 1; sawExpDigit = true }
            guard sawExpDigit else { i = start; return nil }
        }
        let raw = String(decoding: bytes[start..<i], as: UTF8.self)
        return .number(raw)
    }

    private func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    private mutating func parseObject() -> JSONValue? {
        i += 1 // {
        var pairs: [JSONPair] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == 0x7D { i += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == 0x22, let key = parseRawString() else { return nil }
            skipWhitespace()
            guard i < bytes.count, bytes[i] == 0x3A else { return nil } // :
            i += 1
            guard let value = parseValue() else { return nil }
            pairs.append(JSONPair(key: key, value: value))
            skipWhitespace()
            guard i < bytes.count else { return nil }
            if bytes[i] == 0x2C { i += 1; continue }
            if bytes[i] == 0x7D { i += 1; break }
            return nil
        }
        return .object(pairs)
    }

    private mutating func parseArray() -> JSONValue? {
        i += 1 // [
        var items: [JSONValue] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == 0x5D { i += 1; return .array(items) }
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            guard i < bytes.count else { return nil }
            if bytes[i] == 0x2C { i += 1; continue }
            if bytes[i] == 0x5D { i += 1; break }
            return nil
        }
        return .array(items)
    }

    private mutating func parseRawString() -> String? {
        guard i < bytes.count, bytes[i] == 0x22 else { return nil }
        i += 1
        var out = String()
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x22 { i += 1; return out }
            if b == 0x5C {
                i += 1
                guard i < bytes.count else { return nil }
                let e = bytes[i]
                switch e {
                case 0x22: out.append("\""); i += 1
                case 0x5C: out.append("\\"); i += 1
                case 0x2F: out.append("/"); i += 1
                case 0x62: out.append("\u{08}"); i += 1
                case 0x66: out.append("\u{0C}"); i += 1
                case 0x6E: out.append("\n"); i += 1
                case 0x72: out.append("\r"); i += 1
                case 0x74: out.append("\t"); i += 1
                case 0x75:
                    i += 1
                    guard let cp1 = readHex4() else { return nil }
                    if cp1 >= 0xD800 && cp1 <= 0xDBFF {
                        guard i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75 else {
                            out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
                            continue
                        }
                        i += 2
                        guard let cp2 = readHex4() else { return nil }
                        guard cp2 >= 0xDC00 && cp2 <= 0xDFFF else {
                            out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
                            continue
                        }
                        let combined = 0x10000 + (cp1 - 0xD800) * 0x400 + (cp2 - 0xDC00)
                        if let scalar = Unicode.Scalar(combined) { out.unicodeScalars.append(scalar) }
                    } else if cp1 >= 0xDC00 && cp1 <= 0xDFFF {
                        out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
                    } else if let scalar = Unicode.Scalar(cp1) {
                        out.unicodeScalars.append(scalar)
                    } else {
                        return nil
                    }
                default:
                    return nil
                }
            } else {
                let len = utf8SequenceLength(b)
                guard i + len <= bytes.count else { return nil }
                out += String(decoding: bytes[i..<i + len], as: UTF8.self)
                i += len
            }
        }
        return nil // unterminated string
    }

    private mutating func readHex4() -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for _ in 0..<4 {
            guard let d = hexDigit(bytes[i]) else { return nil }
            v = (v << 4) | UInt32(d)
            i += 1
        }
        return v
    }

    private func hexDigit(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }
}

func utf8SequenceLength(_ b: UInt8) -> Int {
    if b & 0x80 == 0 { return 1 }
    if b & 0xE0 == 0xC0 { return 2 }
    if b & 0xF0 == 0xE0 { return 3 }
    if b & 0xF8 == 0xF0 { return 4 }
    return 1
}

// MARK: - Serializer

func jsonSerialize(_ value: JSONValue) -> String {
    switch value {
    case .object(let pairs):
        return "{" + pairs.map { "\"\(jsonEscape($0.key))\":\(jsonSerialize($0.value))" }.joined(separator: ",") + "}"
    case .array(let items):
        return "[" + items.map(jsonSerialize).joined(separator: ",") + "]"
    case .string(let s):
        return "\"\(jsonEscape(s))\""
    case .number(let raw):
        return raw
    case .bool(let b):
        return b ? "true" : "false"
    case .null:
        return "null"
    }
}

/// Two-space-indented serialization, for documents a human reads and diffs — `settings.json`.
/// The compact form above is right for `--settings` on a command line and wrong for a file.
func jsonSerializePretty(_ value: JSONValue, indent: Int = 0) -> String {
    let pad = String(repeating: " ", count: indent * 2)
    let inner = String(repeating: " ", count: (indent + 1) * 2)
    switch value {
    case .object(let pairs):
        guard !pairs.isEmpty else { return "{}" }
        let body = pairs
            .map { "\(inner)\"\(jsonEscape($0.key))\": \(jsonSerializePretty($0.value, indent: indent + 1))" }
            .joined(separator: ",\n")
        return "{\n" + body + "\n" + pad + "}"
    case .array(let items):
        guard !items.isEmpty else { return "[]" }
        let body = items
            .map { "\(inner)\(jsonSerializePretty($0, indent: indent + 1))" }
            .joined(separator: ",\n")
        return "[\n" + body + "\n" + pad + "]"
    default:
        return jsonSerialize(value)
    }
}

/// JSON string escaping shared by the settings-merge serializer and the hand-built wire frames
/// (`sid`, `cwd`, `argv`, …) sent by the hook and launch paths.
func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.utf8.count)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += hexEscape(scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
}

private func hexEscape(_ v: UInt32) -> String {
    let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    var chars: [Character] = []
    var x = v
    for _ in 0..<4 {
        chars.append(digits[Int(x & 0xF)])
        x >>= 4
    }
    return "\\u" + String(chars.reversed())
}
