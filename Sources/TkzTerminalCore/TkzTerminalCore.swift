// TkzTerminalCore — pty, VT bridge (libghostty-vt), TerminalSession. See docs/design.md → Terminal engine.
// Stub from M0.1 (TKZ-5); real code arrives in M1.1–M1.3.
import TkzPtyShim

/// Module marker used by the smoke tests until the module has real API.
public enum TkzTerminalCoreModule {
    public static let name = "TkzTerminalCore"

    /// ABI version of the C pty shim this module was built against.
    public static var ptyShimVersion: Int32 { tkz_pty_shim_version() }
}
