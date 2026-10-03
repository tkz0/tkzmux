// ClosureBoxes — the debug counter of Swift boxes handed to C (WOR-314 S2).
//
// Every Swift object TkzGtkShell passes to GTK as user data (a signal handler's closure, a
// canvas's context, a dma-buf texture's lease, a GDBus callback's state) is retained with
// `Unmanaged` and released only by the destroy-notify GTK calls for it (or, for a one-shot GDBus
// operation, by its completion). A box GTK never releases is a leak; one released twice is a
// crash. Each kind counts itself here, on creation and in `deinit`, so the open/close-cycle checks
// can show the count back at its baseline once every window is gone.

import Synchronization

public enum ClosureBoxes {
    /// One counter per kind of box.
    public enum Kind: Sendable, CaseIterable {
        case signal
        case canvas
        /// A GdkTexture over a presentation-ring dma-buf (`CanvasTextures`, S4).
        case texture
        /// A GDBus callback's state: a pending call or bus connection, a signal subscription, a
        /// name watch or ownership, an exported object (WOR-320 S1).
        case dbus
    }

    /// The boxes alive in the process, every kind together.
    public static var live: Int { Kind.allCases.reduce(0) { $0 + live($1) } }

    /// The boxes of one kind alive in the process.
    public static func live(_ kind: Kind) -> Int {
        switch kind {
        case .signal: signals.load(ordering: .relaxed)
        case .canvas: canvases.load(ordering: .relaxed)
        case .texture: textures.load(ordering: .relaxed)
        case .dbus: dbus.load(ordering: .relaxed)
        }
    }

    static func created(_ kind: Kind) {
        switch kind {
        case .signal: signals.add(1, ordering: .relaxed)
        case .canvas: canvases.add(1, ordering: .relaxed)
        case .texture: textures.add(1, ordering: .relaxed)
        case .dbus: dbus.add(1, ordering: .relaxed)
        }
    }

    static func destroyed(_ kind: Kind) {
        switch kind {
        case .signal: signals.subtract(1, ordering: .relaxed)
        case .canvas: canvases.subtract(1, ordering: .relaxed)
        case .texture: textures.subtract(1, ordering: .relaxed)
        case .dbus: dbus.subtract(1, ordering: .relaxed)
        }
    }

    private static let signals = Atomic<Int>(0)
    private static let canvases = Atomic<Int>(0)
    private static let textures = Atomic<Int>(0)
    private static let dbus = Atomic<Int>(0)
}
