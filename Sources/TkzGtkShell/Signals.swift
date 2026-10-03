// Signals — GObject signal handlers as Swift closures (WOR-314 S1).
//
// Each connection retains a box holding the closure and hands it to GLib as the handler's data
// through `tkz_signal_connect`. The box is released by the destroy-notify and only there: GLib
// calls it once, when the handler is disconnected or the instance is finalized (or at once, if the
// connection fails). Nothing in Swift keeps or releases the box, so a closure can never outlive
// its connection or be freed while GLib can still call it.
//
// Signals are emitted on the GTK thread, which is the main actor's thread under the main-queue
// GSource, so the C trampolines enter the handlers with `MainActor.assumeIsolated` (a trap, not a
// race, if a signal ever arrives on another thread).
//
// `liveBoxes` counts the boxes that exist (ClosureBoxes): the open/close-cycle checks (S2) show
// it back at its baseline.

import CGtk
import TkzLinuxShim

/// A connected handler's id, as `g_signal_connect_data` returns it; 0 when the connection failed.
public typealias SignalHandlerID = gulong

@MainActor
public enum Signals {
    /// The number of signal closure boxes alive in the process, across every connection.
    public nonisolated static var liveBoxes: Int { ClosureBoxes.live(.signal) }

    /// Connects `handler` to a signal whose C handler is `void (*)(instance, user_data)`, such as
    /// GApplication `activate` or GtkWidget `realize`.
    @discardableResult
    public static func connect(
        _ instance: some GObjectPointer, _ signal: String,
        _ handler: @escaping @MainActor () -> Void
    ) -> SignalHandlerID {
        connect(instance, signal, .plain(handler), unsafeBitCast(plainTrampoline, to: GCallback.self))
    }

    /// Connects `handler` to a signal with one pointer argument,
    /// `void (*)(instance, arg, user_data)`, such as `notify::<property>` (a GParamSpec).
    @discardableResult
    public static func connect(
        _ instance: some GObjectPointer, _ signal: String,
        withArgument handler: @escaping @MainActor (UnsafeMutableRawPointer?) -> Void
    ) -> SignalHandlerID {
        connect(instance, signal, .argument(handler), unsafeBitCast(argumentTrampoline, to: GCallback.self))
    }

    /// Connects `handler` to a signal whose C handler is `gboolean (*)(instance, user_data)`, such
    /// as GtkWindow `close-request` (true stops the default handler).
    @discardableResult
    public static func connect(
        _ instance: some GObjectPointer, _ signal: String,
        returning handler: @escaping @MainActor () -> Bool
    ) -> SignalHandlerID {
        connect(instance, signal, .boolean(handler), unsafeBitCast(booleanTrampoline, to: GCallback.self))
    }

    /// Disconnects a handler; GLib then calls the destroy-notify, which releases its box.
    public static func disconnect(_ instance: some GObjectPointer, _ id: SignalHandlerID) {
        g_signal_handler_disconnect(instance.gpointer, id)
    }

    private static func connect(
        _ instance: some GObjectPointer, _ signal: String, _ handler: SignalBox.Handler,
        _ callback: GCallback
    ) -> SignalHandlerID {
        let box = Unmanaged.passRetained(SignalBox(handler)).toOpaque()
        return tkz_signal_connect(instance.gpointer, signal, callback, box, releaseBox)
    }
}

/// One connection's closure. Retained once at connect time; released by `releaseBox` only.
final class SignalBox {
    enum Handler {
        case plain(@MainActor () -> Void)
        case argument(@MainActor (UnsafeMutableRawPointer?) -> Void)
        case boolean(@MainActor () -> Bool)
    }

    let handler: Handler

    init(_ handler: Handler) {
        self.handler = handler
        ClosureBoxes.created(.signal)
    }

    deinit {
        ClosureBoxes.destroyed(.signal)
    }

    static func from(_ data: UnsafeMutableRawPointer?) -> SignalBox {
        Unmanaged<SignalBox>.fromOpaque(data!).takeUnretainedValue()
    }
}

// The trampolines GLib calls. The box pointer crosses into the main-actor closure as an address,
// which is Sendable, and becomes the box again on the other side.

private let plainTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = {
    _, data in
    let address = UInt(bitPattern: data)
    MainActor.assumeIsolated {
        if case .plain(let handler) = SignalBox.from(UnsafeMutableRawPointer(bitPattern: address)).handler {
            handler()
        }
    }
}

private let argumentTrampoline: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { _, argument, data in
    let address = UInt(bitPattern: data)
    let argumentAddress = UInt(bitPattern: argument)
    MainActor.assumeIsolated {
        if case .argument(let handler) = SignalBox.from(UnsafeMutableRawPointer(bitPattern: address)).handler {
            handler(UnsafeMutableRawPointer(bitPattern: argumentAddress))
        }
    }
}

private let booleanTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = {
    _, data in
    let address = UInt(bitPattern: data)
    return MainActor.assumeIsolated {
        if case .boolean(let handler) = SignalBox.from(UnsafeMutableRawPointer(bitPattern: address)).handler {
            return handler() ? 1 : 0
        }
        return 0
    }
}

/// The destroy-notify: the box's only release. GLib may call it from whichever thread drops the
/// instance's last reference, which is why the box itself is not main-actor isolated.
private let releaseBox: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = {
    data, _ in
    Unmanaged<SignalBox>.fromOpaque(data!).release()
}
