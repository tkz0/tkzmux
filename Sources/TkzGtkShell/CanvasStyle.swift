// CanvasStyle — the CSS that keeps GTK out of a canvas window's pixels (WOR-314 S4).
//
// GTK draws a widget's CSS background, border, outline and shadow before its snapshot vfunc, and
// the theme gives windows a background colour, rounded corners and shadows. Any of those around
// or under the TkzCanvas would either show (GTK drawing a visible pixel, against ADR-0001) or
// stop GtkGraphicsOffload from offloading (a clipped, rounded or translucent texture is
// composited by GSK instead, silently, every frame). One application-priority provider per
// display zeroes all of it for windows carrying `tkzmux-canvas`:
//
//   - the window: black and square, so it stays opaque (GTK then sets an opaque region, and the
//     compositor never blends under it) and nothing of the theme shows during a resize;
//   - the GtkGraphicsOffload and the TkzCanvas: no background, border, radius, shadow, outline,
//     margin or padding, so the canvas fills the window at (0, 0) and its texture is the only
//     node.

import CGtk
import TkzLinuxShim

@MainActor
enum CanvasStyle {
    /// The CSS class `GtkCanvasHost` puts on its window.
    static let windowClass = "tkzmux-canvas"

    static let css = """
        window.\(windowClass) {
          background-color: black; background-image: none;
          border: none; border-radius: 0; box-shadow: none; outline: none; margin: 0; padding: 0;
        }
        window.\(windowClass) graphicsoffload, window.\(windowClass) tkzcanvas {
          background-color: transparent; background-image: none;
          border: none; border-radius: 0; box-shadow: none; outline: none; margin: 0; padding: 0;
        }
        """

    private static var displays: Set<UInt> = []

    /// Adds the provider to `display` (a `GdkDisplay *`), once.
    static func install(on display: OpaquePointer) {
        guard displays.insert(UInt(bitPattern: UnsafeRawPointer(display))).inserted else { return }
        let provider = gtk_css_provider_new()!
        defer { g_object_unref(UnsafeMutableRawPointer(provider)) }
        gtk_css_provider_load_from_string(provider, css)
        // The display keeps its own reference for as long as it lives.
        gtk_style_context_add_provider_for_display(display, tkz_style_provider(UnsafeMutableRawPointer(provider)),
                                                   UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}
