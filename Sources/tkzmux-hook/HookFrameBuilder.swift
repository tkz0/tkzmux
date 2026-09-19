// Builds the NDJSON wire frames sent to `HookServer`. `Darwin` only.
import Darwin

private let frameSizeLimit = 240 * 1024
private let stringTruncateLimit = 64 * 1024
private let truncatedSuffix: [UInt8] = Array("…[truncated]".utf8)

/// Replaces raw `\n`/`\r` bytes with spaces so the whole frame stays one line. Valid JSON tolerates
/// this (a real newline can't legally appear inside a JSON string); anything else is unaffected.
private func replaceNewlines(_ bytes: [UInt8]) -> [UInt8] {
    bytes.map { $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 }
}

/// Byte-level scanner (in-string / backslash-escape state only, no full JSON validation) that
/// truncates every JSON string literal longer than 64 KiB, cutting on a UTF-8 character boundary
/// and never inside an escape sequence.
private func truncateLongStrings(_ payload: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(payload.count)
    let n = payload.count
    var i = 0
    while i < n {
        let b = payload[i]
        guard b == 0x22 else { out.append(b); i += 1; continue }
        out.append(b) // opening quote
        var j = i + 1
        while j < n {
            if payload[j] == 0x5C, j + 1 < n { j += 2; continue }
            if payload[j] == 0x22 { break }
            j += 1
        }
        let strStart = i + 1
        let strEnd = j // index of closing quote, or n if unterminated
        let contentLen = strEnd - strStart
        if contentLen > stringTruncateLimit {
            var k = strStart
            while k - strStart < stringTruncateLimit && k < strEnd {
                k += unit(payload, k, strEnd)
            }
            out.append(contentsOf: payload[strStart..<k])
            out.append(contentsOf: truncatedSuffix)
        } else {
            out.append(contentsOf: payload[strStart..<strEnd])
        }
        if strEnd < n {
            out.append(0x22) // closing quote
            i = strEnd + 1
        } else {
            i = strEnd
        }
    }
    return out
}

/// Length in bytes of the "unit" starting at `idx`: a `\uXXXX` escape (6), a two-char escape (2),
/// or one UTF-8 character (1-4). Used so a cut point never lands mid-escape or mid-codepoint.
private func unit(_ payload: [UInt8], _ idx: Int, _ end: Int) -> Int {
    let b = payload[idx]
    if b == 0x5C, idx + 1 < end {
        if payload[idx + 1] == 0x75 { return min(6, end - idx) } // \uXXXX
        return min(2, end - idx)
    }
    return min(utf8SequenceLength(b), end - idx)
}

/// `agent` rides on the envelope, next to `event`/`sid`/`ppid` — never inside `payload`, which stays
/// exactly what the agent itself sent (or the stdin bytes handed to `notify-argv`). Omitted when
/// `nil`: an already-installed shim from before this ticket sends no `agent` field at all, and
/// `HookServer` reads that absence as Claude — the same contract `HookPayload.agent`'s default
/// documents on the server side.
private func assembleHookFrame(event: String, sid: String, ppid: pid_t, ts: Int64, agent: String?, payload: [UInt8]) -> [UInt8] {
    var prefix = "{\"v\":1,\"type\":\"hook\",\"event\":\"\(jsonEscape(event))\",\"sid\":\"\(jsonEscape(sid))\","
        + "\"ppid\":\(ppid),\"ts\":\(ts),"
    if let agent { prefix += "\"agent\":\"\(jsonEscape(agent))\"," }
    prefix += "\"payload\":"
    var bytes = Array(prefix.utf8)
    bytes.append(contentsOf: payload)
    bytes.append(contentsOf: Array("}\n".utf8))
    return bytes
}

/// Builds the `hook` wire frame. `stdinHitCap` means `readStdin` had to stop early — the tail of
/// the payload was chopped mid-value, so it cannot be valid JSON; skip straight to the
/// `{"truncated":true}` fallback rather than running the string scanner over unparseable bytes.
///
/// `agent` is `TKZMUX_AGENT` as the caller read it from its own environment — this function does
/// not know or care where it came from. It reaches every hook-shaped frame this binary sends,
/// including `notify-argv`'s, because both paths funnel through here.
func buildHookFrame(event: String, sid: String, ppid: pid_t, ts: Int64, stdinBytes: [UInt8], stdinHitCap: Bool, agent: String?) -> [UInt8] {
    if stdinHitCap {
        return assembleHookFrame(event: event, sid: sid, ppid: ppid, ts: ts, agent: agent, payload: Array(#"{"truncated":true}"#.utf8))
    }

    let rawPayload = stdinBytes.isEmpty ? Array("null".utf8) : replaceNewlines(stdinBytes)
    var frame = assembleHookFrame(event: event, sid: sid, ppid: ppid, ts: ts, agent: agent, payload: rawPayload)
    if frame.count <= frameSizeLimit { return frame }

    let shrunk = truncateLongStrings(rawPayload)
    frame = assembleHookFrame(event: event, sid: sid, ppid: ppid, ts: ts, agent: agent, payload: shrunk)
    if frame.count <= frameSizeLimit { return frame }

    return assembleHookFrame(event: event, sid: sid, ppid: ppid, ts: ts, agent: agent, payload: Array(#"{"truncated":true}"#.utf8))
}

/// `agent` is omitted (rather than sent as `null` or `""`) exactly when the caller passes `nil`, so
/// an old shim that never learned about `--agent` still produces a frame `HookServer` reads as
/// Claude.
func buildLaunchFrame(sid: String, pid: pid_t, cwd: String, configDir: String, argv: [String], agent: String?) -> [UInt8] {
    var s = "{\"v\":1,\"type\":\"launch\",\"sid\":\"\(jsonEscape(sid))\",\"pid\":\(pid),"
    s += "\"cwd\":\"\(jsonEscape(cwd))\",\"config_dir\":\"\(jsonEscape(configDir))\","
    if let agent { s += "\"agent\":\"\(jsonEscape(agent))\"," }
    s += "\"argv\":["
    s += argv.map { "\"\(jsonEscape($0))\"" }.joined(separator: ",")
    s += "]}\n"
    return Array(s.utf8)
}
