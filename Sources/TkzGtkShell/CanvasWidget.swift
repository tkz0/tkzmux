// CanvasWidget — the Swift side of TkzCanvas, the one GtkWidget tkzmux draws through (WOR-314 S2).
//
// TkzCanvas (TkzLinuxShim) forwards its snapshot, measure, size_allocate, realize, unrealize,
// focus and accessibility-child vfuncs to a C vtable plus a `ctx`. Here the vtable is a set of
// `@convention(c)` trampolines and `ctx` is a `CanvasBox`, retained with `Unmanaged` when the
// widget is made and released by the vtable's `destroy` when GTK disposes it, and nowhere else
// (the same rule as signal boxes; ClosureBoxes counts both).
//
// Ownership, so nothing forms a cycle through C:
//   - CanvasWidget holds the widget's one Swift reference (a GObjectRef); a parent (a window, a
//     GtkGraphicsOffload) holds its own.
//   - The box holds the CanvasWidget weakly, and CanvasWidget holds its delegate weakly. Whoever
//     owns the CanvasWidget (S4's CanvasHost implementation) owns the delegate too, usually by
//     being it.
//   - Once the CanvasWidget or its delegate is gone, every vfunc takes GtkWidget's own behaviour:
//     an empty snapshot, the default size and focus handling, no accessible child.
//
// GTK calls the vfuncs on its thread, which is the main actor's, so the trampolines enter it with
// `MainActor.assumeIsolated`, like the signal trampolines.

import CGtk
import TkzLinuxShim

/// What a TkzCanvas asks of its owner. Every method has a default that keeps GtkWidget's own
/// behaviour, so a delegate implements only what it needs.
@MainActor
public protocol CanvasWidgetDelegate: AnyObject {
    /// Appends the canvas's content to `snapshot` (a `GtkSnapshot *`).
    func canvasSnapshot(_ canvas: CanvasWidget, snapshot: OpaquePointer)
    /// The canvas's minimum and natural size along `orientation`, or nil for GtkWidget's.
    func canvasMeasure(_ canvas: CanvasWidget, orientation: GtkOrientation, forSize: Int32) -> CanvasWidget.Measure?
    /// The canvas has its new size, in logical pixels.
    func canvasSizeAllocate(_ canvas: CanvasWidget, width: Int32, height: Int32, baseline: Int32)
    /// The canvas has a native and a surface.
    func canvasRealize(_ canvas: CanvasWidget)
    /// The canvas is about to lose its surface; it is still there.
    func canvasUnrealize(_ canvas: CanvasWidget)
    /// Keyboard focus moving in `direction`: true if the canvas took or kept it, false if it
    /// passes, nil for GtkWidget's handling.
    func canvasFocus(_ canvas: CanvasWidget, direction: GtkDirectionType) -> Bool?
    /// The accessibility slot (WOR-325): the canvas's first accessible child, transfer full, or nil
    /// for none (a `GtkAccessible *`).
    func canvasFirstAccessibleChild(_ canvas: CanvasWidget) -> OpaquePointer?
}

extension CanvasWidgetDelegate {
    public func canvasSnapshot(_ canvas: CanvasWidget, snapshot: OpaquePointer) {}
    public func canvasMeasure(_ canvas: CanvasWidget, orientation: GtkOrientation, forSize: Int32) -> CanvasWidget.Measure? { nil }
    public func canvasSizeAllocate(_ canvas: CanvasWidget, width: Int32, height: Int32, baseline: Int32) {}
    public func canvasRealize(_ canvas: CanvasWidget) {}
    public func canvasUnrealize(_ canvas: CanvasWidget) {}
    public func canvasFocus(_ canvas: CanvasWidget, direction: GtkDirectionType) -> Bool? { nil }
    public func canvasFirstAccessibleChild(_ canvas: CanvasWidget) -> OpaquePointer? { nil }
}

@MainActor
public final class CanvasWidget {
    /// A measurement along one orientation, in logical pixels.
    public struct Measure: Equatable, Sendable {
        public var minimum: Int32
        public var natural: Int32

        public init(minimum: Int32, natural: Int32) {
            self.minimum = minimum
            self.natural = natural
        }
    }

    /// The TkzCanvas. Valid for as long as this object lives.
    public let widget: GObjectRef<UnsafeMutablePointer<GtkWidget>>

    /// Receives the forwarded vfuncs. Weak: see the ownership notes at the top of the file.
    public weak var delegate: (any CanvasWidgetDelegate)?

    public init(delegate: (any CanvasWidgetDelegate)? = nil) {
        let box = CanvasBox()
        var vtable = canvasVTable
        // The canvas owns the retain from here on; `destroyCanvasBox` gives it back.
        let pointer = tkz_canvas_new(&vtable, Unmanaged.passRetained(box).toOpaque())!
        widget = GObjectRef(adopting: pointer)
        self.delegate = delegate
        box.canvas = self
    }

