// GDBusConnectionTests — WOR-320 S1. The GDBus wrapper against a real dbus-daemon: calls and
// replies, GError → DBusError mapping, signal delivery, name watching and NameOwnerChanged, token
// lifetimes, and 10,000 round trips with bounded memory.
//
// Each test runs its own private bus (GDBusTestSupport's PrivateBus) with two clients, `a` and
// `b`, inside the GLib pump; `bus(.session)` and `bus(.system)` are tried against the
// environment's buses when there are any (CI runs this under `dbus-run-session`). Every test ends
// with the D-Bus box count back at its baseline: each box GIO was given was released exactly once.
import CGtk
import Foundation
import Testing
@testable import TkzGtkShell

/// Something a handler appends to, checked by the test.
@MainActor
final class Recorder<T> {
    var items: [T] = []
}

/// Polls `condition` while the pump runs, for up to `seconds`.
@MainActor
func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

@Suite(.serialized) @MainActor
struct GDBusConnectionTests {
    /// Runs `body` on a private bus and checks that every D-Bus box was released afterwards.
    func onPrivateBus(_ body: @escaping @MainActor (DBusConnection, DBusConnection) async throws -> Void) async throws {
        let baseline = ClosureBoxes.live(.dbus)
        try await withPrivateBus(body)
        try await GLibPump.run { await GLibPump.settle() }
        #expect(ClosureBoxes.live(.dbus) == baseline, "a D-Bus callback box was not released")
    }

