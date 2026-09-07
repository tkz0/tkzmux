// tkzmux-hook — Claude Code hook relay. Must stay tiny and fast (< 20 ms): `import Darwin` only,
// no Foundation. Reads one JSON payload from stdin, forwards one NDJSON frame over AF_UNIX to the
// app, exits 0 on every path and never writes to stdout. Implemented in M3.2 (TKZ-19).
import Darwin

// Drain stdin so Claude Code never sees a broken pipe, then exit 0.
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    let n = read(STDIN_FILENO, &buffer, buffer.count)
    if n <= 0 { break }
}
exit(0)
