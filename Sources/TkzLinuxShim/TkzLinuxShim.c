// Before any GLib header: the domain of this file's own criticals.
#define G_LOG_DOMAIN "TkzLinuxShim"

#include "TkzLinuxShim.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdint.h>
#include <unistd.h>

// MARK: - libdispatch main queue

// libdispatch SPI, the pair swift-corelibs-foundation's RunLoop uses (libdispatch
// `private/private.h`, swift-6.3.3-RELEASE: `dispatch_runloop_handle_t` is an `int` on Linux).
// libdispatch.so exports both; the `Dispatch` module does not declare them.
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *msg);

typedef struct {
    GSource source;
    gpointer tag;   // g_source_add_unix_fd's handle for the eventfd
    int fd;
} TkzMainQueueSource;

static guint main_queue_source_id;
static _Atomic guint64 main_queue_dispatches;   // written on the main thread, read from any

static gboolean main_queue_dispatch(GSource *source, GSourceFunc callback, gpointer user_data) {
    (void)callback;
    (void)user_data;
    TkzMainQueueSource *self = (TkzMainQueueSource *)source;
    if (!(g_source_query_unix_fd(source, self->tag) & G_IO_IN)) {
        return G_SOURCE_CONTINUE;
    }
    // Reset the eventfd before draining: the drain does not, and a wakeup written by a post that
    // lands during the drain must survive for the next iteration. The fd is non-blocking.
    uint64_t counter;
    ssize_t n;
    do {
        n = read(self->fd, &counter, sizeof counter);
    } while (n < 0 && errno == EINTR);
    atomic_fetch_add_explicit(&main_queue_dispatches, 1, memory_order_relaxed);
    _dispatch_main_queue_callback_4CF(NULL);
    return G_SOURCE_CONTINUE;
}

// No prepare/check: a source with a unix fd is ready whenever that fd's revents are set.
static GSourceFuncs main_queue_source_funcs = {
    .prepare = NULL,
    .check = NULL,
    .dispatch = main_queue_dispatch,
    .finalize = NULL,
};

guint tkz_main_queue_source_attach(GMainContext *context) {
    if (main_queue_source_id != 0) {
        return main_queue_source_id;
    }
    GSource *source = g_source_new(&main_queue_source_funcs, sizeof(TkzMainQueueSource));
    TkzMainQueueSource *self = (TkzMainQueueSource *)source;
    self->fd = _dispatch_get_main_queue_handle_4CF();
    self->tag = g_source_add_unix_fd(source, self->fd, G_IO_IN);
    g_source_set_priority(source, G_PRIORITY_DEFAULT);
    g_source_set_name(source, "tkzmux libdispatch main queue");
    main_queue_source_id = g_source_attach(source, context);
    g_source_unref(source);   // the context keeps it
    return main_queue_source_id;
}

guint64 tkz_main_queue_source_dispatch_count(void) {
    return atomic_load_explicit(&main_queue_dispatches, memory_order_relaxed);
}

// MARK: - Signals

gulong tkz_signal_connect(gpointer instance, const char *signal, GCallback callback, gpointer box,
                          GClosureNotify destroy) {
    // Whether g_signal_connect_data calls destroy when it fails is not documented (GLib 2.88 does
    // not), so a connection that would fail never reaches it: the same checks it makes, done here,
    // and destroy called here instead. The box then has exactly one release path whatever GLib does.
    guint signal_id = 0;
    GQuark detail = 0;
    if (callback == NULL || !G_TYPE_CHECK_INSTANCE(instance)
        || !g_signal_parse_name(signal, G_TYPE_FROM_INSTANCE(instance), &signal_id, &detail, TRUE)) {
        g_critical("%s: signal '%s' is invalid for instance '%p'", G_STRFUNC, signal, instance);
        if (destroy != NULL) {
            destroy(box, NULL);
        }
        return 0;
    }
    return g_signal_connect_data(instance, signal, callback, box, destroy, (GConnectFlags)0);
}

// MARK: - APIs newer than 4.16

static GMutex symbol_lock;
static GHashTable *symbol_cache;   // name (owned) → address, or symbol_missing
static int forced_minor = -1;
static char symbol_missing;        // its address marks a cached NULL

unsigned tkz_gtk_minor_version(void) {
    g_mutex_lock(&symbol_lock);
    int forced = forced_minor;
    g_mutex_unlock(&symbol_lock);
    return forced >= 0 ? (unsigned)forced : gtk_get_minor_version();
}

void *tkz_gtk_symbol(const char *name, unsigned minor) {
    if (gtk_get_major_version() != 4) {
        return NULL;
    }
    // The version gate comes before the cache, which holds only what dlsym found.
    if (tkz_gtk_minor_version() < minor) {
        return NULL;
    }
    g_mutex_lock(&symbol_lock);
    if (symbol_cache == NULL) {
        symbol_cache = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    }
    void *address = g_hash_table_lookup(symbol_cache, name);
    if (address == NULL) {
        address = dlsym(RTLD_DEFAULT, name);
        if (address == NULL) {
            address = &symbol_missing;
        }
        g_hash_table_insert(symbol_cache, g_strdup(name), address);
    }
    g_mutex_unlock(&symbol_lock);
    return address == &symbol_missing ? NULL : address;
}

void tkz_gtk_force_minor_version(int minor) {
    g_mutex_lock(&symbol_lock);
    forced_minor = minor;
    if (symbol_cache != NULL) {
        g_hash_table_remove_all(symbol_cache);
    }
    g_mutex_unlock(&symbol_lock);
}
