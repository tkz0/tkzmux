// CanvasFrameQueue — which presented frames a host still holds, and when each goes back to its
// ring (WOR-314 S4).
//
// A ring image the compositor may still read must not be drawn into. `GtkCanvasHost` keeps one
// GdkTexture per slot (GTK still creates a wl_buffer per attach, see docs/linux/presentation.md),
// so it never sees a texture destroyed per frame and cannot release from a destroy-notify. This
// type decides when a frame is old enough by position, the same way for the fake host; the GTK
// host then also waits until GTK no longer refers to the slot's texture:
//
//   pending    presented, not yet shown; a newer `submit` releases it at once (never on screen)
//   shown      appended by the latest snapshot: the compositor shows it, or is about to
//   previous   shown one frame earlier: the compositor may still be scanning it out until it
//              latches `shown`
//
// `show()` (the host's snapshot) moves pending → shown → previous and releases what falls off the
// end, two frames after it was shown. With a ring of three that leaves one image to draw into,
// and the ring's re-acquire still waits for the consumer's implicit fences on it (WOR-313 S5a),
// so a compositor that is slower than that only costs a GPU wait, never a torn frame.

@MainActor
public final class CanvasFrameQueue<Frame> {
    public struct Entry {
        public let frame: Frame
        let release: @MainActor (Frame) -> Void
    }

    public private(set) var pending: Entry?
    public private(set) var shown: Entry?
    public private(set) var previous: Entry?

    public init() {}

    /// Frames held: not yet given back to their rings.
    public var heldCount: Int { [pending, shown, previous].count { $0 != nil } }

    /// A frame to show from the next `show()` on; `release` gives it back to its ring. Replaces
    /// (and releases) a pending frame that was never shown.
    public func submit(_ frame: Frame, release: @escaping @MainActor (Frame) -> Void) {
        if let pending { pending.release(pending.frame) }
        pending = Entry(frame: frame, release: release)
    }

    /// The frame to show now: the pending one if there is one (releasing the frame two shows old),
    /// else the one already shown. Nil before anything was submitted.
    @discardableResult
    public func show() -> Frame? {
        if let next = pending {
            if let previous { previous.release(previous.frame) }
            previous = shown
            shown = next
            pending = nil
        }
        return shown?.frame
    }

    /// Takes the shown frame out without releasing it: the host could not show it, and hands it to
    /// its ring's `importFailed`, which releases it. The previous frame is shown again.
    public func removeShown() -> Frame? {
        guard let entry = shown else { return nil }
        shown = previous
        previous = nil
        return entry.frame
    }

    /// Releases every frame held: the host is going away, or its surface is.
    public func releaseAll() {
        let held = [pending, shown, previous]
        pending = nil
        shown = nil
        previous = nil
        for entry in held { if let entry { entry.release(entry.frame) } }
    }
}
