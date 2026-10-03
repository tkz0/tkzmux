// DBusCallbacks — the boxes DBusConnection hands to GIO and the trampolines GIO calls (WOR-320 S1).
//
// A one-shot operation (a call, a connect, a close) owns its box until its completion, which takes
// the retained reference back and resumes the continuation; GIO calls a GAsyncReadyCallback
// exactly once, error or not. A long-lived handler (a subscription, a name watch or ownership, an
// exported object) is released by `releaseHandlerBox`, the GDestroyNotify GIO calls once the
// handler can no longer run. Pointers cross into main-actor closures as addresses, which are
// Sendable, the same way Signals does.
//
// Values are read off GLib's GVariants before the hop, outside the main actor (GVariant is
// immutable and thread-safe), so a handler receives only Swift data.

import CGtk
import TkzLinuxShim

/// A continuation that receives an object's address (0 for a close), and is resumed exactly once.
final class ConnectBox {
    let continuation: CheckedContinuation<UInt, any Error>

    init(_ continuation: CheckedContinuation<UInt, any Error>) {
        self.continuation = continuation
        ClosureBoxes.created(.dbus)
    }

    deinit { ClosureBoxes.destroyed(.dbus) }
}

/// A pending call and the reply type it expects.
final class CallBox {
    let continuation: CheckedContinuation<[DBusValue], any Error>
    let reply: String?

    init(_ continuation: CheckedContinuation<[DBusValue], any Error>, reply: String?) {
        self.continuation = continuation
        self.reply = reply
        ClosureBoxes.created(.dbus)
    }

    deinit { ClosureBoxes.destroyed(.dbus) }
}

/// A long-lived handler. Not main-actor isolated, because `releaseHandlerBox` may run on any thread.
final class HandlerBox<Handler> {
    let handler: Handler

    init(_ handler: Handler) {
        self.handler = handler
        ClosureBoxes.created(.dbus)
    }

    deinit { ClosureBoxes.destroyed(.dbus) }

    static func from(_ address: UInt) -> HandlerBox {
        Unmanaged<HandlerBox>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
    }
}

typealias SignalHandler = @MainActor (DBusSignal) -> Void
typealias MethodHandler = @MainActor (DBusMethodCall) throws -> [DBusValue]

/// A name watch's or ownership's pair: appeared/acquired (with the owner) and vanished/lost.
struct NameHandlers {
    let appeared: @MainActor (String) -> Void
    let lost: @MainActor () -> Void
}

private func string(_ pointer: UnsafePointer<gchar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

private func failure(_ error: UnsafeMutablePointer<GError>?) -> any Error {
    error.map { DBusError(consuming: $0) } ?? DBusError.closed
}

// MARK: - One-shot completions

let busGetDone: GAsyncReadyCallback = { _, result, data in
    let box = Unmanaged<ConnectBox>.fromOpaque(data!).takeRetainedValue()
    var error: UnsafeMutablePointer<GError>?
    if let connection = g_bus_get_finish(result, &error) {
        box.continuation.resume(returning: UInt(bitPattern: UnsafeRawPointer(connection)))
    } else {
        box.continuation.resume(throwing: failure(error))
    }
}

let newForAddressDone: GAsyncReadyCallback = { _, result, data in
    let box = Unmanaged<ConnectBox>.fromOpaque(data!).takeRetainedValue()
    var error: UnsafeMutablePointer<GError>?
    if let connection = g_dbus_connection_new_for_address_finish(result, &error) {
        box.continuation.resume(returning: UInt(bitPattern: UnsafeRawPointer(connection)))
    } else {
        box.continuation.resume(throwing: failure(error))
    }
}

let closeDone: GAsyncReadyCallback = { source, result, data in
    let box = Unmanaged<ConnectBox>.fromOpaque(data!).takeRetainedValue()
    var error: UnsafeMutablePointer<GError>?
    if g_dbus_connection_close_finish(OpaquePointer(source), result, &error) != 0 {
        box.continuation.resume(returning: 0)
    } else {
        box.continuation.resume(throwing: failure(error))
    }
}

/// The reply is transfer full: read (after the type check), then unreffed.
let callDone: GAsyncReadyCallback = { source, result, data in
    let box = Unmanaged<CallBox>.fromOpaque(data!).takeRetainedValue()
    var error: UnsafeMutablePointer<GError>?
    guard let reply = g_dbus_connection_call_finish(OpaquePointer(source), result, &error) else {
        box.continuation.resume(throwing: failure(error))
        return
    }
    defer { g_variant_unref(reply) }
    do {
        box.continuation.resume(returning: try GVariantCodec.readBody(reply, expecting: box.reply))
    } catch {
        box.continuation.resume(throwing: error)
    }
}

// MARK: - Handlers

/// GDestroyNotify for every HandlerBox, whatever its handler type: the retain is the object's.
let releaseHandlerBox: GDestroyNotify = { data in
    Unmanaged<AnyObject>.fromOpaque(data!).release()
}

/// `parameters` is transfer none.
let signalReceived: GDBusSignalCallback = { _, sender, path, interface, member, parameters, data in
    let signal: DBusSignal
    do {
        signal = DBusSignal(sender: string(sender), path: string(path), interface: string(interface),
                            member: string(member),
                            arguments: try parameters.map { try GVariantCodec.readBody($0, expecting: nil) } ?? [])
    } catch {
        dbusLog.warning("dbus: dropped signal \(string(interface), privacy: .public).\(string(member), privacy: .public): \(String(describing: error), privacy: .public)")
        return
    }
    let address = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        HandlerBox<SignalHandler>.from(address).handler(signal)
    }
}

