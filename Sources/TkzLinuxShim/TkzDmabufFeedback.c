// The compositor's dmabuf-feedback `main_device`, read on GDK's own Wayland connection
// (WOR-314 S4).
//
// The Vulkan device that draws tkzmux must be the one the compositor composites on, or every
// frame crosses GPUs and offload turns off (WOR-301 S4: Hyprland on the AMD iGPU refuses every
// NVIDIA dma-buf). GDK reads the compositor's linux-dmabuf feedback itself but publishes only the
// format list (`gdk_display_get_dmabuf_formats`), not its `main_device`. So this file asks once,
// at startup, on GDK's `wl_display`, through a private event queue so GDK's own queue and
// dispatch are never touched:
//
//   wl_display.get_registry → zwp_linux_dmabuf_v1 (v4+) → get_default_feedback → main_device
//
// libwayland-client is never linked (linkage-policy.txt denies a direct NEEDED entry: GDK owns the
// connection). It is already in the process, loaded by libgtk-4, so every libwayland call and
// `wl_registry_interface` are looked up with dlsym, like `gdk_wayland_display_*` (a GTK built
// without the Wayland backend has none). The two protocol interfaces below are written out from
// linux-dmabuf-v1.xml; only the requests and events used here carry types.

#define G_LOG_DOMAIN "TkzLinuxShim"

#include "TkzLinuxShim.h"

#include <dlfcn.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#include <wayland-client-core.h>

// MARK: - linux-dmabuf-v1, the part used here

static const struct wl_interface tkz_dmabuf_feedback_interface;

// Argument types, shared by the messages below. NULL where the argument is not an object or
// new_id, or where the request is never sent (create_params, get_surface_feedback).
static const struct wl_interface *tkz_dmabuf_types[] = {
    NULL,                               // create_params: new_id zwp_linux_buffer_params_v1
    &tkz_dmabuf_feedback_interface,     // get_default_feedback: new_id
    &tkz_dmabuf_feedback_interface,     // get_surface_feedback: new_id
    NULL,                               //   … object wl_surface
    NULL, NULL, NULL,                   // plain arguments
};

static const struct wl_message tkz_dmabuf_requests[] = {
    {"destroy", "", tkz_dmabuf_types + 4},
    {"create_params", "n", tkz_dmabuf_types + 0},
    {"get_default_feedback", "4n", tkz_dmabuf_types + 1},
    {"get_surface_feedback", "4no", tkz_dmabuf_types + 2},
};

static const struct wl_message tkz_dmabuf_events[] = {
    {"format", "u", tkz_dmabuf_types + 4},
    {"modifier", "3uuu", tkz_dmabuf_types + 4},
};

static const struct wl_interface tkz_dmabuf_interface = {
    "zwp_linux_dmabuf_v1", 5, 4, tkz_dmabuf_requests, 2, tkz_dmabuf_events,
};

static const struct wl_message tkz_dmabuf_feedback_requests[] = {
    {"destroy", "", tkz_dmabuf_types + 4},
};

static const struct wl_message tkz_dmabuf_feedback_events[] = {
    {"done", "", tkz_dmabuf_types + 4},
    {"format_table", "hu", tkz_dmabuf_types + 4},
    {"main_device", "a", tkz_dmabuf_types + 4},
    {"tranche_done", "", tkz_dmabuf_types + 4},
    {"tranche_target_device", "a", tkz_dmabuf_types + 4},
    {"tranche_formats", "a", tkz_dmabuf_types + 4},
    {"tranche_flags", "u", tkz_dmabuf_types + 4},
};

static const struct wl_interface tkz_dmabuf_feedback_interface = {
    "zwp_linux_dmabuf_feedback_v1", 5, 1, tkz_dmabuf_feedback_requests, 7, tkz_dmabuf_feedback_events,
};

// Opcodes: wl_display.get_registry, wl_registry.bind, the two destroys, get_default_feedback.
enum {
    TKZ_WL_DISPLAY_GET_REGISTRY = 1,
    TKZ_WL_REGISTRY_BIND = 0,
    TKZ_DMABUF_DESTROY = 0,
    TKZ_DMABUF_GET_DEFAULT_FEEDBACK = 2,
    TKZ_FEEDBACK_DESTROY = 0,
};

/// The feedback version this asks for: the first with `get_default_feedback`.
#define TKZ_DMABUF_VERSION 4u
#define TKZ_WL_MARSHAL_FLAG_DESTROY (1 << 0)

// MARK: - libwayland-client and GDK, by name

