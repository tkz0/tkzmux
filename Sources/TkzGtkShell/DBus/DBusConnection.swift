// DBusConnection — tkzmux's one D-Bus client, over GIO's GDBus (WOR-320 S1).
//
// GTK already links GIO, so this needs no libdbus or libsystemd (ADR-0001, linkage-policy.txt).
// Every operation is asynchronous; nothing here blocks on the bus:
//
//   bus(_:), open(address:)  g_bus_get / g_dbus_connection_new_for_address
//   call                      g_dbus_connection_call, reply type checked before anything is read
//   emitSignal                g_dbus_connection_emit_signal (queues the message)
//   subscribe                 g_dbus_connection_signal_subscribe → DBusToken
//   watchName, ownName        g_bus_watch_name / g_bus_own_name on this connection → DBusToken
//   exportObject              g_dbus_connection_register_object (tests' mock services) → DBusToken
//
// Threading. GDBus delivers every callback in the thread-default GMainContext of the thread that
// started the operation, captured at the call. The wrapper is `@MainActor`, and in the app the main
// actor is the GTK thread iterating the default context (MainQueueBridge), so replies, signals and
// name events arrive on the main actor with no hop. Handlers are entered through
// `MainActor.assumeIsolated`, which traps rather than races if that ever stops holding. Never push
// a thread-default context around these calls. Tests, where the main actor is a libdispatch worker
// and nothing iterates GLib, pump the default context themselves (GDBusTestSupport).
//
// Ownership. Every callback's state is a Swift box retained once with `Unmanaged` and released in
// exactly one place: the completion of a one-shot operation, or the GDestroyNotify GIO calls after
// a subscription, watch, ownership or export ends (ClosureBoxes counts them as `.dbus`). Names and
// paths are checked in Swift first, because a failed GIO precondition returns without calling
// back, which would strand a continuation and leak its box. GVariant ownership is GVariantCodec's.
//
// Not covered: unix fd passing (`h`, g_dbus_connection_call_with_unix_fd_list), peer-to-peer
// connections, and Task cancellation of a pending call (a call ends by reply, error or its
// timeout). Each is an addition here, not a change, when a caller needs it.

import CGtk
import TkzLinuxShim
import TkzPlatform

let dbusLog = TkzLogger(subsystem: "se.tkz.tkzmux", category: "dbus")

/// The two message buses.
public enum DBusBus: Sendable {
    case session
    case system
}

/// A signal as a subscription receives it.
public struct DBusSignal: Sendable, Hashable {
    public var sender: String
    public var path: String
    public var interface: String
    public var member: String
    public var arguments: [DBusValue]
}

/// A method call on an exported object.
public struct DBusMethodCall: Sendable, Hashable {
    public var sender: String
    public var path: String
    public var interface: String
    public var method: String
    public var arguments: [DBusValue]
}

@MainActor
public final class DBusConnection {
    /// The default timeout of a call, GDBus's own (25 s).
    public static let defaultTimeout: Int32 = -1

    let ref: GObjectRef<OpaquePointer>
    var pointer: OpaquePointer { ref.pointer }

    private init(adopting connection: OpaquePointer) {
        ref = GObjectRef(adopting: connection)
    }

    // MARK: Connecting

    /// The process's connection to `bus`. GIO keeps one per bus, shared with anything else in the
    /// process that asks (GApplication included), so every call returns the same connection.
    ///
    /// Exit-on-close is turned off: GIO's default would end tkzmux, and every session in it, when
    /// the bus goes away. A closed connection fails its calls with `.closed` instead.
    public static func bus(_ bus: DBusBus) async throws -> DBusConnection {
        let address = try await withCheckedThrowingContinuation { continuation in
            let box = Unmanaged.passRetained(ConnectBox(continuation)).toOpaque()
            g_bus_get(bus == .session ? G_BUS_TYPE_SESSION : G_BUS_TYPE_SYSTEM, nil, busGetDone, box)
        }
        let connection = OpaquePointer(bitPattern: address)!
        g_dbus_connection_set_exit_on_close(connection, 0)
        return DBusConnection(adopting: connection)
    }

    /// A new, private connection to the message bus at `address` (a D-Bus address such as
    /// `unix:path=/run/user/1000/bus`), authenticated and registered with the bus. Tests use it
    /// for a second client or a private bus; it is never shared, and closing it is the caller's.
    public static func open(address: String) async throws -> DBusConnection {
        guard g_dbus_is_address(address) != 0 else { throw DBusError.invalidName(address) }
        let flags = tkz_dbus_connection_flags_bus_client()
        let connection = try await withCheckedThrowingContinuation { continuation in
            let box = Unmanaged.passRetained(ConnectBox(continuation)).toOpaque()
            g_dbus_connection_new_for_address(address, flags, nil, nil, newForAddressDone, box)
        }
        return DBusConnection(adopting: OpaquePointer(bitPattern: connection)!)
    }

