// GDBusTestSupport — WOR-320 S1. What the GDBus tests share: a pump for the default GMainContext,
// a private bus, an echo service, and seeded generators of D-Bus types and values.
//
// The pump. In the app, GLib iterates the default context on the main actor's thread, so GDBus's
// callbacks arrive on the main actor by themselves (DBusConnection). Under Swift Testing the main
// actor is a libdispatch worker parked in no GLib loop (docs/linux/spikes.md, S3), so a test
// drives the context itself: `GLibPump.run` runs the test body as a main-actor task and, between
// its suspensions, iterates the default context from the same actor. GDBus captured that context
// when each operation started (no thread-default context is ever pushed here), so its callbacks
// run inside the pump, on the main actor, exactly as they would under `g_application_run`.
// MainQueueBridge's "no nested main loop" rule is about its main-queue GSource, which is never
// attached in the test process; the pump never blocks for more than a millisecond at a time.
//
// The bus. Each test starts its own `dbus-daemon --session` (PrivateBus), so the tests need no
// session bus and leave nothing behind on one; only `bus(.session)`/`bus(.system)` themselves are
// tested against the environment's buses, when there are any.
import CGtk
import Foundation
import Testing
@testable import TkzGtkShell

// MARK: - Pump

@MainActor
enum GLibPump {
    struct TimedOut: Error {}

    /// Runs `operation` while iterating the default GMainContext, and returns its result. Fails
    /// with `TimedOut` if it has not finished after `timeout`.
    static func run<T: Sendable>(
        timeout: Duration = .seconds(60), _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let state = PumpState()
        let task = Task { @MainActor in
            defer { state.finished = true }
            return try await operation()
        }
        let deadline = ContinuousClock.now + timeout
        var idleRounds = 0
        while !state.finished {
            guard ContinuousClock.now < deadline else {
                task.cancel()
                throw TimedOut()
            }
            if drain() {
                idleRounds = 0
            } else {
                idleRounds += 1
                // Nothing from GLib for a few turns: the operation is waiting for the bus. Block
                // until GDBus's worker posts something, for at most 1 ms, so a pending main-actor
                // job is never held up for long.
                if idleRounds > 2, blockOnce(milliseconds: 1) { idleRounds = 0 }
            }
            await Task.yield()
        }
        return try await task.value
    }

    /// Settles pending GLib work (destroy-notifies, NameOwnerChanged, idle replies) for `turns`
    /// pump rounds.
    static func settle(turns: Int = 200) async {
        for _ in 0..<turns {
            _ = drain()
            await Task.yield()
        }
    }

    /// Dispatches everything ready, without blocking. Whether anything was.
    @discardableResult
    static func drain() -> Bool {
        var dispatched = false
        while g_main_context_iteration(nil, 0) != 0 { dispatched = true }
        return dispatched
    }

    /// One blocking iteration, woken by a timeout source after `milliseconds` at the latest.
    private static func blockOnce(milliseconds: UInt32) -> Bool {
        let timeout = g_timeout_source_new(milliseconds)!
        g_source_set_callback(timeout, { _ in 0 }, nil, nil)   // G_SOURCE_REMOVE
        g_source_attach(timeout, nil)
        let dispatched = g_main_context_iteration(nil, 1) != 0
        g_source_destroy(timeout)
        g_source_unref(timeout)
        return dispatched
    }
}

@MainActor
private final class PumpState {
    var finished = false
}

// MARK: - Private bus

/// A `dbus-daemon --session` of this test's own, with its address.
///
/// Spawned with `posix_spawn` and a clean signal state (empty mask, default dispositions), not
/// Foundation's `Process`: a child of a libdispatch thread inherits its blocked signals, so a
/// `Process`-spawned daemon never sees SIGTERM and outlives the test (docs/linux/services.md).
/// Under `timeout`, so a test process that dies without stopping it does not leave it running
/// for long.
final class PrivateBus {
    let address: String
    private let pid: pid_t

    init() throws {
        let daemon = "/usr/bin/dbus-daemon"
        try #require(FileManager.default.isExecutableFile(atPath: daemon),
                     "the GDBus tests need dbus-daemon (Arch: dbus; docs/linux/dev.md)")
        var fds: [Int32] = [-1, -1]
        try #require(pipe(&fds) == 0)
        defer { close(fds[0]) }

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addclose(&actions, fds[1])
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var empty = sigset_t(), all = sigset_t()
        sigemptyset(&empty)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let arguments = ["/usr/bin/timeout", "600", daemon, "--session", "--nofork", "--nopidfile", "--print-address=1"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, arguments[0], &actions, &attributes, &argv, environ)
        close(fds[1])
        try #require(status == 0, "posix_spawn dbus-daemon: \(status)")
        pid = child

