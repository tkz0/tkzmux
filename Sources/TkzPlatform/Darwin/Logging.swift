// Logging and signposts on Darwin — the facade's macOS half (WOR-304 S1).
//
// `TkzLogger` and `TkzSignposter` are the only names the rest of tkzmux logs through, on both OSes.
// Here they are plain aliases of `os.Logger` and `OSSignposter`, so nothing changes on the Mac:
// every call site still builds its own `OSLogMessage` from the string literal it passes, so the
// `privacy:` annotations, the `<private>` redaction in `log stream` and the deferred formatting
// are exactly what they were with a direct `import os`. A wrapper that took a `String` would
// format every message eagerly and lose the per-field redaction, so there is none.
//
// `os` is re-exported for the same reason: `OSSignpostID`, `OSSignpostIntervalState` and the
// `OSLogMessage` interpolation types stay visible to every file that imports TkzPlatform. This is
// the only `import os` in Sources/; everything else imports TkzPlatform. The Linux half
// (a journald-backed struct with the same API) lives in Linux/.

#if canImport(Darwin)
@_exported import os

/// The logger every tkzmux module uses: `os.Logger` on macOS.
public typealias TkzLogger = os.Logger

/// The signposter every tkzmux module uses: `OSSignposter` on macOS.
public typealias TkzSignposter = OSSignposter

/// The names Linux gives its own signpost types; the same `os` types on macOS.
public typealias TkzSignpostID = OSSignpostID
public typealias TkzSignpostIntervalState = OSSignpostIntervalState
#endif
