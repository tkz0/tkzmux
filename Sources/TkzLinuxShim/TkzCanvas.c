// TkzCanvas — the GtkWidget subclass behind every tkzmux surface (WOR-314 S2).
//
// The C half only routes: each vfunc below forwards to the vtable the canvas was created with
// (TkzGtkShell's CanvasWidget fills it with Swift trampolines) and falls back to GtkWidget's own
// behaviour for a NULL entry or once the context is gone. Nothing here draws.

// Before any GLib header: the domain of this file's own criticals.
#define G_LOG_DOMAIN "TkzLinuxShim"

#include "TkzLinuxShim.h"

#include <stdatomic.h>

struct _TkzCanvas {
    GtkWidget parent_instance;
    TkzCanvasVTable vtable;   // zeroed when the context is released
    gpointer ctx;
};

typedef struct {
    GtkWidgetClass parent_class;
} TkzCanvasClass;

static void tkz_canvas_accessible_init(GtkAccessibleInterface *iface);

G_DEFINE_TYPE_WITH_CODE(TkzCanvas, tkz_canvas, GTK_TYPE_WIDGET,
                        G_IMPLEMENT_INTERFACE(GTK_TYPE_ACCESSIBLE, tkz_canvas_accessible_init))

#define TKZ_CANVAS(p) (G_TYPE_CHECK_INSTANCE_CAST((p), tkz_canvas_get_type(), TkzCanvas))

static _Atomic guint live_canvases;
static GtkAccessibleInterface *parent_accessible_iface;

/// Runs `destroy(ctx)` once and forgets both, so every later vfunc takes its fallback.
static void tkz_canvas_release_context(TkzCanvas *self) {
    void (*destroy)(gpointer) = self->vtable.destroy;
    gpointer ctx = self->ctx;
    self->vtable = (TkzCanvasVTable){0};
    self->ctx = NULL;
    if (destroy != NULL) {
        destroy(ctx);
    }
}

// MARK: - GObject

static void tkz_canvas_dispose(GObject *object) {
    TkzCanvas *self = TKZ_CANVAS(object);
    // The parent first: if it unrealizes the widget, that still reaches ctx. Dispose may run more
    // than once; the release happens on the first run only.
    G_OBJECT_CLASS(tkz_canvas_parent_class)->dispose(object);
    tkz_canvas_release_context(self);
}

static void tkz_canvas_finalize(GObject *object) {
    atomic_fetch_sub_explicit(&live_canvases, 1, memory_order_relaxed);
    G_OBJECT_CLASS(tkz_canvas_parent_class)->finalize(object);
}

// MARK: - GtkWidget

static void tkz_canvas_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    TkzCanvas *self = TKZ_CANVAS(widget);
    if (self->vtable.snapshot != NULL) {
        self->vtable.snapshot(self->ctx, widget, snapshot);
    } else {
        GTK_WIDGET_CLASS(tkz_canvas_parent_class)->snapshot(widget, snapshot);
    }
}

static void tkz_canvas_measure(GtkWidget *widget, GtkOrientation orientation, int for_size, int *minimum,
                               int *natural, int *minimum_baseline, int *natural_baseline) {
    TkzCanvas *self = TKZ_CANVAS(widget);
    int min = 0, nat = 0;
    if (self->vtable.measure != NULL && self->vtable.measure(self->ctx, widget, orientation, for_size, &min, &nat)) {
        *minimum = min;
        *natural = nat;
        *minimum_baseline = -1;
        *natural_baseline = -1;
        return;
    }
    GTK_WIDGET_CLASS(tkz_canvas_parent_class)
        ->measure(widget, orientation, for_size, minimum, natural, minimum_baseline, natural_baseline);
}

static void tkz_canvas_size_allocate(GtkWidget *widget, int width, int height, int baseline) {
    TkzCanvas *self = TKZ_CANVAS(widget);
    GTK_WIDGET_CLASS(tkz_canvas_parent_class)->size_allocate(widget, width, height, baseline);
    if (self->vtable.size_allocate != NULL) {
        self->vtable.size_allocate(self->ctx, widget, width, height, baseline);
    }
}

static void tkz_canvas_realize(GtkWidget *widget) {
    TkzCanvas *self = TKZ_CANVAS(widget);
    GTK_WIDGET_CLASS(tkz_canvas_parent_class)->realize(widget);
    if (self->vtable.realize != NULL) {
        self->vtable.realize(self->ctx, widget);
    }
}

static void tkz_canvas_unrealize(GtkWidget *widget) {
    TkzCanvas *self = TKZ_CANVAS(widget);
    if (self->vtable.unrealize != NULL) {
        self->vtable.unrealize(self->ctx, widget);
    }
    GTK_WIDGET_CLASS(tkz_canvas_parent_class)->unrealize(widget);
}

static gboolean tkz_canvas_focus(GtkWidget *widget, GtkDirectionType direction) {
    TkzCanvas *self = TKZ_CANVAS(widget);
    if (self->vtable.focus != NULL) {
        int answer = self->vtable.focus(self->ctx, widget, direction);
        if (answer != TKZ_CANVAS_DEFAULT) {
            return answer != 0;
        }
    }
    return GTK_WIDGET_CLASS(tkz_canvas_parent_class)->focus(widget, direction);
}

// MARK: - GtkAccessible (the WOR-325 slot)

static GtkAccessible *tkz_canvas_get_first_accessible_child(GtkAccessible *accessible) {
    TkzCanvas *self = TKZ_CANVAS(accessible);
    if (self->vtable.first_accessible_child != NULL) {
        return self->vtable.first_accessible_child(self->ctx, GTK_WIDGET(accessible));
    }
    return parent_accessible_iface->get_first_accessible_child(accessible);
}

static void tkz_canvas_accessible_init(GtkAccessibleInterface *iface) {
    // Every other entry stays GtkWidget's: the interface is copied from the parent's.
    parent_accessible_iface = g_type_interface_peek_parent(iface);
    iface->get_first_accessible_child = tkz_canvas_get_first_accessible_child;
}

// MARK: - Type

static void tkz_canvas_class_init(TkzCanvasClass *klass) {
    GObjectClass *object_class = G_OBJECT_CLASS(klass);
    object_class->dispose = tkz_canvas_dispose;
    object_class->finalize = tkz_canvas_finalize;

    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS(klass);
    widget_class->snapshot = tkz_canvas_snapshot;
    widget_class->measure = tkz_canvas_measure;
    widget_class->size_allocate = tkz_canvas_size_allocate;
    widget_class->realize = tkz_canvas_realize;
    widget_class->unrealize = tkz_canvas_unrealize;
    widget_class->focus = tkz_canvas_focus;
    gtk_widget_class_set_css_name(widget_class, "tkzcanvas");
}

static void tkz_canvas_init(TkzCanvas *self) {
    (void)self;
    atomic_fetch_add_explicit(&live_canvases, 1, memory_order_relaxed);
}

GtkWidget *tkz_canvas_new(const TkzCanvasVTable *vtable, gpointer ctx) {
    TkzCanvas *self = g_object_new(tkz_canvas_get_type(), NULL);
    self->vtable = *vtable;
    self->ctx = ctx;
    return GTK_WIDGET(self);
}

gpointer tkz_canvas_get_context(GtkWidget *canvas) {
    g_return_val_if_fail(tkz_is_canvas(canvas), NULL);
    return TKZ_CANVAS(canvas)->ctx;
}

guint tkz_canvas_live_count(void) {
    return atomic_load_explicit(&live_canvases, memory_order_relaxed);
}