    /// The live TkzCanvas instances in the process (TkzLinuxShim's count): created and not yet
    /// finalized, whether or not a CanvasWidget still refers to them.
    public nonisolated static var liveInstances: Int { Int(tkz_canvas_live_count()) }

    /// `gtk_widget_queue_draw`: GTK calls `canvasSnapshot` on the next frame.
    public func queueDraw() {
        gtk_widget_queue_draw(widget.pointer)
    }
}

/// A canvas's `ctx`. Retained once when the widget is made; released by `destroyCanvasBox` only.
final class CanvasBox {
    weak var canvas: CanvasWidget?

    init() { ClosureBoxes.created(.canvas) }

    deinit { ClosureBoxes.destroyed(.canvas) }

    /// The CanvasWidget and its delegate behind `ctx`, if both are still alive.
    @MainActor
    static func target(_ ctx: UnsafeMutableRawPointer?) -> (CanvasWidget, any CanvasWidgetDelegate)? {
        guard let canvas = Unmanaged<CanvasBox>.fromOpaque(ctx!).takeUnretainedValue().canvas,
              let delegate = canvas.delegate else { return nil }
        return (canvas, delegate)
    }
}

// The trampolines. As with signals, `ctx` crosses into the main-actor closure as an address and
// becomes the box again on the other side.

private let canvasVTable = TkzCanvasVTable(
    snapshot: { ctx, _, snapshot in
        let address = UInt(bitPattern: ctx), snapshotAddress = UInt(bitPattern: snapshot)
        MainActor.assumeIsolated {
            guard let (canvas, delegate) = CanvasBox.target(UnsafeMutableRawPointer(bitPattern: address)),
                  let snapshot = OpaquePointer(bitPattern: snapshotAddress) else { return }
            delegate.canvasSnapshot(canvas, snapshot: snapshot)
        }
    },
    measure: { ctx, _, orientation, forSize, minimum, natural in
        let address = UInt(bitPattern: ctx)
        let measure = MainActor.assumeIsolated { () -> CanvasWidget.Measure? in
            guard let (canvas, delegate) = CanvasBox.target(UnsafeMutableRawPointer(bitPattern: address)) else { return nil }
            return delegate.canvasMeasure(canvas, orientation: orientation, forSize: forSize)
        }
        guard let measure else { return 0 }
        minimum!.pointee = measure.minimum
        natural!.pointee = measure.natural
        return 1
    },
    size_allocate: { ctx, _, width, height, baseline in
        let address = UInt(bitPattern: ctx)
        MainActor.assumeIsolated {
            guard let (canvas, delegate) = CanvasBox.target(UnsafeMutableRawPointer(bitPattern: address)) else { return }
            delegate.canvasSizeAllocate(canvas, width: width, height: height, baseline: baseline)
        }
    },
    realize: { ctx, _ in
        let address = UInt(bitPattern: ctx)
        MainActor.assumeIsolated {
            guard let (canvas, delegate) = CanvasBox.target(UnsafeMutableRawPointer(bitPattern: address)) else { return }
            delegate.canvasRealize(canvas)
        }
    },
    unrealize: { ctx, _ in
        let address = UInt(bitPattern: ctx)
        MainActor.assumeIsolated {
            guard let (canvas, delegate) = CanvasBox.target(UnsafeMutableRawPointer(bitPattern: address)) else { return }
            delegate.canvasUnrealize(canvas)
        }
    },
    focus: { ctx, _, direction in
        let address = UInt(bitPattern: ctx)
        let answer = MainActor.assumeIsolated { () -> Bool? in
            guard let (canvas, delegate) = CanvasBox.target(UnsafeMutableRawPointer(bitPattern: address)) else { return nil }
            return delegate.canvasFocus(canvas, direction: direction)
        }
        return answer.map { $0 ? 1 : 0 } ?? TKZ_CANVAS_DEFAULT
    },
    first_accessible_child: { ctx, _ in
        let address = UInt(bitPattern: ctx)
        let child = MainActor.assumeIsolated { () -> UInt in
            guard let (canvas, delegate) = CanvasBox.target(UnsafeMutableRawPointer(bitPattern: address)) else { return 0 }
            return UInt(bitPattern: delegate.canvasFirstAccessibleChild(canvas))
        }
        return OpaquePointer(bitPattern: child)
    },
    destroy: destroyCanvasBox
)

/// The vtable's `destroy`: the box's only release. GTK disposes widgets on its own thread, but the
/// box is not main-actor isolated, like a signal box.
private let destroyCanvasBox: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
    Unmanaged<CanvasBox>.fromOpaque(ctx!).release()
}