    /// Closes the connection. Pending calls fail with `.closed`, and tokens on it stop delivering.
    public func close() async throws {
        _ = try await withCheckedThrowingContinuation { continuation in
            let box = Unmanaged.passRetained(ConnectBox(continuation)).toOpaque()
            g_dbus_connection_close(pointer, nil, closeDone, box)
        }
    }

    /// The unique name the bus assigned this connection (`:1.42`).
    public var uniqueName: String? {
        g_dbus_connection_get_unique_name(pointer).map { String(cString: $0) }
    }

    public var isClosed: Bool { g_dbus_connection_is_closed(pointer) != 0 }

    // MARK: Calls

    /// Calls `method` and returns the reply's values. `reply` is the reply's type as a tuple
    /// (`(u)`, `(sa{sv})`, `()`): a reply of any other type throws `.typeMismatch` and nothing of it
    /// is read. Pass nil only to accept any reply. A D-Bus error reply throws `.remote`.
    public func call(
        destination: String, path: String, interface: String, method: String,
        arguments: [DBusValue] = [], reply: String?, timeoutMilliseconds: Int32 = defaultTimeout
    ) async throws -> [DBusValue] {
        try Self.check(busName: destination)
        try Self.check(path: path)
        try Self.check(interface: interface)
        try Self.check(member: method)
        if let reply { try Self.check(bodyType: reply) }
        let body = try GVariantCodec.makeBody(arguments)
        return try await withCheckedThrowingContinuation { continuation in
            let box = Unmanaged.passRetained(CallBox(continuation, reply: reply)).toOpaque()
            g_dbus_connection_call(pointer, destination, path, interface, method, body, nil,
                                   GDBusCallFlags(rawValue: 0), timeoutMilliseconds, nil, callDone, box)
        }
    }

    /// Calls a method whose reply is one value of type `T`, such as `(o)` or `(u)`.
    public func call<T: DBusRepresentable>(
        destination: String, path: String, interface: String, method: String,
        arguments: [DBusValue] = [], returning type: T.Type,
        timeoutMilliseconds: Int32 = defaultTimeout
    ) async throws -> T {
        let values = try await call(destination: destination, path: path, interface: interface, method: method,
                                    arguments: arguments, reply: "(" + T.dbusType.signature + ")",
                                    timeoutMilliseconds: timeoutMilliseconds)
        return try values.decode(T.self, at: 0)
    }

    // MARK: Signals

    /// Emits a signal, to `destination` or (nil) to every subscriber. The message is queued and
    /// sent by GDBus's worker; this does not wait for the bus.
    public func emitSignal(
        destination: String? = nil, path: String, interface: String, name: String,
        arguments: [DBusValue] = []
    ) throws(DBusError) {
        if let destination { try Self.check(busName: destination) }
        try Self.check(path: path)
        try Self.check(interface: interface)
        try Self.check(member: name)
        let body = try GVariantCodec.makeBody(arguments)
        var error: UnsafeMutablePointer<GError>?
        if g_dbus_connection_emit_signal(pointer, destination, path, interface, name, body, &error) == 0 {
            throw error.map { DBusError(consuming: $0) } ?? .closed
        }
    }

    /// Calls `handler` for every matching signal until the token is cancelled or released. A nil
    /// criterion matches anything; `arg0` matches a first argument that is that string. A signal
    /// whose arguments include a type DBusValue cannot hold is logged and not delivered.
    public func subscribe(
        sender: String? = nil, interface: String? = nil, member: String? = nil, path: String? = nil,
        arg0: String? = nil, handler: @escaping @MainActor (DBusSignal) -> Void
    ) throws(DBusError) -> DBusToken {
        if let sender { try Self.check(busName: sender) }
        if let interface { try Self.check(interface: interface) }
        if let member { try Self.check(member: member) }
        if let path { try Self.check(path: path) }
        if let arg0, arg0.utf8.contains(0) { throw .invalidValue("arg0 contains NUL") }
        let box = Unmanaged.passRetained(HandlerBox(handler)).toOpaque()
        let id = g_dbus_connection_signal_subscribe(pointer, sender, interface, member, path, arg0,
                                                    GDBusSignalFlags(rawValue: 0), signalReceived, box, releaseHandlerBox)
        return DBusToken(self, .signal(id))
    }

    // MARK: Names

    /// Watches `name` (well-known or unique): `onAppeared` with the owner's unique name whenever it
    /// gains one, `onVanished` whenever it has none. One of them always runs first, soon after the
    /// watch starts, so a name with no owner reports `onVanished` once.
    public func watchName(
        _ name: String,
        onAppeared: @escaping @MainActor (_ owner: String) -> Void,
        onVanished: @escaping @MainActor () -> Void
    ) throws(DBusError) -> DBusToken {
        try Self.check(busName: name)
        let box = Unmanaged.passRetained(HandlerBox(NameHandlers(appeared: onAppeared, lost: onVanished)))
        let id = g_bus_watch_name_on_connection(pointer, name, GBusNameWatcherFlags(rawValue: 0),
                                                nameAppeared, nameVanished, box.toOpaque(), releaseHandlerBox)
        return DBusToken(self, .watch(id))
    }

