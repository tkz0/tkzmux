// TkzPlatform — the one place tkzmux talks to OS-specific APIs below the UI (WOR-304).
//
// A leaf module: Foundation only, never AppKit or GTK, and nothing in tkzmux below it. Each
// primitive has one API for both OSes and a back-end per OS; a back-end that needs a framework the
// other OS lacks lives in a per-OS folder (`Darwin/`), so the source hygiene tests can forbid those
// imports everywhere else.
//
//   Darwin/Logging.swift      `TkzLogger` / `TkzSignposter`, aliases of `os.Logger` / `OSSignposter`
//   Linux/LinuxLogging.swift  `TkzLogger`: the same call shape, journald-backed (Linux/Journal.swift)
//   Linux/Signposts.swift     `TkzSignposter`: a no-op, or Chrome trace JSON under `TKZMUX_TRACE`
//   AppPaths.swift            `AppPaths`: home, support, cache and runtime directories (XDG on Linux)
//   SHA256.swift              `SHA256`: FIPS 180-4 in plain Swift, CryptoKit's call shape, both OSes
//   Clocks.swift              `Clocks`: monotonic (stops in sleep) and boot (counts sleep) nanoseconds

/// Module marker used by the smoke tests until the module has API on every OS.
public enum TkzPlatformModule {
    public static let name = "TkzPlatform"
}