        var output = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 256)
        while !output.contains(UInt8(ascii: "\n")) {
            let count = read(fds[0], &buffer, buffer.count)
            if count <= 0 { break }
            output += buffer[0..<count]
        }
        address = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty { stop() }
        try #require(!address.isEmpty, "dbus-daemon printed no address")
    }

    func stop() {
        kill(pid, SIGTERM)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
}

/// Two clients of a fresh private bus, closed (and the bus stopped) when `body` returns. The body
/// runs inside the pump.
@MainActor
func withPrivateBus(
    _ body: @escaping @MainActor (_ a: DBusConnection, _ b: DBusConnection) async throws -> Void
) async throws {
    let bus = try PrivateBus()
    defer { bus.stop() }
    try await GLibPump.run {
        let a = try await DBusConnection.open(address: bus.address)
        let b = try await DBusConnection.open(address: bus.address)
        do {
            try await body(a, b)
        } catch {
            try? await a.close()
            try? await b.close()
            throw error
        }
        if !a.isClosed { try await a.close() }
        if !b.isClosed { try await b.close() }
    }
}

// MARK: - Echo service

/// `se.tkz.tkzmux.Test` at `/se/tkz/tkzmux/Test`, the mock service the call tests talk to.
enum EchoService {
    static let interface = "se.tkz.tkzmux.Test"
    static let path = "/se/tkz/tkzmux/Test"
    static let customError = "se.tkz.tkzmux.Test.Error.Custom"

    static let xml = """
        <node>
          <interface name="se.tkz.tkzmux.Test">
            <method name="Echo"><arg type="v" direction="in"/><arg type="v" direction="out"/></method>
            <method name="Pair"><arg type="s" direction="in"/><arg type="u" direction="in"/>
              <arg type="s" direction="out"/><arg type="u" direction="out"/></method>
            <method name="Fail"><arg type="s" direction="in"/><arg type="s" direction="in"/></method>
            <method name="Throw"/>
            <method name="WrongReply"><arg type="u" direction="out"/></method>
            <signal name="Ping"><arg type="s"/><arg type="u"/><arg type="a{sv}"/></signal>
          </interface>
        </node>
        """

    struct Plain: Error {}

    /// Exports the service on `connection`.
    @MainActor
    static func export(on connection: DBusConnection) throws -> DBusToken {
        try connection.exportObject(path: path, interfaceXML: xml) { call in
            switch call.method {
            case "Echo", "Pair":
                return call.arguments
            case "Fail":
                throw DBusError.remote(name: try call.arguments.decode(String.self, at: 0),
                                       message: try call.arguments.decode(String.self, at: 1))
            case "Throw":
                throw Plain()
            case "WrongReply":
                return [.string("not a uint32")]
            default:
                return []
            }
        }
    }

    /// Echo(v) → v on the service owned by `service`, through `client`.
    @MainActor
    static func echo(_ value: DBusValue, via client: DBusConnection, to service: DBusConnection) async throws -> DBusValue {
        let reply = try await client.call(destination: service.uniqueName!, path: path, interface: interface,
                                          method: "Echo", arguments: [.variant(value)], reply: "(v)")
        return try #require(reply.first?.variantValue)
    }
}

// MARK: - Generators

