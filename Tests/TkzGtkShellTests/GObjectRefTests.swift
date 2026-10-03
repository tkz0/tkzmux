// GObjectRefTests — WOR-314 S1. GObjectRef holds exactly one strong ref and drops it on the main
// actor, and signal closure boxes are released by the destroy-notify only.
//
// Plain GObject and GIO types (GSimpleAction, GApplication, GInitiallyUnowned): no display, no
// `gtk_init`, no main loop. Signals are emitted synchronously from the test, which runs on the
// main actor, so the trampolines' `MainActor.assumeIsolated` holds.
import CGtk
import Dispatch
import Testing
import TkzGtkShell
import TkzLinuxShim

/// A GObject weak pointer: cleared by GLib when the object is finalized.
@MainActor
final class WeakPointer {
    let slot = UnsafeMutablePointer<gpointer?>.allocate(capacity: 1)

    init(_ object: some GObjectPointer) {
        slot.initialize(to: object.gpointer)
        g_object_add_weak_pointer(tkz_object(object.gpointer), slot)
    }

    var isCleared: Bool { slot.pointee == nil }

    isolated deinit {
        if let object = slot.pointee { g_object_remove_weak_pointer(tkz_object(object), slot) }
        slot.deallocate()
    }
}

/// A GSimpleAction (an opaque type, so an OpaquePointer), transfer full.
func newAction(_ name: String = "probe") -> OpaquePointer {
    g_simple_action_new(name, nil)!
}

@Suite(.serialized) @MainActor
struct GObjectRefTests {
    @Test func adoptingTakesOverTheCallersReference() {
        let action = newAction()
        let weak = WeakPointer(action)
        var ref: GObjectRef? = GObjectRef(adopting: action)
        #expect(tkz_object_ref_count(action.gpointer) == 1)
        _ = ref
        ref = nil
        #expect(weak.isCleared)
    }

    @Test func retainingAddsOneReference() {
        let action = newAction()
        let weak = WeakPointer(action)
        var ref: GObjectRef? = GObjectRef(retaining: action)
        #expect(tkz_object_ref_count(action.gpointer) == 2)
        _ = ref
        ref = nil
        #expect(tkz_object_ref_count(action.gpointer) == 1)
        g_object_unref(action.gpointer)
        #expect(weak.isCleared)
    }

    @Test func aFloatingReferenceIsSunkNotDoubled() throws {
        let raw = try #require(g_object_new_with_properties(g_initially_unowned_get_type(), 0, nil, nil))
        #expect(g_object_is_floating(raw) != 0)
        let weak = WeakPointer(raw)
        var ref: GObjectRef? = GObjectRef(adopting: raw)
        #expect(g_object_is_floating(raw) == 0)
        #expect(tkz_object_ref_count(raw) == 1)
        _ = ref
        ref = nil
        #expect(weak.isCleared)
    }

    /// The last Swift reference dropped off the main actor: the unref, and so the finalization,
    /// still runs on the main queue (the main actor's executor on Linux).
    @Test func theUnrefRunsOnTheMainActorWhenTheLastReferenceDiesElsewhere() async throws {
        let probe = FinalizeProbe()
        DispatchQueue.main.setSpecific(key: probe.key, value: true)
        defer { DispatchQueue.main.setSpecific(key: probe.key, value: nil) }

        let action = newAction()
        let weak = WeakPointer(action)
        let unmanaged = Unmanaged.passRetained(probe)
        defer { unmanaged.release() }
        g_object_weak_ref(tkz_object(action.gpointer), { data, _ in
            Unmanaged<FinalizeProbe>.fromOpaque(data!).takeUnretainedValue().finalized()
        }, unmanaged.toOpaque())

        // The detached task ends up with the only reference and drops it on a worker thread.
        let gate = DispatchSemaphore(value: 0)
        var ref: GObjectRef? = GObjectRef(adopting: action)
        let task = Task.detached { [ref] in
            gate.wait()
            _ = ref
        }
        ref = nil
        #expect(!weak.isCleared)
        gate.signal()
        await task.value
        for _ in 0..<200 where !weak.isCleared {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(weak.isCleared)
        #expect(probe.finalizedOnMainQueue == true)
    }
}

/// Records, from GLib's weak-ref callback, whether the object was finalized on the main queue.
final class FinalizeProbe {
    let key = DispatchSpecificKey<Bool>()
    var finalizedOnMainQueue: Bool?

    func finalized() {
        finalizedOnMainQueue = DispatchQueue.getSpecific(key: key) == true
    }
}
