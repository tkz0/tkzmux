// Reads the hook payload from stdin. `Darwin` only.
import Darwin

/// Reads stdin to EOF, keeping at most `cap` bytes. Bytes beyond the cap are still drained (so
/// Claude Code never sees a broken pipe / SIGPIPE while writing its side) but discarded; `hitCap`
/// tells the caller the returned bytes are not the whole payload, so the frame builder can skip
/// straight to `{"truncated":true}` instead of running the string-truncation scanner over a JSON
/// document whose tail was chopped mid-value (which would not parse as JSON anyway).
func readStdin(cap: Int = 1 * 1024 * 1024) -> (bytes: [UInt8], hitCap: Bool) {
    var result = [UInt8]()
    result.reserveCapacity(min(cap, 65536))
    var buf = [UInt8](repeating: 0, count: 65536)
    var hitCap = false
    while true {
        let n = buf.withUnsafeMutableBytes { ptr -> Int in
            read(STDIN_FILENO, ptr.baseAddress, ptr.count)
        }
        if n <= 0 { break }
        if result.count < cap {
            let take = min(n, cap - result.count)
            result.append(contentsOf: buf[0..<take])
            if take < n { hitCap = true }
        } else {
            hitCap = true
        }
    }
    if hitCap {
        debugLog("stdin: truncated at \(cap) byte cap")
    }
    return (result, hitCap)
}
