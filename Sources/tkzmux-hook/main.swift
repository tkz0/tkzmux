// tkzmux-hook — Claude Code hook relay. Must stay tiny and fast (< 20 ms): `import Darwin` only,
// no Foundation. Forwards hook JSON to the app over a Unix socket. Every error path exits 0 with
// empty stdout — except `settings-merge`, whose failures exit non-zero with empty stdout — because
// this binary must never slow down or break Claude Code when the app isn't running. M3.2.
import Darwin

// The app may close the connection mid-write (or never accept it); never die to SIGPIPE for that.
signal(SIGPIPE, SIG_IGN)

func currentTimeMillis() -> Int64 {
    var tv = timeval()
    gettimeofday(&tv, nil)
    return Int64(tv.tv_sec) * 1000 + Int64(tv.tv_usec) / 1000
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    exit(0)
}

switch args[1] {
case "launch":
    runLaunch(Array(args.dropFirst(2)))
    exit(0)

case "settings-merge":
    let arg = args.count > 2 ? args[2] : nil
    exit(runSettingsMerge(arg: arg))

case "statusline-settings":
    exit(runStatuslineSettings(Array(args.dropFirst(2))))

case "statusline":
    // Never returns: it exits with the wrapped command's status, or 0. Outside the < 20 ms budget.
    runStatusline()

case "notify-argv":
    runNotifyArgv(Array(args.dropFirst(2)))
    exit(0)

default:
    let event = args[1]
    let (stdinBytes, hitCap) = readStdin()
    let sid = envString("TKZMUX_SESSION_ID") ?? ""
    let ppid = getppid()
    let ts = currentTimeMillis()
    // No flag carries this on the relay path: the shim exports `TKZMUX_AGENT` before `exec`ing the
    // agent, the agent inherits it, and the hook process the agent spawns for each event inherits
    // it in turn. Unset (an older shim, or an agent this ticket doesn't know about) reads as Claude.
    let agent = envString("TKZMUX_AGENT")
    let frame = buildHookFrame(event: event, sid: sid, ppid: ppid, ts: ts, stdinBytes: stdinBytes, stdinHitCap: hitCap, agent: agent)
    sendFrame(frame)
    exit(0)
}
