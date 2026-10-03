// HookSocket — the name of a running instance's hook socket, in the one module both sides of the
// socket can see.
//
// The pty environment (`TkzTerminalCore`, which exports `TKZMUX_SOCKET`) and the listener
// (`AgentBridge.HookServer`) must agree on the path byte for byte, and neither module can import
// the other, so the naming lives here.
//
// **Where.** On macOS the socket sits in the application-support directory, as it always has. On
// Linux it sits in the per-login runtime directory, `$XDG_RUNTIME_DIR/tkzmux` (0700, a tmpfs that
// logout clears, so a crash leaves nothing in persistent storage; ADR-0002), and falls back to the
// support directory when there is none. `directory(support:environment:)` is the one place that
// decides, and both sides call it.
//
// **Why one socket per instance and not one per install.** With a single `tkzmux.sock` a second
// running tkzmux (a dev build started from a pane of the installed one) cannot bind — the first
// instance's socket answers a probe `connect()`, so it is never treated as stale — and its start
// failure is only a log line. Its panes still export the shared path, so every `launch` and hook
// frame from its Claude sessions lands in the *other* instance, which holds the same session ids
// (both loaded the same `state.json`) and binds the foreign pid to its own copy of the row. A row
// bound to two Claudes flips between two descriptors; the working dot vanishes or never appears.
// Naming the socket after the pid gives every instance its own listener and routes each pane's
// frames back to the instance that spawned it.

import Foundation
#if os(Linux)
import TkzPlatform
#endif

public enum HookSocket {
    public static let prefix = "tkzmux-"
    public static let suffix = ".sock"

    /// `tkzmux-<pid>.sock`.
    public static func fileName(pid: pid_t) -> String {
        "\(prefix)\(pid)\(suffix)"
    }

    /// The directory the instance sockets live in. macOS: `support`, unchanged. Linux:
    /// `$XDG_RUNTIME_DIR/tkzmux` as `environment` names it, created 0700
    /// (`AppPaths.privateRuntimeDirectory`), or `support` when the variable is unset, empty or
    /// relative, or the directory is not private to this user or not writable.
    ///
    /// The owner-only directory plus the socket's own `chmod 0600` (`HookServer`) are the access
    /// boundary; there is no peer-credential check (docs/linux/agents.md).
    public static func directory(
        support: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        #if os(Linux)
        AppPaths.privateRuntimeDirectory(environment: environment) ?? support
        #else
        support
        #endif
    }

    /// The socket of the instance with `pid`, inside `directory` (see `directory(support:)`).
    public static func url(in directory: URL, pid: pid_t) -> URL {
        directory.appending(path: fileName(pid: pid), directoryHint: .notDirectory)
    }

    /// Whether `name` is an instance socket — `tkzmux-` + one or more digits + `.sock`, and
    /// nothing else. The legacy per-install `tkzmux.sock` (no dash) is deliberately *not* one: a
    /// file left by a pre-upgrade build is ignored, never swept.
    public static func isInstanceSocket(_ name: String) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
              name.utf8.count > prefix.utf8.count + suffix.utf8.count
        else { return false }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        return digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
