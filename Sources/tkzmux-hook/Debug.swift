// Small helpers shared by the rest of the target. `Darwin` only — see main.swift header.
import Darwin

/// Reads an environment variable, returning nil when unset (matches `getenv`'s NULL semantics).
func envString(_ name: String) -> String? {
    guard let c = getenv(name) else { return nil }
    return String(cString: c)
}

/// `TKZMUX_HOOK_DEBUG=1` turns on stderr diagnostics; stdout is reserved for `settings-merge`.
let hookDebug = envString("TKZMUX_HOOK_DEBUG") == "1"

func debugLog(_ message: @autoclosure () -> String) {
    guard hookDebug else { return }
    let bytes = Array((message() + "\n").utf8)
    bytes.withUnsafeBytes { buf in
        _ = write(STDERR_FILENO, buf.baseAddress, buf.count)
    }
}

/// `$CLAUDE_CONFIG_DIR`, else `$HOME/.claude`. Which account a Claude Code process belongs to
/// follows from this directory and nothing else — see `statuslineAccountKey(configDir:)`.
func claudeConfigDirectory() -> String {
    if let configDir = envString("CLAUDE_CONFIG_DIR"), !configDir.isEmpty { return configDir }
    return (envString("HOME") ?? "") + "/.claude"
}
