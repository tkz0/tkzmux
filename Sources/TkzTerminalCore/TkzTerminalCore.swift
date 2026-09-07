// TkzTerminalCore — pty, VT bridge (libghostty-vt), TerminalSession. See docs/design.md → Terminal engine.
// M0.1 stub (TKZ-5); libghostty-vt wrappers in GhosttyVt+Swift.swift (M1.1); Pty/TerminalSession arrive in M1.2–M1.3.
import TkzPtyShim

/// Module marker used by the smoke tests (pty shim version); the libghostty-vt API lives in GhosttyVt+Swift.swift.
public enum TkzTerminalCoreModule {
    public static let name = "TkzTerminalCore"

    /// ABI version of the C pty shim this module was built against.
    public static var ptyShimVersion: Int32 { tkz_pty_shim_version() }
}
