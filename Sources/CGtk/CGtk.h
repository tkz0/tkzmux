// The GTK 4 headers, pinned to the 4.16 API (ADR-0002 D3, D4).
//
// GDK_VERSION_MIN_REQUIRED and GDK_VERSION_MAX_ALLOWED are set before <gtk/gtk.h>, so any direct
// use of an API newer than 4.16 is a "Not available before 4.x" deprecation warning, in Swift as
// in C. The guard only warns: such an API is always reached through `tkz_gtk_symbol`
// (TkzLinuxShim), never by name, or the binary stops loading on a 4.16 host.
//
// TkzLinuxShim's public header includes this file, so both modules see GTK through the same
// guard.
#pragma once

#ifndef GDK_VERSION_MIN_REQUIRED
#define GDK_VERSION_MIN_REQUIRED GDK_VERSION_4_16
#endif
#ifndef GDK_VERSION_MAX_ALLOWED
#define GDK_VERSION_MAX_ALLOWED GDK_VERSION_4_16
#endif

#include <gtk/gtk.h>
#include <glib-unix.h>

#if !GTK_CHECK_VERSION(4, 16, 0)
#error "tkzmux needs GTK 4.16 or later (ADR-0002 D3)"
#endif
