// `tkzmux-hook notify-argv '<json>'` — Codex's legacy `notify = [...]` config hands its payload as
// one JSON string in argv rather than on stdin the way every other hook event does. `Darwin` only.
import Darwin

/// Parses Codex's notify payload and sends it as an ordinary `hook` frame — `HookServer` needs no
/// second frame shape for this. The frame's `event` is the payload's own `"type"`
/// (`agent-turn-complete`, …); the raw JSON bytes become the frame's `payload`, so the existing
/// three-tier truncation in `buildHookFrame` covers an oversized notify payload the same way it
/// covers an oversized stdin one.
///
/// Malformed argv, a missing `type`, or anything that isn't a JSON object: send nothing and return.
/// Codex is waiting on this process to exit, so there is nothing to gain by being stricter here —
/// a frame that doesn't arrive is exactly as safe as one the server would have dropped anyway.
func runNotifyArgv(_ args: [String]) {
    guard let json = args.first else {
        debugLog("notify-argv: missing payload argument")
        return
    }

    var parser = JSONParser(json)
    guard let value = parser.parse(), value.asObject != nil else {
        debugLog("notify-argv: payload is not a JSON object")
        return
    }
    guard let type = value.get("type")?.asString else {
        debugLog("notify-argv: payload has no string 'type' field")
        return
    }

    let sid = envString("TKZMUX_SESSION_ID") ?? ""
    let ppid = getppid()
    let ts = currentTimeMillis()
    let agent = envString("TKZMUX_AGENT")
    let frame = buildHookFrame(
        event: type, sid: sid, ppid: ppid, ts: ts,
        stdinBytes: Array(json.utf8), stdinHitCap: false, agent: agent)
    sendFrame(frame)
}
