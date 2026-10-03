// DBusError — every failure the GDBus wrapper reports, GErrors included (WOR-320 S1).
//
// A GError never crosses into Swift as a pointer: `init(consuming:)` reads it, frees it and
// classifies it. A reply the peer sent as a D-Bus error is `.remote` with the error's D-Bus name
// (GDBus keeps it in the message as `GDBus.Error:<name>: `, which is stripped here), whichever
// GError domain GDBus mapped it to. Local failures keep their GIO meaning: cancelled, timed out,
// closed, or `.failure` with the GError's domain and code.

import CGtk

public enum DBusError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The peer (or the bus) answered with a D-Bus error, such as
    /// `org.freedesktop.DBus.Error.ServiceUnknown`.
    case remote(name: String, message: String)
    /// No reply within the call's timeout (`G_IO_ERROR_TIMED_OUT`).
    case timedOut
    /// The operation was cancelled (`G_IO_ERROR_CANCELLED`).
    case cancelled
    /// The connection is closed (`G_IO_ERROR_CLOSED`).
    case closed
    /// Any other GError, by domain name and code.
    case failure(domain: String, code: Int32, message: String)
    /// A reply or signal whose GVariant type is not the one the caller asked for; nothing was
    /// unpacked.
    case typeMismatch(expected: String, actual: String)
    /// A value of a type this wrapper does not marshal (`h`, `m`; see DBusType).
    case unsupportedType(String)
    /// A malformed type signature, or a `DBusType` outside the D-Bus grammar or limits.
    case invalidSignature(String)
    /// A value that cannot be sent: a string with a NUL, a malformed object path or signature, an
    /// array element of the wrong type. Checked before anything reaches GLib.
    case invalidValue(String)
    /// A bus name, object path, interface or member name GDBus would reject.
    case invalidName(String)

    public var description: String {
        switch self {
        case .remote(let name, let message): "\(name): \(message)"
        case .timedOut: "timed out"
        case .cancelled: "cancelled"
        case .closed: "connection closed"
        case .failure(let domain, let code, let message): "\(domain) \(code): \(message)"
        case .typeMismatch(let expected, let actual): "expected type \(expected), got \(actual)"
        case .unsupportedType(let type): "unsupported type \(type)"
        case .invalidSignature(let signature): "invalid signature \(signature)"
        case .invalidValue(let reason): "invalid value: \(reason)"
        case .invalidName(let name): "invalid D-Bus name \(name)"
        }
    }

    /// The error `error` describes, which is freed.
    init(consuming error: UnsafeMutablePointer<GError>) {
        defer { g_error_free(error) }
        if g_dbus_error_is_remote_error(error) != 0, let name = g_dbus_error_get_remote_error(error) {
            defer { g_free(name) }
            _ = g_dbus_error_strip_remote_error(error)
            self = .remote(name: String(cString: name), message: Self.message(error))
            return
        }
        if error.pointee.domain == g_io_error_quark() {
            switch GIOErrorEnum(rawValue: UInt32(bitPattern: error.pointee.code)) {
            case G_IO_ERROR_TIMED_OUT: self = .timedOut; return
            case G_IO_ERROR_CANCELLED: self = .cancelled; return
            case G_IO_ERROR_CLOSED: self = .closed; return
            default: break
            }
        }
        let domain = g_quark_to_string(error.pointee.domain).map { String(cString: $0) } ?? "unknown"
        self = .failure(domain: domain, code: error.pointee.code, message: Self.message(error))
    }

    private static func message(_ error: UnsafeMutablePointer<GError>) -> String {
        error.pointee.message.map { String(cString: $0) } ?? ""
    }
}
