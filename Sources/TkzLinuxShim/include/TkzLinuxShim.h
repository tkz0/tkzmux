// TkzLinuxShim — the C half of the GTK platform shell (WOR-314). GTK only: TkzPlatformShim
// (libc) and CVulkan stay separate, and nothing below TkzGtkShell includes this header.
//
//   - the libdispatch main-queue GSource that lets GTK own the main thread (S1);
//   - type-checked cast wrappers and the macros Swift cannot import (S1);
//   - `tkz_signal_connect`, a `g_signal_connect_data` whose destroy-notify is the only release of
//     the Swift closure box (S1);
//   - `tkz_gtk_symbol`, the runtime gate for every API newer than 4.16 (S1, ADR-0002 D4);
//   - `TkzCanvas`, the one GtkWidget subclass, whose vfuncs forward to a C vtable (S2);
//   - the compositor's dmabuf-feedback `main_device`, read on GDK's Wayland connection (S4).
//
// Every function here is called on the GTK (process main) thread unless it says otherwise.
#pragma once

#include "../../CGtk/CGtk.h"

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - libdispatch main queue

/// Attaches the main-queue source to `context` (NULL for the default context) at
/// G_PRIORITY_DEFAULT, once per process; later calls return the same id. Call it on the thread
/// that owns `context` and will iterate it, which must be the process main thread: libdispatch
/// binds its main queue to that thread, and every `DispatchQueue.main` block, `@MainActor` job and
/// main-queue `DispatchSource` then runs there, from GLib.
///
/// The source polls the eventfd that `_dispatch_get_main_queue_handle_4CF` returns. On dispatch it
/// first reads the eventfd, because `_dispatch_main_queue_callback_4CF` does not reset it and GLib
/// would otherwise spin (WOR-300 S2, docs/linux/spikes.md), then drains the queue. Never iterate a
/// nested main loop from a main-queue block: the drain is not re-entrant.
guint tkz_main_queue_source_attach(GMainContext *context);

/// How many times the main-queue source has dispatched since the process started. A diagnostic:
/// it stays put while nothing is posted, and grows by about one per burst of posts, never by
/// thousands per second (the spin the eventfd read prevents).
guint64 tkz_main_queue_source_dispatch_count(void);

// MARK: - Signals

/// `g_signal_connect_data(instance, signal, callback, box, destroy, 0)`. `destroy(box, NULL)` runs
/// exactly once: when the handler is disconnected, when `instance` is finalized, or right away
/// if the connection would fail (an unknown signal, or a detail on a signal that takes none), in
/// which case this logs a critical in the `TkzLinuxShim` domain, never calls GLib, and returns 0.
/// The Swift side therefore releases its box in `destroy` and nowhere else.
gulong tkz_signal_connect(gpointer instance, const char *signal, GCallback callback, gpointer box,
                          GClosureNotify destroy);

// MARK: - APIs newer than 4.16

/// The runtime GTK minor version (`gtk_get_minor_version()`), or the value forced by
/// `tkz_gtk_force_minor_version`.
unsigned tkz_gtk_minor_version(void);

/// The address of `name`, a GTK function introduced in 4.`minor`, or NULL when the running GTK
/// is older than 4.`minor` or does not export it. Looked up with `dlsym(RTLD_DEFAULT, …)` and
/// cached per name, the NULL result included. Every API above the 4.16 floor goes through here;
/// a direct reference would stop the binary loading on 4.16 (ADR-0002 D4). Any thread.
void *tkz_gtk_symbol(const char *name, unsigned minor);

/// Tests only: pretends the running GTK is 4.`minor` (a negative value restores the real version)
/// and empties the `tkz_gtk_symbol` cache, so the missing-symbol path can be tested on a newer
/// GTK.
void tkz_gtk_force_minor_version(int minor);

// MARK: - TkzCanvas

// The GtkWidget every tkzmux pixel goes through (ADR-0001: GTK never draws a visible pixel of its
// own). A plain G_DEFINE_TYPE subclass of GtkWidget with CSS name `tkzcanvas` and no children. Its
// vfuncs do nothing themselves: each forwards to the matching entry of the vtable it was created
// with, passing the `ctx` it was created with, and a NULL entry (or a released context) falls back
// to GtkWidget's own behaviour.
typedef struct _TkzCanvas TkzCanvas;

/// What a forwarded vfunc with a fallback answers: the parent's behaviour, false or true.
#define TKZ_CANVAS_DEFAULT (-1)

typedef struct {
    /// `GtkWidgetClass.snapshot`: append the frame to `snapshot`.
    void (*snapshot)(gpointer ctx, GtkWidget *canvas, GtkSnapshot *snapshot);
    /// `GtkWidgetClass.measure`: set `*minimum` and `*natural` (both already 0) and return TRUE,
    /// or return FALSE for GtkWidget's measurement. Baselines are always -1.
    gboolean (*measure)(gpointer ctx, GtkWidget *canvas, GtkOrientation orientation, int for_size,
                        int *minimum, int *natural);
    /// `GtkWidgetClass.size_allocate`, after the parent's.
    void (*size_allocate)(gpointer ctx, GtkWidget *canvas, int width, int height, int baseline);
    /// `GtkWidgetClass.realize`, after the parent's: the widget has its native and surface.
    void (*realize)(gpointer ctx, GtkWidget *canvas);
    /// `GtkWidgetClass.unrealize`, before the parent's: the surface is still there.
    void (*unrealize)(gpointer ctx, GtkWidget *canvas);
    /// `GtkWidgetClass.focus`: TRUE, FALSE, or TKZ_CANVAS_DEFAULT for GtkWidget's keyboard
    /// navigation.
    int (*focus)(gpointer ctx, GtkWidget *canvas, GtkDirectionType direction);
    /// The accessibility slot (WOR-325): `GtkAccessibleInterface.get_first_accessible_child`,
    /// transfer full. NULL falls back to GtkWidget's (a canvas has no child widgets, so none).
    GtkAccessible *(*first_accessible_child)(gpointer ctx, GtkWidget *canvas);
    /// Releases `ctx`. Called exactly once, when the widget is disposed (after the parent's
    /// dispose, so an unrealize during it still reaches `ctx`); no entry is called after it.
    void (*destroy)(gpointer ctx);
} TkzCanvasVTable;

