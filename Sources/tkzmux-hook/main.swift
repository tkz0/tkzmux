// tkzmux-hook — Claude Code hook relay. Must stay tiny and fast (< 20 ms): `import Darwin` only,
// no Foundation. Forwards hook JSON to the app over a Unix socket. Every error path exits 0 with
// empty stdout — except `settings-merge`, whose failures exit non-zero with empty stdout — because
// this binary must never slow down or break Claude Code when the app isn't running. M3.2 (TKZ-22).
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

default:
    let event = args[1]
    let (stdinBytes, hitCap) = readStdin()
    let sid = envString("TKZMUX_SESSION_ID") ?? ""
    let ppid = getppid()
    let ts = currentTimeMillis()
    let frame = buildHookFrame(event: event, sid: sid, ppid: ppid, ts: ts, stdinBytes: stdinBytes, stdinHitCap: hitCap)
    sendFrame(frame)
    exit(0)
}