/// SplitMix64: small, fast, and the same sequence for the same seed everywhere.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// A seed derived from `name` with FNV-1a, stable across runs (unlike `Hasher`).
    init(named name: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        self.init(seed: hash)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// Random D-Bus types and values of them.
struct ValueGenerator {
    var rng: SeededGenerator

    /// How a `v` picks its contents: any type, or biased to `a{sv}` or to another `v`, which is
    /// what the nested cases need.
    enum VariantBias { case any, vardict, variant }
    var bias: VariantBias = .any

    init(seed name: String) { rng = SeededGenerator(named: name) }

    private static let scalars: [Unicode.Scalar] = [
        "a", "z", "A", "Z", "0", "9", " ", "/", "{", "}", "\"", "\\", "\n", "\t", "\u{7f}",
        "é", "ß", "ø", "Ω", "Ж", "ש", "ع", "中", "文", "日", "\u{301}", "\u{200d}", "\u{fffd}",
        "😀", "🧪", "\u{10ffff}", "\u{1}",
    ]

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func bool() -> Bool { Bool.random(using: &rng) }

    mutating func string() -> String {
        var s = String.UnicodeScalarView()
        for _ in 0..<int(0...24) { s.append(Self.scalars.randomElement(using: &rng)!) }
        return String(s)
    }

    mutating func objectPath() -> String {
        let count = int(0...4)
        if count == 0 { return "/" }
        let chars = Array("abcXYZ019_")
        return (0..<count).map { _ in
            "/" + String((0..<int(1...8)).map { _ in chars.randomElement(using: &rng)! })
        }.joined()
    }

    mutating func double() -> Double {
        if int(0...5) == 0 {
            return [0.0, -0.0, .infinity, -.infinity, .leastNonzeroMagnitude, .greatestFiniteMagnitude][int(0...5)]
        }
        // Any other double but NaN, sign included: an all-ones exponent loses a bit.
        var bits = rng.next()
        if (bits >> 52) & 0x7ff == 0x7ff { bits &= ~(UInt64(1) << 52) }
        return Double(bitPattern: bits)
    }

    /// How many arrays the value being drawn is inside.
    private var arrayDepth = 0

    /// A random basic type (a dictionary key). Never `g` inside an array: GLib 2.88's GDBus
    /// misreads some of those (`glibMisreadsSignaturesInArrays`), and the fuzz cases test this
    /// wrapper, not that.
    mutating func basicType(inArray: Bool = false) -> DBusType {
        let types: [DBusType] = [.boolean, .byte, .int16, .uint16, .int32, .uint32, .int64, .uint64, .double,
                                 .string, .objectPath, .signature]
        return types[int(0...(inArray ? 10 : 11))]
    }

    /// A random complete type, at most `depth` containers deep.
    mutating func type(depth: Int, inArray: Bool = false) -> DBusType {
        let pick = int(0...(depth > 0 ? 17 : 12))
        switch pick {
        case 0...11: return basicType(inArray: inArray)
        case 12: return .variant
        case 13, 14: return .array(type(depth: depth - 1, inArray: true))
        case 15, 16: return .dictionary(key: basicType(inArray: true), value: type(depth: depth - 1, inArray: true))
        default: return .structure((0..<int(1...3)).map { _ in type(depth: depth - 1, inArray: inArray) })
        }
    }

    /// A random value of `type`.
    mutating func value(of type: DBusType, depth: Int = 3) -> DBusValue {
        switch type {
        case .boolean: return .boolean(bool())
        case .byte: return .byte(UInt8.random(in: .min ... .max, using: &rng))
        case .int16: return .int16(Int16.random(in: .min ... .max, using: &rng))
        case .uint16: return .uint16(UInt16.random(in: .min ... .max, using: &rng))
        case .int32: return .int32(Int32.random(in: .min ... .max, using: &rng))
        case .uint32: return .uint32(UInt32.random(in: .min ... .max, using: &rng))
        case .int64: return .int64(Int64.random(in: .min ... .max, using: &rng))
        case .uint64: return .uint64(UInt64.random(in: .min ... .max, using: &rng))
        case .double: return .double(double())
        case .string: return .string(string())
        case .objectPath: return .objectPath(objectPath())
        case .signature: return .signature(self.type(depth: 2).signature)
        case .variant:
            let inArray = arrayDepth > 0
            let inner: DBusType
            switch (bias, depth > 0) {
            case (_, false): inner = basicType(inArray: inArray)
            case (.vardict, true): inner = bool() ? .dictionary(key: .string, value: .variant) : basicType(inArray: inArray)
            case (.variant, true): inner = bool() ? .variant : self.type(depth: 1, inArray: inArray)
            case (.any, true): inner = self.type(depth: min(depth, 2), inArray: inArray)
            }
            return .variant(value(of: inner, depth: depth - 1))
        case .array(let element):
            arrayDepth += 1
            defer { arrayDepth -= 1 }
            return .array(element, (0..<int(0...5)).map { _ in value(of: element, depth: depth - 1) })
        case .dictionary(let key, let valueType):
            arrayDepth += 1
            defer { arrayDepth -= 1 }
            return .dictionary(key: key, value: valueType, (0..<int(0...5)).map { _ in
                DBusDictEntry(key: value(of: key), value: value(of: valueType, depth: depth - 1))
            })
        case .structure(let fields):
            return .structure(fields.map { value(of: $0, depth: depth - 1) })
        }
    }
}

// MARK: - Process memory

/// Whether this is the AddressSanitizer build (the sanitized runtime exports `__asan_init`), whose
/// quarantine holds freed memory back, so resident size says nothing about leaks there; LSan does.
let addressSanitizer: Bool = dlsym(nil, "__asan_init") != nil

/// Resident set size in bytes, from /proc/self/statm.
func residentBytes() throws -> Int {
    let statm = try String(contentsOfFile: "/proc/self/statm", encoding: .utf8)
    let pages = try #require(Int(statm.split(separator: " ")[1]))
    return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
}