    /// Requests the well-known `name`: `onAcquired` once this connection owns it, `onLost` when it
    /// cannot have it or loses it. The name is released when the token is.
    public func ownName(
        _ name: String, allowReplacement: Bool = false, replace: Bool = false,
        onAcquired: @escaping @MainActor () -> Void = {},
        onLost: @escaping @MainActor () -> Void = {}
    ) throws(DBusError) -> DBusToken {
        try Self.check(busName: name)
        guard g_dbus_is_unique_name(name) == 0 else { throw .invalidName(name) }
        let flags = tkz_bus_name_owner_flags(allowReplacement ? 1 : 0, replace ? 1 : 0)
        let handlers = NameHandlers(appeared: { _ in onAcquired() }, lost: onLost)
        let box = Unmanaged.passRetained(HandlerBox(handlers)).toOpaque()
        let id = g_bus_own_name_on_connection(pointer, name, flags,
                                              nameAcquired, nameLost, box, releaseHandlerBox)
        return DBusToken(self, .ownership(id))
    }

    // MARK: Objects

    /// Exports the one interface `interfaceXML` declares (introspection XML, `<node><interface>…`)
    /// at `path`. GDBus checks each call's arguments against it before `handler` runs. `handler`
    /// returns the reply's values, which must match the method's out arguments, or throws: a
    /// `.remote` error is replied with its name and message, any other error as
    /// `org.freedesktop.DBus.Error.Failed`. Unexported when the token is cancelled or released.
    public func exportObject(
        path: String, interfaceXML: String,
        handler: @escaping @MainActor (DBusMethodCall) throws -> [DBusValue]
    ) throws(DBusError) -> DBusToken {
        try Self.check(path: path)
        var error: UnsafeMutablePointer<GError>?
        guard let node = g_dbus_node_info_new_for_xml(interfaceXML, &error) else {
            throw error.map { DBusError(consuming: $0) } ?? .invalidValue("introspection XML")
        }
        defer { g_dbus_node_info_unref(node) }
        guard let interfaces = node.pointee.interfaces, let info = interfaces[0], interfaces[1] == nil else {
            throw .invalidValue("the introspection XML must declare exactly one interface")
        }
        let box = Unmanaged.passRetained(HandlerBox(handler)).toOpaque()
        let id = tkz_dbus_register_object(pointer, path, info, methodCalled, box, releaseHandlerBox, &error)
        guard id != 0 else {
            throw error.map { DBusError(consuming: $0) } ?? .invalidName(path)
        }
        return DBusToken(self, .object(id))
    }

    // MARK: Checks GIO would assert on

    static func check(busName: String) throws(DBusError) {
        guard g_dbus_is_name(busName) != 0 else { throw .invalidName(busName) }
    }

    static func check(path: String) throws(DBusError) {
        guard !path.utf8.contains(0), g_variant_is_object_path(path) != 0 else { throw .invalidName(path) }
    }

    static func check(interface: String) throws(DBusError) {
        guard g_dbus_is_interface_name(interface) != 0 else { throw .invalidName(interface) }
    }

    static func check(member: String) throws(DBusError) {
        guard g_dbus_is_member_name(member) != 0 else { throw .invalidName(member) }
    }

    /// A reply type is a tuple: `()` or one structure of D-Bus types.
    static func check(bodyType: String) throws(DBusError) {
        if bodyType == "()" { return }
        guard case .structure = try DBusType(signature: bodyType) else { throw .invalidSignature(bodyType) }
    }
}

// MARK: - Tokens

/// A live subscription, name watch, name ownership or exported object. It ends when `cancel()` is
/// called or the token is released, whichever comes first; the connection lives at least as long.
/// GIO releases the handler's box later, from the main context, once no callback can still run.
@MainActor
public final class DBusToken {
    enum Kind {
        case signal(guint)
        case watch(guint)
        case ownership(guint)
        case object(guint)
    }

    private let connection: DBusConnection
    private var kind: Kind?

    init(_ connection: DBusConnection, _ kind: Kind) {
        self.connection = connection
        self.kind = kind
    }

    public var isActive: Bool { kind != nil }

    public func cancel() {
        guard let kind else { return }
        self.kind = nil
        switch kind {
        case .signal(let id): g_dbus_connection_signal_unsubscribe(connection.pointer, id)
        case .watch(let id): g_bus_unwatch_name(id)
        case .ownership(let id): g_bus_unown_name(id)
        case .object(let id): _ = g_dbus_connection_unregister_object(connection.pointer, id)
        }
    }

    isolated deinit {
        cancel()
    }
}
