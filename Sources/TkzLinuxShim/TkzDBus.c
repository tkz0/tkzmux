// TkzDBus — the C half of TkzGtkShell's GDBus wrapper (WOR-320 S1).
//
// Everything else in the wrapper is plain GIO called from Swift. These two exist because Swift
// cannot make the call safely itself: `G_VARIANT_TYPE` is a cast macro whose argument GLib asserts
// on, and `g_dbus_connection_register_object` has a free function whose behaviour on failure is
// not part of the API.

// Before any GLib header: the domain of this file's own criticals.
#define G_LOG_DOMAIN "TkzLinuxShim"

#include "TkzLinuxShim.h"

gboolean tkz_variant_is_of_type(GVariant *value, const char *type_string) {
    if (value == NULL || type_string == NULL || !g_variant_type_string_is_valid(type_string)) {
        return FALSE;
    }
    return g_variant_is_of_type(value, G_VARIANT_TYPE(type_string));
}

// MARK: - Object registration

// What GDBus holds as the registration's user data. Two references: GDBus's (dropped by its free
// function) and this file's own (dropped once registration has returned). The Swift box is
// destroyed when the last one goes, so a failed registration releases it exactly once whether
// GLib called the free function or not.
typedef struct {
    gatomicrefcount refs;
    GDBusInterfaceMethodCallFunc method_call;
    gpointer box;
    GDestroyNotify destroy;
} TkzDBusRegistration;

static void registration_unref(gpointer data) {
    TkzDBusRegistration *self = data;
    if (g_atomic_ref_count_dec(&self->refs)) {
        if (self->destroy != NULL) {
            self->destroy(self->box);
        }
        g_free(self);
    }
}

static void registration_method_call(GDBusConnection *connection, const gchar *sender,
                                     const gchar *object_path, const gchar *interface_name,
                                     const gchar *method_name, GVariant *parameters,
                                     GDBusMethodInvocation *invocation, gpointer data) {
    TkzDBusRegistration *self = data;
    self->method_call(connection, sender, object_path, interface_name, method_name, parameters,
                      invocation, self->box);
}

guint tkz_dbus_register_object(GDBusConnection *connection, const char *object_path,
                               GDBusInterfaceInfo *info, GDBusInterfaceMethodCallFunc method_call,
                               gpointer box, GDestroyNotify destroy, GError **error) {
    TkzDBusRegistration *self = g_new0(TkzDBusRegistration, 1);
    g_atomic_ref_count_init(&self->refs);
    self->method_call = method_call;
    self->box = box;
    self->destroy = destroy;

    // GDBus copies the vtable (GLib >= 2.38), so a stack one is enough.
    GDBusInterfaceVTable vtable = {
        .method_call = registration_method_call,
        .get_property = NULL,
        .set_property = NULL,
    };
    g_atomic_ref_count_inc(&self->refs);   // GDBus's reference
    guint id = g_dbus_connection_register_object(connection, object_path, info, &vtable, self,
                                                 registration_unref, error);
    if (id == 0 && !g_atomic_ref_count_compare(&self->refs, 1)) {
        // GLib kept its reference on failure (its free function was not called): drop it here.
        registration_unref(self);
    }
    registration_unref(self);   // this function's own reference
    return id;
}
