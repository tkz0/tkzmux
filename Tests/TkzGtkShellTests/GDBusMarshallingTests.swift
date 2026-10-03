// GDBusMarshallingTests — WOR-320 S1. DBusValue ⇄ GVariant ⇄ D-Bus wire format, without a bus.
//
// Every supported signature gets 1,000 seeded random values (more for the open-ended cases), each
// built into a GVariant, serialized into a D-Bus message blob by GDBus, parsed back and read: the
// value, its type and the GVariant must all survive. The type parser is fuzzed against GLib's own
// signature check, wrong-typed bodies must throw instead of trapping, and values GLib would assert
// on must be refused before any GVariant exists.
import CGtk
import Testing
import TkzLinuxShim
@testable import TkzGtkShell

/// A named way to draw random values: a fixed signature, or a nesting the plain draw rarely hits.
struct FuzzCase: CustomStringConvertible, Sendable {
    let name: String
    let signature: String
    let bias: ValueGenerator.VariantBias

    var description: String { name }

    static let all: [FuzzCase] = [
        "s", "u", "i", "b", "o", "as", "a{sv}", "v",
        "y", "n", "q", "x", "t", "d", "g", "av", "aas", "a{us}", "a{oa{sv}}", "(sv)", "a(sv)",
        "a{sa{sv}}", "(ssa(sv)a(sa(sv)))",
    ].map { FuzzCase(name: $0, signature: $0, bias: .any) } + [
        FuzzCase(name: "a{sv} nested in its variants", signature: "a{sv}", bias: .vardict),
        FuzzCase(name: "v inside a{sv}", signature: "a{sv}", bias: .variant),
        FuzzCase(name: "v nested in v", signature: "v", bias: .variant),
    ]
}

/// Builds a body of `values`, puts it in a GDBusMessage, serializes the message to D-Bus's wire
/// format and parses it back, then reads the parsed body against the sent signature. Also checks
/// that GLib sees the two bodies as equal.
func wireRoundTrip(_ values: [DBusValue]) throws -> [DBusValue] {
    let message = g_dbus_message_new_signal("/se/tkz/tkzmux/Test", "se.tkz.tkzmux.Test", "Fuzz")!
    defer { g_object_unref(UnsafeMutableRawPointer(message)) }
    g_dbus_message_set_body(message, try GVariantCodec.makeBody(values))   // sinks the floating body
    var size: gsize = 0
    var error: UnsafeMutablePointer<GError>?
    let capabilities = GDBusCapabilityFlags(rawValue: 0)
    guard let blob = g_dbus_message_to_blob(message, &size, capabilities, &error) else {
        throw DBusError(consuming: error!)
    }
    defer { g_free(blob) }
    guard let parsed = g_dbus_message_new_from_blob(blob, size, capabilities, &error) else {
        throw DBusError(consuming: error!)
    }
    defer { g_object_unref(UnsafeMutableRawPointer(parsed)) }
    // GDBus leaves an empty body out of the message, so `()` comes back as no body at all.
    guard let sent = g_dbus_message_get_body(message), let received = g_dbus_message_get_body(parsed) else {
        #expect(values.isEmpty && g_dbus_message_get_body(parsed) == nil)
        return []
    }
    #expect(g_variant_equal(UnsafeRawPointer(sent), UnsafeRawPointer(received)) != 0)
    return try GVariantCodec.readBody(received, expecting: "(" + values.signature + ")")
}

/// A sunk (non-floating) GVariant body of `values`, for the read-side tests.
func sunkBody(_ values: [DBusValue]) throws -> OpaquePointer {
    g_variant_ref_sink(try GVariantCodec.makeBody(values))
}

@Suite(.serialized)
struct GDBusMarshallingTests {
    // MARK: Round trips

    @Test(arguments: FuzzCase.all)
    func randomValuesSurviveTheWire(_ fuzz: FuzzCase) throws {
        var generator = ValueGenerator(seed: "GDBusMarshallingTests." + fuzz.name)
        generator.bias = fuzz.bias
        let type = try DBusType(signature: fuzz.signature)
        for index in 0..<1_000 {
            let value = generator.value(of: type)
            #expect(value.type == type)
            let back: [DBusValue]
            do {
                back = try wireRoundTrip([value])
            } catch {
                Issue.record("case \(index): \(value): \(error)")
                continue
            }
            #expect(back == [value], "case \(index): \(value)")
            // A bit-exact check for the one lossy-looking Equatable: -0.0 == 0.0.
            #expect(back.map(\.description) == [value.description])
        }
    }