GType tkz_canvas_get_type(void);

/// A new canvas, floating like every fresh GtkWidget. `vtable` is copied; `ctx` is owned by the
/// canvas from here on and released through `vtable->destroy`.
GtkWidget *tkz_canvas_new(const TkzCanvasVTable *vtable, gpointer ctx);

/// The `ctx` a canvas was created with, or NULL once it has been released.
gpointer tkz_canvas_get_context(GtkWidget *canvas);

/// How many TkzCanvas instances exist (created and not yet finalized). A diagnostic for the
/// open/close-cycle checks (S2); any thread.
guint tkz_canvas_live_count(void);

static inline gboolean tkz_is_canvas(gpointer p) { return G_TYPE_CHECK_INSTANCE_TYPE(p, tkz_canvas_get_type()); }

// MARK: - The compositor's main device

typedef enum {
    /// `*main_device` is the compositor's dmabuf-feedback `main_device`.
    TKZ_MAIN_DEVICE_FOUND = 0,
    /// The display is not a Wayland display (or GDK was built without the Wayland backend).
    TKZ_MAIN_DEVICE_NOT_WAYLAND,
    /// libwayland-client's functions are not in the process, or a queue could not be made.
    TKZ_MAIN_DEVICE_NO_LIBWAYLAND,
    /// The compositor offers no zwp_linux_dmabuf_v1 of version 4 or later (no feedback).
    TKZ_MAIN_DEVICE_NO_DMABUF,
    /// The default feedback arrived without a `main_device`.
    TKZ_MAIN_DEVICE_NO_FEEDBACK,
} TkzMainDeviceResult;

/// The compositor's dmabuf-feedback `main_device` (a `dev_t`) for `display`: the DRM device it
/// composites on, which the Vulkan device must match (WOR-313 `DeviceSelector`). Binds
/// zwp_linux_dmabuf_v1 v4 on GDK's own `wl_display` through a private event queue, reads the
/// default feedback, and destroys everything again; GDK's queue is never dispatched. libwayland is
/// reached through dlsym only (it is in the process through libgtk-4, never linked). Blocks for a
/// few roundtrips; call it once, on the GTK thread, outside any GDK event dispatch.
TkzMainDeviceResult tkz_dmabuf_main_device(GdkDisplay *display, guint64 *main_device);

// MARK: - Casts and macros

// The G_TYPE_CHECK_INSTANCE_CAST macros (GTK_WIDGET(), G_OBJECT(), …) do not import into Swift.
// These are the same checked casts: a wrong type logs a GLib critical and returns the pointer.

static inline GObject *tkz_object(gpointer p) { return G_OBJECT(p); }
static inline GApplication *tkz_application(gpointer p) { return G_APPLICATION(p); }
static inline GtkApplication *tkz_gtk_application(gpointer p) { return GTK_APPLICATION(p); }
static inline GtkWidget *tkz_widget(gpointer p) { return GTK_WIDGET(p); }
static inline GtkWindow *tkz_window(gpointer p) { return GTK_WINDOW(p); }
static inline GtkNative *tkz_native(gpointer p) { return GTK_NATIVE(p); }
static inline GtkGraphicsOffload *tkz_graphics_offload(gpointer p) { return GTK_GRAPHICS_OFFLOAD(p); }
static inline GdkSurface *tkz_surface(gpointer p) { return GDK_SURFACE(p); }
static inline GdkToplevel *tkz_toplevel(gpointer p) { return GDK_TOPLEVEL(p); }
static inline GdkPaintable *tkz_paintable(gpointer p) { return GDK_PAINTABLE(p); }
static inline GdkTexture *tkz_texture(gpointer p) { return GDK_TEXTURE(p); }
static inline GtkAccessible *tkz_accessible(gpointer p) { return GTK_ACCESSIBLE(p); }
static inline GtkStyleProvider *tkz_style_provider(gpointer p) { return GTK_STYLE_PROVIDER(p); }
static inline GdkFrameClock *tkz_frame_clock(gpointer p) { return GDK_FRAME_CLOCK(p); }

/// `G_IS_OBJECT(p)`: whether `p` points at a live GObject instance (a debugging aid; a freed
/// instance can still pass).
static inline gboolean tkz_is_object(gpointer p) { return G_IS_OBJECT(p); }

/// `G_OBJECT(p)->ref_count`, read atomically. Tests and diagnostics only.
static inline guint tkz_object_ref_count(gpointer p) { return g_atomic_int_get(&G_OBJECT(p)->ref_count); }

/// `G_SOURCE_CONTINUE` and `G_SOURCE_REMOVE` (defined as `TRUE`/`FALSE`, which do not import).
static inline gboolean tkz_source_continue(void) { return G_SOURCE_CONTINUE; }
static inline gboolean tkz_source_remove(void) { return G_SOURCE_REMOVE; }

/// `G_APPLICATION_NON_UNIQUE`, whose availability-annotated enumerator does not import (WOR-300 S2).
static inline GApplicationFlags tkz_application_non_unique(void) { return G_APPLICATION_NON_UNIQUE; }

#ifdef __cplusplus
}
#endif