let nameAppeared: GBusNameAppearedCallback = { _, _, owner, data in
    let owner = string(owner)
    let address = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        HandlerBox<NameHandlers>.from(address).handler.appeared(owner)
    }
}

let nameVanished: GBusNameVanishedCallback = { _, _, data in
    let address = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        HandlerBox<NameHandlers>.from(address).handler.lost()
    }
}

let nameAcquired: GBusNameAcquiredCallback = { _, _, data in
    let address = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        HandlerBox<NameHandlers>.from(address).handler.appeared("")
    }
}

let nameLost: GBusNameLostCallback = { _, _, data in
    let address = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        HandlerBox<NameHandlers>.from(address).handler.lost()
    }
}

/// `parameters` is transfer none; `invocation` is transfer full and is returned on exactly once
/// here, which consumes it.
let methodCalled: GDBusInterfaceMethodCallFunc = { _, sender, path, interface, method, parameters, invocation, data in
    let invocationAddress = UInt(bitPattern: UnsafeRawPointer(invocation!))
    let call: DBusMethodCall
    do {
        call = DBusMethodCall(sender: string(sender), path: string(path), interface: string(interface),
                              method: string(method),
                              arguments: try parameters.map { try GVariantCodec.readBody($0, expecting: nil) } ?? [])
    } catch {
        returnError(invocationAddress, "org.freedesktop.DBus.Error.InvalidArgs", String(describing: error))
        return
    }
    let address = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        let invocation = OpaquePointer(bitPattern: invocationAddress)!
        do {
            let values = try HandlerBox<MethodHandler>.from(address).handler(call)
            // GDBus would only warn about a reply that does not match the out arguments, and send
            // nothing; answer the caller with an error instead.
            let expected = outSignature(invocation)
            guard values.signature == expected else {
                returnError(invocationAddress, "org.freedesktop.DBus.Error.Failed",
                            "reply (\(values.signature)) does not match the out arguments (\(expected))")
                return
            }
            g_dbus_method_invocation_return_value(invocation, try GVariantCodec.makeBody(values))
        } catch DBusError.remote(let name, let message) where g_dbus_is_interface_name(name) != 0 {
            returnError(invocationAddress, name, message)
        } catch {
            returnError(invocationAddress, "org.freedesktop.DBus.Error.Failed", String(describing: error))
        }
    }
}

/// The concatenated out-argument signatures of the invoked method.
private func outSignature(_ invocation: OpaquePointer) -> String {
    guard let info = g_dbus_method_invocation_get_method_info(invocation),
          var argument = info.pointee.out_args else { return "" }
    var signature = ""
    while let arg = argument.pointee {
        signature += String(cString: arg.pointee.signature)
        argument += 1
    }
    return signature
}

private func returnError(_ invocationAddress: UInt, _ name: String, _ message: String) {
    g_dbus_method_invocation_return_dbus_error(OpaquePointer(bitPattern: invocationAddress)!, name, message)
}
