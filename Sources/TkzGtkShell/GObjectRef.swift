// GObjectRef — the one way Swift owns a GObject (WOR-314 S1).
//
// GObject refcounting is thread-safe, but GTK objects are not: they are created, used and
// finalized on the GTK thread. So a reference is a `@MainActor` class holding exactly one strong
// ref, dropped in an `isolated deinit`: whichever thread lets go of the last Swift reference, the
// `g_object_unref` (and with it any finalization) runs on the main actor, which under
// `g_application_run` is the GTK thread.
//
// The raw pointer is never Sendable. Code off the main actor can hold a GObjectRef but cannot
// reach its `pointer` without hopping back, and nothing in this module opts out of Sendable
// checking (SourceHygieneTests).

import CGtk
import TkzLinuxShim

/// A pointer to a GObject instance, in either of the forms GTK types import as: a typed
/// `UnsafeMutablePointer` for a type whose struct is public (GtkWidget, GtkWindow, GApplication)
/// or an `OpaquePointer` for a final or interface type (GtkGraphicsOffload, GdkToplevel,
/// GSimpleAction).
public protocol GObjectPointer {
    init(gpointer: UnsafeMutableRawPointer)
    /// The same address as a `gpointer`, for the g_object_* and g_signal_* calls.
    var gpointer: UnsafeMutableRawPointer { get }
}

extension UnsafeMutablePointer: GObjectPointer {
    public init(gpointer: UnsafeMutableRawPointer) { self = gpointer.assumingMemoryBound(to: Pointee.self) }
    public var gpointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

extension OpaquePointer: GObjectPointer {
    public init(gpointer: UnsafeMutableRawPointer) { self.init(gpointer) }
    public var gpointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

@MainActor
public final class GObjectRef<Pointer: GObjectPointer> {
    /// The object. Valid for as long as this reference lives.
    public let pointer: Pointer

    /// Takes over a reference the caller owns (transfer full: what `*_new` returns). A floating
    /// reference (a fresh GtkWidget or other GInitiallyUnowned) is sunk, so it becomes this one
    /// strong ref; nothing is added.
    public init(adopting pointer: Pointer) {
        if g_object_is_floating(pointer.gpointer) != 0 {
            g_object_ref_sink(pointer.gpointer)
        }
        self.pointer = pointer
    }

    /// Adds a strong reference to an object someone else owns (transfer none: a getter's
    /// result). A floating reference is sunk instead, the way a GTK container claims a child.
    public init(retaining pointer: Pointer) {
        g_object_ref_sink(pointer.gpointer)
        self.pointer = pointer
    }

    /// The object as a `GObject *`, for the g_object_* calls that take one.
    public var object: UnsafeMutablePointer<GObject> { tkz_object(pointer.gpointer) }

    isolated deinit {
        g_object_unref(pointer.gpointer)
    }
}
