// GtkRuntime — the GTK the process is running against, and the gate for newer APIs (ADR-0002 D4).
//
// The floor is 4.16. Anything newer is looked up by name at run time through `symbol(_:minor:as:)`
// and called through the returned pointer when it exists; the caller always has a 4.16 fallback.
// `GTK_CHECK_VERSION` cannot replace this: it describes the headers used for the build.

import CGtk
import TkzLinuxShim

public enum GtkRuntime {
    /// The running GTK's minor version (4.`minor`).
    public static var minorVersion: UInt32 { tkz_gtk_minor_version() }

    /// The function `name`, introduced in 4.`minor`, cast to its C type, or nil when this GTK is
    /// older or does not export it. Cached per name in TkzLinuxShim.
    ///
    ///     typealias GetCapabilities = @convention(c) (OpaquePointer?) -> UInt32   // GdkToplevel *
    ///     if let get = GtkRuntime.symbol("gdk_toplevel_get_capabilities", minor: 20, as: GetCapabilities.self) { … }
    public static func symbol<Function>(_ name: String, minor: UInt32, as type: Function.Type) -> Function? {
        guard let address = tkz_gtk_symbol(name, minor) else { return nil }
        return unsafeBitCast(address, to: type)
    }
}
