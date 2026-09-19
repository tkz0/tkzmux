// `tkzmux-hook launch --pid <N> --cwd <DIR> --config-dir <DIR> [--agent <KIND>] -- <argv…>`.
// `Darwin` only.
import Darwin

/// Parses and sends the `launch` frame. Always returns normally (exit 0 on every path is handled
/// by the caller) — a malformed invocation just sends nothing.
///
/// The config directory is no longer this binary's business to work out: the shim already knows
/// `$CLAUDE_CONFIG_DIR`/`$HOME/.claude` (or whatever an equivalent looks like for another agent)
/// and passes it in, so `--config-dir` is required exactly like `--pid`/`--cwd`. `--agent` is
/// optional — an older, already-installed shim never sends it, and `HookServer` reads that absence
/// as Claude.
func runLaunch(_ args: [String]) {
    var pid: pid_t?
    var cwd: String?
    var configDir: String?
    var agent: String?
    var argv: [String] = []

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--pid":
            i += 1
            if i < args.count { pid = pid_t(args[i]) }
        case "--cwd":
            i += 1
            if i < args.count { cwd = args[i] }
        case "--config-dir":
            i += 1
            if i < args.count { configDir = args[i] }
        case "--agent":
            i += 1
            if i < args.count { agent = args[i] }
        case "--":
            i += 1
            argv = Array(args[i...])
            i = args.count
            continue
        default:
            break
        }
        i += 1
    }

    guard let pid, let cwd, let configDir else {
        debugLog("launch: missing --pid, --cwd, or --config-dir")
        return
    }

    let sid = envString("TKZMUX_SESSION_ID") ?? ""

    let frame = buildLaunchFrame(sid: sid, pid: pid, cwd: cwd, configDir: configDir, argv: argv, agent: agent)
    sendFrame(frame)
}
