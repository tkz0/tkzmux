// ClosureBoxes — the debug counter of Swift boxes handed to C (WOR-314 S2).
//
// Every Swift object TkzGtkShell passes to GTK as user data (a signal handler's closure, a
// canvas's context) is retained with `Unmanaged` and released only by the destroy-notify GTK
// calls for it. A box GTK never releases is a leak; one released twice is a crash. Each kind
// counts itself here, on creation and in `deinit`, so the open/close-cycle checks can show the
// count back at its baseline once every window is gone.

import Synchronization

public enum ClosureBoxes {
    /// One counter per kind of box.
    public enum Kind: Sendable, CaseIterable {
        case signal
        case canvas
    }

    /// The boxes alive in the process, every kind together.
    public static var live: Int { Kind.allCases.reduce(0) { $0 + live($1) } }

    /// The boxes of one kind alive in the process.
    public static func live(_ kind: Kind) -> Int {
        switch kind {
        case .signal: signals.load(ordering: .relaxed)
        case .canvas: canvases.load(ordering: .relaxed)
        }
    }

    static func created(_ kind: Kind) {
        switch kind {
        case .signal: signals.add(1, ordering: .relaxed)
        case .canvas: canvases.add(1, ordering: .relaxed)
        }
    }

    static func destroyed(_ kind: Kind) {
        switch kind {
        case .signal: signals.subtract(1, ordering: .relaxed)
        case .canvas: canvases.subtract(1, ordering: .relaxed)
        }
    }

    private static let signals = Atomic<Int>(0)
    private static let canvases = Atomic<Int>(0)
}