typedef struct {
    struct wl_event_queue *(*display_create_queue)(struct wl_display *);
    void *(*proxy_create_wrapper)(void *);
    void (*proxy_wrapper_destroy)(void *);
    void (*proxy_set_queue)(struct wl_proxy *, struct wl_event_queue *);
    struct wl_proxy *(*proxy_marshal_flags)(struct wl_proxy *, uint32_t, const struct wl_interface *, uint32_t,
                                            uint32_t, ...);
    int (*proxy_add_listener)(struct wl_proxy *, void (**)(void), void *);
    uint32_t (*proxy_get_version)(struct wl_proxy *);
    void (*proxy_destroy)(struct wl_proxy *);
    int (*display_roundtrip_queue)(struct wl_display *, struct wl_event_queue *);
    void (*event_queue_destroy)(struct wl_event_queue *);
    const struct wl_interface *registry_interface;
} WaylandProcs;

#define TKZ_LOOKUP(field, name)                                                                              \
    do {                                                                                                     \
        *(void **)&procs->field = dlsym(RTLD_DEFAULT, name);                                                 \
        if (procs->field == NULL) return FALSE;                                                              \
    } while (0)

static gboolean wayland_procs(WaylandProcs *procs) {
    TKZ_LOOKUP(display_create_queue, "wl_display_create_queue");
    TKZ_LOOKUP(proxy_create_wrapper, "wl_proxy_create_wrapper");
    TKZ_LOOKUP(proxy_wrapper_destroy, "wl_proxy_wrapper_destroy");
    TKZ_LOOKUP(proxy_set_queue, "wl_proxy_set_queue");
    TKZ_LOOKUP(proxy_marshal_flags, "wl_proxy_marshal_flags");
    TKZ_LOOKUP(proxy_add_listener, "wl_proxy_add_listener");
    TKZ_LOOKUP(proxy_get_version, "wl_proxy_get_version");
    TKZ_LOOKUP(proxy_destroy, "wl_proxy_destroy");
    TKZ_LOOKUP(display_roundtrip_queue, "wl_display_roundtrip_queue");
    TKZ_LOOKUP(event_queue_destroy, "wl_event_queue_destroy");
    TKZ_LOOKUP(registry_interface, "wl_registry_interface");
    return TRUE;
}

/// GDK's `wl_display`, or NULL when `display` is not a Wayland display (or GDK has no Wayland
/// backend).
static struct wl_display *gdk_wl_display(GdkDisplay *display) {
    GType (*get_type)(void) = (GType (*)(void))dlsym(RTLD_DEFAULT, "gdk_wayland_display_get_type");
    struct wl_display *(*get_display)(GdkDisplay *) =
        (struct wl_display * (*)(GdkDisplay *)) dlsym(RTLD_DEFAULT, "gdk_wayland_display_get_wl_display");
    if (get_type == NULL || get_display == NULL || !G_TYPE_CHECK_INSTANCE_TYPE(display, get_type())) {
        return NULL;
    }
    return get_display(display);
}

// MARK: - Listeners

typedef struct {
    uint32_t dmabuf_name;
    uint32_t dmabuf_version;
    gboolean done;
    gboolean has_main_device;
    dev_t main_device;
} FeedbackState;

static void registry_global(void *data, void *registry, uint32_t name, const char *interface,
                            uint32_t version) {
    (void)registry;
    FeedbackState *state = data;
    if (strcmp(interface, tkz_dmabuf_interface.name) == 0) {
        state->dmabuf_name = name;
        state->dmabuf_version = version;
    }
}

