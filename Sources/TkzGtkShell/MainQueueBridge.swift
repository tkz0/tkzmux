// MainQueueBridge — GTK owns the main thread, libdispatch's main queue runs on it (WOR-314 S1).
//
// On Linux the main queue, and with it the main actor, `Task { @MainActor … }`, `Task.sleep`
// resumptions and every `DispatchSource` on `.main`, is drained by whoever calls
// `_dispatch_main_queue_callback_4CF` on the process main thread. tkzmux never calls
// `dispatchMain()`: GLib iterates the default context there instead, and the GSource in
// TkzLinuxShim drains the queue whenever libdispatch signals its eventfd (docs/linux/spikes.md,
// WOR-300 S2).
//
// Two rules follow:
//   - Keep every `DispatchSource` in a property. An unretained source is deallocated and never
//     fires on Linux (WOR-300 S2).
//   - Never run a nested main loop from main-queue work (no `g_main_context_iteration` inside a
//     main-actor job): the drain is not re-entrant, so a nested iteration stalls the queue.
//     `iterate` is for the entry point's own top-level loop and the self-check.

import CGtk
import TkzLinuxShim

public enum MainQueueBridge {
    /// Attaches the main-queue source to the default GMainContext, once. Call it on the process
    /// main thread before the first iteration (before `g_application_run`, or before `iterate`).
    @discardableResult
    public static func attach() -> UInt32 {
        tkz_main_queue_source_attach(nil)
    }

    /// How many times the source has drained the queue (a diagnostic; see TkzLinuxShim.h).
    public static var dispatchCount: UInt64 { UInt64(tkz_main_queue_source_dispatch_count()) }

    /// Iterates the default context on the calling thread, blocking between events, until `done`
    /// returns true or `timeoutMilliseconds` pass. Returns whether `done` held. For top-level code
    /// on the main thread only (see the rules above), never from a main-queue block.
    public static func iterate(timeoutMilliseconds: UInt32, until done: () -> Bool) -> Bool {
        let context = g_main_context_default()
        let expired = UnsafeMutablePointer<gint>.allocate(capacity: 1)
        expired.initialize(to: 0)
        defer { expired.deallocate() }
        // A timeout source wakes the blocking iteration at the deadline.
        let timer = g_timeout_add(timeoutMilliseconds, { flag in
            flag!.assumingMemoryBound(to: gint.self).pointee = 1
            return tkz_source_remove()
        }, expired)
        while !done() && expired.pointee == 0 {
            g_main_context_iteration(context, 1)
        }
        if expired.pointee == 0 {
            g_source_remove(timer)
        }
        return done()
    }
}
