// `tkzmux-hook launch --pid <N> --cwd <DIR> -- <argv…>`. `Darwin` only.
import Darwin

/// Parses and sends the `launch` frame. Always returns normally (exit 0 on every path is handled
/// by the caller) — a malformed invocation just sends nothing.
func runLaunch(_ args: [String]) {
    var pid: pid_t?
    var cwd: String?
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

    guard let pid, let cwd else {
        debugLog("launch: missing --pid or --cwd")
        return
    }

    let sid = envString("TKZMUX_SESSION_ID") ?? ""
    let configDir: String
    if let claudeConfigDir = envString("CLAUDE_CONFIG_DIR"), !claudeConfigDir.isEmpty {
        configDir = claudeConfigDir
    } else {
        configDir = (envString("HOME") ?? "") + "/.claude"
    }

    let frame = buildLaunchFrame(sid: sid, pid: pid, cwd: cwd, configDir: configDir, argv: argv)
    sendFrame(frame)
}