static void registry_global_remove(void *data, void *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static void (*registry_listener[])(void) = {
    (void (*)(void))registry_global,
    (void (*)(void))registry_global_remove,
};

static void feedback_done(void *data, void *feedback) {
    (void)feedback;
    ((FeedbackState *)data)->done = TRUE;
}

static void feedback_format_table(void *data, void *feedback, int32_t fd, uint32_t size) {
    (void)data;
    (void)feedback;
    (void)size;
    close(fd);   // GDK has its own copy of the table; this one is not read
}

static void feedback_main_device(void *data, void *feedback, struct wl_array *device) {
    (void)feedback;
    FeedbackState *state = data;
    if (device->size == sizeof(dev_t)) {
        memcpy(&state->main_device, device->data, sizeof(dev_t));
        state->has_main_device = TRUE;
    }
}

static void feedback_ignore(void *data, void *feedback) {
    (void)data;
    (void)feedback;
}

static void feedback_ignore_array(void *data, void *feedback, struct wl_array *array) {
    (void)data;
    (void)feedback;
    (void)array;
}

static void feedback_ignore_flags(void *data, void *feedback, uint32_t flags) {
    (void)data;
    (void)feedback;
    (void)flags;
}

static void (*feedback_listener[])(void) = {
    (void (*)(void))feedback_done,
    (void (*)(void))feedback_format_table,
    (void (*)(void))feedback_main_device,
    (void (*)(void))feedback_ignore,          // tranche_done
    (void (*)(void))feedback_ignore_array,    // tranche_target_device
    (void (*)(void))feedback_ignore_array,    // tranche_formats
    (void (*)(void))feedback_ignore_flags,    // tranche_flags
};

static void dmabuf_ignore_format(void *data, void *dmabuf, uint32_t format) {
    (void)data;
    (void)dmabuf;
    (void)format;
}

static void dmabuf_ignore_modifier(void *data, void *dmabuf, uint32_t format, uint32_t high, uint32_t low) {
    (void)data;
    (void)dmabuf;
    (void)format;
    (void)high;
    (void)low;
}

static void (*dmabuf_listener[])(void) = {
    (void (*)(void))dmabuf_ignore_format,
    (void (*)(void))dmabuf_ignore_modifier,
};

// MARK: - The query

TkzMainDeviceResult tkz_dmabuf_main_device(GdkDisplay *display, guint64 *main_device) {
    struct wl_display *wl_display = gdk_wl_display(display);
    if (wl_display == NULL) {
        return TKZ_MAIN_DEVICE_NOT_WAYLAND;
    }
    WaylandProcs procs;
    if (!wayland_procs(&procs)) {
        return TKZ_MAIN_DEVICE_NO_LIBWAYLAND;
    }

    struct wl_event_queue *queue = procs.display_create_queue(wl_display);
    struct wl_proxy *wrapper = procs.proxy_create_wrapper(wl_display);
    if (queue == NULL || wrapper == NULL) {
        if (wrapper != NULL) procs.proxy_wrapper_destroy(wrapper);
        if (queue != NULL) procs.event_queue_destroy(queue);
        return TKZ_MAIN_DEVICE_NO_LIBWAYLAND;
    }
    procs.proxy_set_queue(wrapper, queue);

    FeedbackState state = {0};
    struct wl_proxy *registry = procs.proxy_marshal_flags(
        wrapper, TKZ_WL_DISPLAY_GET_REGISTRY, procs.registry_interface, procs.proxy_get_version(wrapper), 0, NULL);
    // The registry inherits the wrapper's queue; the wrapper itself is no longer needed.
    procs.proxy_wrapper_destroy(wrapper);

    TkzMainDeviceResult result = TKZ_MAIN_DEVICE_NO_DMABUF;
    if (registry != NULL) {
        procs.proxy_add_listener(registry, registry_listener, &state);
        procs.display_roundtrip_queue(wl_display, queue);
    }
    if (registry != NULL && state.dmabuf_name != 0 && state.dmabuf_version >= TKZ_DMABUF_VERSION) {
        struct wl_proxy *dmabuf = procs.proxy_marshal_flags(
            registry, TKZ_WL_REGISTRY_BIND, &tkz_dmabuf_interface, TKZ_DMABUF_VERSION, 0, state.dmabuf_name,
            tkz_dmabuf_interface.name, TKZ_DMABUF_VERSION, NULL);
        struct wl_proxy *feedback = NULL;
        if (dmabuf != NULL) {
            procs.proxy_add_listener(dmabuf, dmabuf_listener, &state);
            feedback = procs.proxy_marshal_flags(dmabuf, TKZ_DMABUF_GET_DEFAULT_FEEDBACK,
                                                 &tkz_dmabuf_feedback_interface, TKZ_DMABUF_VERSION, 0, NULL);
        }
        if (feedback != NULL) {
            procs.proxy_add_listener(feedback, feedback_listener, &state);
            // The compositor sends the whole feedback at once, ending with `done`; a few
            // roundtrips bound the wait if it does not.
            for (int i = 0; i < 4 && !state.done; i++) {
                if (procs.display_roundtrip_queue(wl_display, queue) < 0) break;
            }
            procs.proxy_marshal_flags(feedback, TKZ_FEEDBACK_DESTROY, NULL, TKZ_DMABUF_VERSION,
                                      TKZ_WL_MARSHAL_FLAG_DESTROY);
            result = state.has_main_device ? TKZ_MAIN_DEVICE_FOUND : TKZ_MAIN_DEVICE_NO_FEEDBACK;
        }
        if (dmabuf != NULL) {
            procs.proxy_marshal_flags(dmabuf, TKZ_DMABUF_DESTROY, NULL, TKZ_DMABUF_VERSION,
                                      TKZ_WL_MARSHAL_FLAG_DESTROY);
        }
    }
    if (registry != NULL) {
        procs.proxy_destroy(registry);
    }
    procs.event_queue_destroy(queue);

    if (result == TKZ_MAIN_DEVICE_FOUND) {
        *main_device = (guint64)state.main_device;
    }
    return result;
}
