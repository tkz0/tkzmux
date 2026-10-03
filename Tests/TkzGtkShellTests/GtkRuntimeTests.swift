// GtkRuntimeTests — WOR-314 S1, ADR-0002 D4. APIs above the 4.16 floor are reached only through
// `tkz_gtk_symbol`, which answers nil when the running GTK is older than the API or does not
// export it; forcing 4.16 exercises that path on a newer GTK. `gtk_get_minor_version` needs no
// display or `gtk_init`.
import CGtk
import Testing
import TkzGtkShell
import TkzLinuxShim

/// `gdk_toplevel_get_capabilities` (4.20), the first user (WOR-314 S6).
typealias GetCapabilities = @convention(c) (OpaquePointer?) -> UInt32

@Suite(.serialized)
struct GtkRuntimeTests {
    @Test func theRunningGtkMeetsTheFloor() {
        #expect(gtk_get_major_version() == 4)
        #expect(GtkRuntime.minorVersion >= 16)
        #expect(GtkRuntime.minorVersion == gtk_get_minor_version())
    }

    @Test func aFloorApiResolves() {
        typealias MinorVersion = @convention(c) () -> UInt32
        let resolved = GtkRuntime.symbol("gtk_get_minor_version", minor: 0, as: MinorVersion.self)
        #expect(resolved?() == gtk_get_minor_version())
    }

    @Test func anUnknownNameIsNil() {
        #expect(tkz_gtk_symbol("gtk_tkzmux_no_such_function", 0) == nil)
        // The cached miss answers the same.
        #expect(tkz_gtk_symbol("gtk_tkzmux_no_such_function", 0) == nil)
    }

    @Test func anApiNewerThanTheRunningGtkIsNil() {
        #expect(tkz_gtk_symbol("gtk_get_minor_version", gtk_get_minor_version() + 1) == nil)
    }

    /// The 4.16 missing-symbol path: the function exists in this GTK, but a 4.16 host must not
    /// see it.
    @Test func forcing416HidesA420Api() {
        defer { tkz_gtk_force_minor_version(-1) }
        tkz_gtk_force_minor_version(16)
        #expect(GtkRuntime.minorVersion == 16)
        #expect(GtkRuntime.symbol("gdk_toplevel_get_capabilities", minor: 20, as: GetCapabilities.self) == nil)

        tkz_gtk_force_minor_version(-1)
        #expect(GtkRuntime.minorVersion == gtk_get_minor_version())
        let real = GtkRuntime.symbol("gdk_toplevel_get_capabilities", minor: 20, as: GetCapabilities.self)
        #expect((real != nil) == (gtk_get_minor_version() >= 20))
    }
}