    /// Random types up to four containers deep, one value each, several values per body.
    @Test func randomTypesSurviveTheWire() throws {
        var generator = ValueGenerator(seed: "GDBusMarshallingTests.randomTypes")
        for index in 0..<2_000 {
            let values = (0..<generator.int(0...4)).map { _ in generator.value(of: generator.type(depth: 4)) }
            let back = try wireRoundTrip(values)
            #expect(back == values, "case \(index): \(values.signature)")
            #expect(back.signature == values.signature)
        }
    }

    @Test func typedValuesRoundTrip() throws {
        let vardict: [String: DBusVariant] = [
            "count": DBusVariant(.uint32(3)),
            "nested": DBusVariant(.vardict(["inner": .variant(.string("deep"))])),
            "paths": DBusVariant(DBusValue([DBusObjectPath("/a"), DBusObjectPath("/b/c")])),
        ]
        let values: [DBusValue] = [
            DBusValue("text"), DBusValue(UInt32.max), DBusValue(Int32.min), DBusValue(true),
            DBusValue(DBusObjectPath("/se/tkz")), DBusValue(["a", "", "ü"]), DBusValue(vardict),
            DBusValue(DBusVariant(.int64(-1))),
        ]
        let back = try wireRoundTrip(values)
        #expect(try back.decode(String.self, at: 0) == "text")
        #expect(try back.decode(UInt32.self, at: 1) == .max)
        #expect(try back.decode(Int32.self, at: 2) == .min)
        #expect(try back.decode(Bool.self, at: 3))
        #expect(try back.decode(DBusObjectPath.self, at: 4) == DBusObjectPath("/se/tkz"))
        #expect(try back.decode([String].self, at: 5) == ["a", "", "ü"])
        #expect(try back.decode([String: DBusVariant].self, at: 6) == vardict)
        #expect(back[6].vardict?["nested"]?.vardict?["inner"] == .variant(.string("deep")))
        #expect(try back.decode(DBusVariant.self, at: 7).value == .int64(-1))
        // `vardict` sorts its keys, so the same dictionary always marshals the same way.
        #expect(DBusValue.vardict(["b": .uint32(1), "a": .uint32(2)])
                == .dictionary(key: .string, value: .variant, [
                    DBusDictEntry(key: .string("a"), value: .variant(.uint32(2))),
                    DBusDictEntry(key: .string("b"), value: .variant(.uint32(1))),
                ]))
    }

    @Test func anEmptyBodyIsTheUnitTuple() throws {
        #expect(try wireRoundTrip([]) == [])
        let body = try sunkBody([])
        defer { g_variant_unref(body) }
        #expect(GVariantCodec.typeString(body) == "()")
        #expect(try GVariantCodec.readBody(body, expecting: "()") == [])
    }

    // MARK: Floating references

    /// A built body is floating, so the GIO call it is passed to owns it; sinking it takes that one
    /// reference over and nothing else holds one.
    @Test func aBuiltBodyIsFloatingAndSinksToOneReference() throws {
        let body = try GVariantCodec.makeBody([.vardict(["k": .string("v")]), .stringArray(["x"])])
        #expect(g_variant_is_floating(body) != 0)
        let owned = g_variant_ref_sink(body)!
        #expect(owned == body)
        #expect(g_variant_is_floating(owned) == 0)
        // Reading borrows: the caller's reference is still the only one, so one unref frees it
        // (ASan would report a use after free or a leak otherwise).
        _ = try GVariantCodec.readBody(owned, expecting: "(a{sv}as)")
        _ = try GVariantCodec.readBody(owned, expecting: "(a{sv}as)")
        g_variant_unref(owned)
    }

    // MARK: Wrong types

    @Test func aBodyOfTheWrongTypeThrowsInsteadOfTrapping() throws {
        let body = try sunkBody([.string("not a number")])
        defer { g_variant_unref(body) }
        #expect(throws: DBusError.typeMismatch(expected: "(u)", actual: "(s)")) {
            try GVariantCodec.readBody(body, expecting: "(u)")
        }
        #expect(throws: DBusError.typeMismatch(expected: "(ss)", actual: "(s)")) {
            try GVariantCodec.readBody(body, expecting: "(ss)")
        }
        // An invalid expected type is a mismatch, not a GLib assertion.
        #expect(throws: DBusError.self) { try GVariantCodec.readBody(body, expecting: "(u") }
        // The values themselves, read untyped, then decoded as the wrong Swift type.
        let values = try GVariantCodec.readBody(body, expecting: nil)
        #expect(throws: DBusError.typeMismatch(expected: "u", actual: "s")) { try values.decode(UInt32.self, at: 0) }
        #expect(throws: DBusError.self) { try values.decode(String.self, at: 1) }
        #expect(throws: DBusError.self) { try values[0].decode([String].self) }
        #expect(throws: DBusError.self) { try DBusValue.stringArray(["a"]).decode([String: DBusVariant].self) }
        #expect(throws: DBusError.self) { try DBusValue.vardict([:]).decode([UInt32: DBusVariant].self) }
    }

    /// `h` and `m` exist in GVariant but not in DBusValue: reading one, or an array of one, throws.
    @Test func unsupportedTypesThrow() throws {
        var handle: [OpaquePointer?] = [g_variant_new_handle(0)]
        let handleBody = g_variant_ref_sink(g_variant_new_tuple(&handle, 1))!
        defer { g_variant_unref(handleBody) }
        #expect(throws: DBusError.unsupportedType("h")) { try GVariantCodec.readBody(handleBody, expecting: nil) }

        var maybe: [OpaquePointer?] = [g_variant_new_maybe(nil, g_variant_new_uint32(7))]
        let maybeBody = g_variant_ref_sink(g_variant_new_tuple(&maybe, 1))!
        defer { g_variant_unref(maybeBody) }
        #expect(throws: DBusError.unsupportedType("mu")) { try GVariantCodec.readBody(maybeBody, expecting: nil) }

        let handleType = g_variant_type_new("h")!
        defer { g_variant_type_free(handleType) }
        var handles: [OpaquePointer?] = [g_variant_new_array(handleType, nil, 0)]
        let handlesBody = g_variant_ref_sink(g_variant_new_tuple(&handles, 1))!
        defer { g_variant_unref(handlesBody) }
        #expect(throws: DBusError.unsupportedType("ah")) { try GVariantCodec.readBody(handlesBody, expecting: nil) }

        #expect(throws: DBusError.self) { try GVariantCodec.readBody(handleBody, expecting: "(u)") }
    }

    // MARK: GLib

    /// GLib 2.88.3's GDBus message reader loses or misreads elements of some arrays whose elements
    /// hold a signature (`g`): `[('sssss', 1), ('u', 2)]` of type `a(gy)` comes back with one
    /// element, and `a{yg}` dictionaries fail to parse ("Wanted to read 6553950 bytes"). The blob
    /// GDBus writes is correct (the array length and padding check out by hand); its own parser
    /// misreads it. Pure GLib reproduces it, without this wrapper, so the fuzz generators keep `g`
    /// out of arrays, and this test notices when a GLib update fixes it. tkzmux sends no `g`.
    @Test func glibMisreadsSignaturesInArrays() throws {
        let value = DBusValue.array(.structure([.signature, .byte]), [
            .structure([.signature("sssss"), .byte(1)]), .structure([.signature("u"), .byte(2)]),
        ])
        withKnownIssue("GLib 2.88 GDBus misreads a(gy) on the wire") {
            let back = try wireRoundTrip([value])
            #expect(back == [value])
        }
        // The same value through GVariant alone is intact: the codec is not the cause.
        let body = try sunkBody([value])
        defer { g_variant_unref(body) }
        #expect(try GVariantCodec.readBody(body, expecting: "(a(gy))") == [value])
    }

    // MARK: Validation

    /// Each of these would be a GLib critical (or a silently truncated string) if it reached
    /// g_variant_new_*; they are refused before any GVariant is built.
    @Test func valuesGLibWouldRejectAreRefusedFirst() {
        let bad: [DBusValue] = [
            .string("nul\u{0}inside"),
            .objectPath("relative/path"),
            .objectPath("/trailing/"),
            .objectPath("/double//slash"),
            .objectPath("/bad-char"),
            .signature("a{vs}"),
            .signature("(s"),
            .array(.string, [.uint32(1)]),
            .array(.variant, [.string("not wrapped")]),
            .dictionary(key: .string, value: .variant, [DBusDictEntry(key: .uint32(1), value: .variant(.byte(0)))]),
            .dictionary(key: .variant, value: .string, []),
            .dictionary(key: .array(.string), value: .string, []),
            .structure([]),
            .array(.structure([]), []),
            .variant(.string("deep \u{0}")),
            .array(.array(.string), [.array(.string, [.string("\u{0}")])]),
        ]
        for value in bad {
            #expect(throws: DBusError.self, "\(value)") { try value.validate() }
            #expect(throws: DBusError.self, "\(value)") { try GVariantCodec.makeBody([.string("ok"), value]) }
        }
        var tooDeep = DBusType.string
        for _ in 0..<33 { tooDeep = .array(tooDeep) }
        #expect(throws: DBusError.self) { try DBusValue.array(tooDeep, []).validate() }
    }

    // MARK: Signatures

    @Test func signaturesParseAndPrint() throws {
        for signature in ["s", "a{sv}", "(ssa(sv)a(sa(sv)))", "aa{oa{sv}}", "v", "a(ybnqiuxtdsogv)"] {
            #expect(try DBusType(signature: signature).signature == signature)
        }
        #expect(try DBusType.parse(list: "sa{sv}u").map(\.signature) == ["s", "a{sv}", "u"])
        #expect(try DBusType.parse(list: "").isEmpty)
        for bad in ["", "su", "a", "a{", "a{sv", "a{vs}", "a{(s)s}", "()", "(s", "s)", "{sv}", "h", "mu", "ah",
                    "z", String(repeating: "a", count: 33) + "s", String(repeating: "(", count: 33) + "s" + String(repeating: ")", count: 33)] {
            #expect(throws: DBusError.self, "\(bad)") { try DBusType(signature: bad) }
        }
        #expect(throws: DBusError.self) { try DBusType.parse(list: String(repeating: "s", count: 256)) }
        #expect(try DBusType.parse(list: String(repeating: "s", count: 255)).count == 255)
    }

    /// Random strings over the signature alphabet: whatever the parser accepts, GLib accepts as a
    /// D-Bus signature, and whatever GLib accepts the parser accepts too, except `h`, an empty
    /// structure and a dict entry outside an array (`i{qq}`), which `g_variant_is_signature`
    /// lets through and the D-Bus specification does not.
    @Test func theParserAgreesWithGLib() {
        func bareDictEntry(_ signature: String) -> Bool {
            let bytes = Array(signature.utf8)
            return bytes.indices.contains { bytes[$0] == UInt8(ascii: "{") && ($0 == 0 || bytes[$0 - 1] != UInt8(ascii: "a")) }
        }
        var rng = SeededGenerator(named: "GDBusMarshallingTests.parser")
        let alphabet = Array("bynqiuxtdsogvaa{}()hm")
        var accepted = 0
        for _ in 0..<20_000 {
            let signature = String((0..<Int.random(in: 0...10, using: &rng)).map { _ in
                alphabet.randomElement(using: &rng)!
            })
            let ours = (try? DBusType.parse(list: signature)) != nil
            let glib = g_variant_is_signature(signature) != 0
            if ours {
                accepted += 1
                #expect(glib, "\(signature)")
            } else if glib && !signature.contains("h") && !signature.contains("()") && !bareDictEntry(signature) {
                Issue.record("GLib accepts \(signature), the parser does not")
            }
        }
        #expect(accepted > 1_000)
    }

    @Test func tkzVariantIsOfTypeNeverAsserts() throws {
        let body = try sunkBody([.uint32(1)])
        defer { g_variant_unref(body) }
        #expect(tkz_variant_is_of_type(body, "(u)") != 0)
        #expect(tkz_variant_is_of_type(body, "r") != 0)
        #expect(tkz_variant_is_of_type(body, "(s)") == 0)
        #expect(tkz_variant_is_of_type(body, "(u") == 0)
        #expect(tkz_variant_is_of_type(body, "") == 0)
        #expect(tkz_variant_is_of_type(nil, "(u)") == 0)
    }
}