    // MARK: Connecting

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] != nil))
    func theSessionBusAnswers() async throws {
        let id = try await GLibPump.run {
            let session = try await DBusConnection.bus(.session)
            let again = try await DBusConnection.bus(.session)
            #expect(session.pointer == again.pointer, "g_bus_get shares one connection per bus")
            #expect(session.uniqueName?.hasPrefix(":") == true)
            return try await session.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                          interface: "org.freedesktop.DBus", method: "GetId", returning: String.self)
        }
        #expect(id.count == 32)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/run/dbus/system_bus_socket")))
    func theSystemBusAnswers() async throws {
        let names = try await GLibPump.run {
            let system = try await DBusConnection.bus(.system)
            return try await system.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                         interface: "org.freedesktop.DBus", method: "ListNames",
                                         returning: [String].self)
        }
        #expect(names.contains("org.freedesktop.DBus"))
    }

    @Test func aBadAddressFailsWithoutTouchingTheBus() async throws {
        try await GLibPump.run {
            await #expect(throws: DBusError.invalidName("not an address")) {
                try await DBusConnection.open(address: "not an address")
            }
            await #expect(throws: DBusError.self) {
                try await DBusConnection.open(address: "unix:path=/nonexistent/tkzmux-test-bus")
            }
        }
    }

    // MARK: Calls

    @Test func callAndReply() async throws {
        try await onPrivateBus { a, b in
            let service = try EchoService.export(on: a)
            let reply = try await b.call(destination: a.uniqueName!, path: EchoService.path,
                                         interface: EchoService.interface, method: "Pair",
                                         arguments: [.string("tkzmux"), .uint32(42)], reply: "(su)")
            #expect(reply == [.string("tkzmux"), .uint32(42)])
            let value = DBusValue.vardict(["nested": .vardict(["v": .variant(.objectPath("/x"))]), "n": .int32(-5)])
            #expect(try await EchoService.echo(value, via: b, to: a) == value)

            // Typed, against the bus driver: GetNameOwner (s).
            let owner = try await b.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                         interface: "org.freedesktop.DBus", method: "GetNameOwner",
                                         arguments: [.string(a.uniqueName!)], returning: String.self)
            #expect(owner == a.uniqueName)
            service.cancel()
        }
    }

    @Test func aReplyOfTheWrongTypeThrows() async throws {
        try await onPrivateBus { a, b in
            let service = try EchoService.export(on: a)
            // The bus driver's GetNameOwner replies (s).
            await #expect(throws: DBusError.typeMismatch(expected: "(u)", actual: "(s)")) {
                try await b.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                 interface: "org.freedesktop.DBus", method: "GetNameOwner",
                                 arguments: [.string(b.uniqueName!)], reply: "(u)")
            }
            await #expect(throws: DBusError.typeMismatch(expected: "(u)", actual: "(s)")) {
                try await b.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                 interface: "org.freedesktop.DBus", method: "GetNameOwner",
                                 arguments: [.string(b.uniqueName!)], returning: UInt32.self)
            }
            // Echo replies (v), whatever the variant holds.
            await #expect(throws: DBusError.typeMismatch(expected: "(u)", actual: "(v)")) {
                try await b.call(destination: a.uniqueName!, path: EchoService.path, interface: EchoService.interface,
                                 method: "Echo", arguments: [.variant(.uint32(1))], reply: "(u)")
            }
            await #expect(throws: DBusError.invalidSignature("u")) {
                try await b.call(destination: a.uniqueName!, path: EchoService.path, interface: EchoService.interface,
                                 method: "Echo", arguments: [.variant(.uint32(1))], reply: "u")
            }
            service.cancel()
        }
    }

    @Test func errorsMapToDBusError() async throws {
        try await onPrivateBus { a, b in
            let service = try EchoService.export(on: a)
            let dest = a.uniqueName!
            func call(_ method: String, _ arguments: [DBusValue] = [], destination: String? = nil,
                      reply: String? = nil) async throws -> [DBusValue] {
                try await b.call(destination: destination ?? dest, path: EchoService.path,
                                 interface: EchoService.interface, method: method, arguments: arguments, reply: reply)
            }
            /// The D-Bus error name a call fails with.
            func remoteName(_ method: String, _ arguments: [DBusValue] = [], destination: String? = nil) async -> String? {
                do {
                    _ = try await call(method, arguments, destination: destination)
                } catch let DBusError.remote(name, _) {
                    return name
                } catch {
                    Issue.record("expected a remote error, got \(error)")
                }
                return nil
            }

            #expect(await remoteName("Echo", destination: "se.tkz.tkzmux.Nobody")
                    == "org.freedesktop.DBus.Error.ServiceUnknown")
            #expect(await remoteName("NoSuchMethod") == "org.freedesktop.DBus.Error.UnknownMethod")
            // GDBus checks the in arguments against the introspection data.
            #expect(await remoteName("Echo", [.string("not a variant")])
                    == "org.freedesktop.DBus.Error.InvalidArgs")
            // A handler's `.remote` error goes out under its own name and message.
            await #expect(throws: DBusError.remote(name: EchoService.customError, message: "boom")) {
                try await call("Fail", [.string(EchoService.customError), .string("boom")])
            }
            // Any other error is Failed, and so is a reply that does not match the out arguments.
            #expect(await remoteName("Throw") == "org.freedesktop.DBus.Error.Failed")
            #expect(await remoteName("WrongReply") == "org.freedesktop.DBus.Error.Failed")
            // An error name that is not a valid D-Bus name is replaced by Failed, not asserted on.
            #expect(await remoteName("Fail", [.string("not a name"), .string("x")])
                    == "org.freedesktop.DBus.Error.Failed")

            // Names and paths GIO would assert on are refused before GIO sees them.
            await #expect(throws: DBusError.invalidName("no/slash")) {
                try await b.call(destination: dest, path: "no/slash", interface: "a.b", method: "M", reply: nil)
            }
            await #expect(throws: DBusError.invalidName("bad interface")) {
                try await b.call(destination: dest, path: "/", interface: "bad interface", method: "M", reply: nil)
            }
            await #expect(throws: DBusError.invalidName("1bad")) {
                try await b.call(destination: dest, path: "/", interface: "a.b", method: "1bad", reply: nil)
            }
            await #expect(throws: DBusError.invalidName("")) {
                try await b.call(destination: "", path: "/", interface: "a.b", method: "M", reply: nil)
            }
            await #expect(throws: DBusError.self) {
                try await call("Echo", [.variant(.string("a\u{0}b"))])
            }
            #expect(throws: DBusError.self) { try b.subscribe(path: "relative") { _ in } }
            #expect(throws: DBusError.self) { try b.watchName("not a name", onAppeared: { _ in }, onVanished: {}) }
            #expect(throws: DBusError.self) { try b.ownName(":1.1") }
            #expect(throws: DBusError.self) { try b.emitSignal(path: "/", interface: "a.b", name: "bad-member") }
            #expect(throws: DBusError.self) {
                try a.exportObject(path: "/x", interfaceXML: "<node/>") { _ in [] }
            }
            // A second export of the same interface at the same path fails, and its box is released
            // once (the suite's baseline check).
            #expect(throws: DBusError.self) {
                try a.exportObject(path: EchoService.path, interfaceXML: EchoService.xml) { _ in [] }
            }

            service.cancel()
            // Unexported: the object is gone.
            #expect(await remoteName("Echo", [.variant(.byte(1))])
                    == "org.freedesktop.DBus.Error.UnknownMethod")

            // A closed connection fails its calls locally.
            try await b.close()
            await #expect(throws: DBusError.closed) { try await call("Echo", [.variant(.byte(1))]) }
        }
    }

    /// A call nobody answers ends with its timeout. The service is registered from a private
    /// context that is not iterated until the end, so GDBus queues the call there unanswered.
    @Test func anUnansweredCallTimesOut() async throws {
        try await onPrivateBus { a, b in
            let frozen = g_main_context_new()!
            g_main_context_push_thread_default(frozen)
            let service: DBusToken
            do {
                service = try EchoService.export(on: a)
            } catch {
                g_main_context_pop_thread_default(frozen)
                throw error
            }
            g_main_context_pop_thread_default(frozen)
            let started = ContinuousClock.now
            await #expect(throws: DBusError.timedOut) {
                try await b.call(destination: a.uniqueName!, path: EchoService.path, interface: EchoService.interface,
                                 method: "Echo", arguments: [.variant(.byte(1))], reply: "(v)",
                                 timeoutMilliseconds: 100)
            }
            #expect(ContinuousClock.now - started < .seconds(5))
            service.cancel()
            // Let the frozen context answer (too late) and release the registration.
            while g_main_context_iteration(frozen, 0) != 0 {}
            g_main_context_unref(frozen)
        }
    }

    // MARK: Signals

    @Test func signalsAreDeliveredUntilCancelled() async throws {
        try await onPrivateBus { a, b in
            let all = Recorder<DBusSignal>(), filtered = Recorder<DBusSignal>()
            let subscription = try a.subscribe(interface: EchoService.interface, member: "Ping") { all.items.append($0) }
            let byArg0 = try a.subscribe(interface: EchoService.interface, member: "Ping", arg0: "second") {
                filtered.items.append($0)
            }
            // A match rule is in place once the bus has seen the AddMatch: a round trip on `a`.
            _ = try await a.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                 interface: "org.freedesktop.DBus", method: "GetId", returning: String.self)

            let payload = DBusValue.vardict(["count": .uint32(2), "v": .variant(.stringArray(["x"]))])
            try b.emitSignal(path: EchoService.path, interface: EchoService.interface, name: "Ping",
                             arguments: [.string("first"), .uint32(1), payload])
            try b.emitSignal(path: EchoService.path, interface: EchoService.interface, name: "Ping",
                             arguments: [.string("second"), .uint32(2), payload])
            #expect(await eventually { all.items.count == 2 && filtered.items.count == 1 })
            let first = try #require(all.items.first)
            #expect(first.sender == b.uniqueName)
            #expect(first.path == EchoService.path && first.interface == EchoService.interface && first.member == "Ping")
            #expect(first.arguments == [.string("first"), .uint32(1), payload])
            #expect(filtered.items.first?.arguments.first == .string("second"))

            // A signal to one destination reaches only it.
            try b.emitSignal(destination: a.uniqueName, path: EchoService.path, interface: EchoService.interface,
                             name: "Ping", arguments: [.string("direct"), .uint32(3), payload])
            #expect(await eventually { all.items.count == 3 })

            subscription.cancel()
            #expect(!subscription.isActive)
            try b.emitSignal(path: EchoService.path, interface: EchoService.interface, name: "Ping",
                             arguments: [.string("second"), .uint32(4), payload])
            #expect(await eventually { filtered.items.count == 2 })
            #expect(all.items.count == 3, "a cancelled subscription delivered")
            _ = byArg0   // released at the end of the scope, which unsubscribes it
        }
    }

    /// Releasing a token ends it like `cancel()`.
    @Test func releasingATokenUnsubscribes() async throws {
        try await onPrivateBus { a, b in
            let seen = Recorder<DBusSignal>()
            var token: DBusToken? = try a.subscribe(member: "Ping") { seen.items.append($0) }
            _ = try await a.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                 interface: "org.freedesktop.DBus", method: "GetId", returning: String.self)
            try b.emitSignal(path: "/", interface: EchoService.interface, name: "Ping",
                             arguments: [.string(""), .uint32(0), .vardict([:])])
            #expect(await eventually { seen.items.count == 1 })
            #expect(token?.isActive == true)
            token = nil
            try b.emitSignal(path: "/", interface: EchoService.interface, name: "Ping",
                             arguments: [.string(""), .uint32(0), .vardict([:])])
            // A round trip through the bus after the emit: had the signal been delivered, it would
            // have arrived first.
            _ = try await a.call(destination: "org.freedesktop.DBus", path: "/org/freedesktop/DBus",
                                 interface: "org.freedesktop.DBus", method: "GetId", returning: String.self)
            await GLibPump.settle()
            #expect(seen.items.count == 1)
        }
    }

    // MARK: Names

    @Test func nameWatchingAndNameOwnerChanged() async throws {
        try await onPrivateBus { a, b in
            let name = "se.tkz.tkzmux.Test.Watched"
            let events = Recorder<String>()
            let changes = Recorder<[DBusValue]>()
            let watch = try a.watchName(name, onAppeared: { events.items.append("appeared " + $0) },
                                        onVanished: { events.items.append("vanished") })
            let ownerChanges = try a.subscribe(sender: "org.freedesktop.DBus", interface: "org.freedesktop.DBus",
                                               member: "NameOwnerChanged", path: "/org/freedesktop/DBus",
                                               arg0: name) { changes.items.append($0.arguments) }
            // No owner yet: the watch reports that first.
            #expect(await eventually { events.items == ["vanished"] })

            let acquired = Recorder<Bool>()
            let ownership = try b.ownName(name, onAcquired: { acquired.items.append(true) },
                                          onLost: { acquired.items.append(false) })
            #expect(await eventually { acquired.items == [true] })
            #expect(await eventually { events.items == ["vanished", "appeared " + b.uniqueName!] })
            #expect(await eventually { changes.items.count == 1 })
            #expect(changes.items.first == [.string(name), .string(""), .string(b.uniqueName!)])

            // Releasing the name: vanished again, and NameOwnerChanged with the old owner.
            ownership.cancel()
            #expect(await eventually { events.items.count == 3 })
            #expect(events.items.last == "vanished")
            #expect(await eventually { changes.items.count == 2 })
            #expect(changes.items.last == [.string(name), .string(b.uniqueName!), .string("")])

            // An owner whose connection closes loses the name the same way.
            let again = try b.ownName(name)
            #expect(await eventually { events.items.count == 4 })
            let unique = b.uniqueName!
            try await b.close()
            #expect(await eventually { events.items.count == 5 && events.items.last == "vanished" })
            #expect(await eventually { changes.items.last == [.string(name), .string(unique), .string("")] })
            again.cancel()
            watch.cancel()
            ownerChanges.cancel()
        }
    }

    @Test func aSecondOwnerQueuesAndTakesOverOrIsRefused() async throws {
        try await onPrivateBus { a, b in
            let name = "se.tkz.tkzmux.Test.Owned"
            let first = Recorder<Bool>(), second = Recorder<Bool>()
            let ownerA = try a.ownName(name, allowReplacement: true, onAcquired: { first.items.append(true) },
                                       onLost: { first.items.append(false) })
            #expect(await eventually { first.items == [true] })
            // Without `replace`, b cannot have it.
            let refused = try b.ownName(name, onAcquired: { second.items.append(true) },
                                        onLost: { second.items.append(false) })
            #expect(await eventually { second.items == [false] })
            refused.cancel()
            // With it, b takes the name over from a, which allowed replacement.
            let replacing = Recorder<Bool>()
            let ownerB = try b.ownName(name, replace: true, onAcquired: { replacing.items.append(true) },
                                       onLost: { replacing.items.append(false) })
            #expect(await eventually { replacing.items == [true] && first.items == [true, false] })
            ownerA.cancel()
            ownerB.cancel()
        }
    }

    // MARK: Memory

    /// 10,000 calls, each an a{sv} with nested variants out and back: resident memory grows by
    /// less than 1 MB once warmed up, and no callback box is left behind. Under ASan only the box
    /// count is checked; LSan checks the rest.
    @Test func tenThousandRoundTripsStayFlat() async throws {
        try await onPrivateBus { a, b in
            let service = try EchoService.export(on: a)
            var generator = ValueGenerator(seed: "GDBusConnectionTests.memory")
            generator.bias = .vardict
            let payloads = (0..<64).map { _ in generator.value(of: .dictionary(key: .string, value: .variant)) }
            let boxes = ClosureBoxes.live(.dbus)
            for index in 0..<1_000 {
                _ = try await EchoService.echo(payloads[index % payloads.count], via: b, to: a)
            }
            await GLibPump.settle()
            let before = try residentBytes()
            let started = ContinuousClock.now
            for index in 0..<10_000 {
                let payload = payloads[index % payloads.count]
                let back = try await EchoService.echo(payload, via: b, to: a)
                if back != payload { Issue.record("round trip \(index) changed the value") }
            }
            let elapsed = ContinuousClock.now - started
            await GLibPump.settle()
            let growth = try residentBytes() - before
            print("GDBus: 10000 round trips in \(elapsed), RSS growth \(growth) bytes")
            if !addressSanitizer {
                #expect(growth < 1_000_000, "RSS grew by \(growth) bytes over 10,000 round trips")
            }
            #expect(ClosureBoxes.live(.dbus) == boxes)
            service.cancel()
        }
    }

    // MARK: Fuzzed round trips over the bus

    /// 100 random values per signature through Echo(v), on top of the 1,000 per signature the
    /// marshalling tests send through the wire format alone.
    @Test func randomValuesSurviveTheBus() async throws {
        try await onPrivateBus { a, b in
            let service = try EchoService.export(on: a)
            for fuzz in FuzzCase.all {
                var generator = ValueGenerator(seed: "GDBusConnectionTests.bus." + fuzz.name)
                generator.bias = fuzz.bias
                let type = try DBusType(signature: fuzz.signature)
                for _ in 0..<100 {
                    let value = generator.value(of: type)
                    let back = try await EchoService.echo(value, via: b, to: a)
                    if back != value { Issue.record("\(fuzz): \(value) came back as \(back)") }
                }
            }
            service.cancel()
        }
    }
}
