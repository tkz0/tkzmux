// Raw /proc access for the Linux ProcessTable and ListeningPorts back-ends (WOR-304 S6).
//
// Files under /proc report a size of 0 and are generated on read, so they are read with plain
// read(2) until end of file rather than through Foundation, which would also cost a String or Data
// per call on a path polled every few seconds. Every helper answers nil (or skips the entry) on any
// failure: a process can exit between two reads, and under `hidepid` another user's entries fail
// with EACCES. Neither is an error worth reporting.

#if os(Linux)
import Glibc

enum Procfs {
    /// The whole file at `path`, or nil when it cannot be opened or read.
    static func read(_ path: String) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return withUnsafeTemporaryAllocation(byteCount: 16_384, alignment: 1) { chunk -> [UInt8]? in
            var bytes: [UInt8] = []
            while true {
                let count = Glibc.read(fd, chunk.baseAddress, chunk.count)
                if count > 0 {
                    bytes.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[..<count]))
                } else if count == 0 {
                    return bytes
                } else if errno != EINTR {
                    return nil
                }
            }
        }
    }

    /// The target of the symbolic link at `path`, or nil.
    static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count)
        // A result that fills the buffer may have been truncated.
        guard count > 0, count < buffer.count else { return nil }
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Calls `body` with the name of every entry of the directory at `path` except `.` and `..`,
    /// and with the directory's fd for `*at` calls. False when the directory cannot be opened.
    @discardableResult
    static func forEachEntry(
        in path: String, _ body: (_ name: UnsafePointer<CChar>, _ directoryFD: Int32) -> Void
    ) -> Bool {
        guard let directory = opendir(path) else { return false }
        defer { closedir(directory) }
        let fd = dirfd(directory)
        while let entry = readdir(directory) {
            withUnsafePointer(to: &entry.pointee.d_name) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: 256) { name in
                    if name[0] == 0x2E, name[1] == 0 || (name[1] == 0x2E && name[2] == 0) { return }
                    body(name, fd)
                }
            }
        }
        return true
    }

    /// The numeric entries of the directory at `path` (pids under /proc, tids under task/), or
    /// nil when it cannot be opened.
    static func numericEntries(in path: String) -> [pid_t]? {
        var numbers: [pid_t] = []
        let opened = forEachEntry(in: path) { name, _ in
            if let number = parseDecimal(name) { numbers.append(number) }
        }
        return opened ? numbers : nil
    }

    /// A NUL-terminated string of decimal digits as a pid, or nil.
    static func parseDecimal(_ name: UnsafePointer<CChar>) -> pid_t? {
        var value: Int64 = 0
        var index = 0
        while name[index] != 0 {
            let digit = Int64(name[index]) - 0x30
            guard (0...9).contains(digit), value <= Int64(Int32.max) else { return nil }
            value = value * 10 + digit
            index += 1
        }
        guard index > 0, value <= Int64(Int32.max) else { return nil }
        return pid_t(value)
    }

    /// Appends each whitespace-separated decimal number in `bytes` (a task's `children` file).
    static func appendPids(in bytes: [UInt8], to pids: inout [pid_t]) {
        var value: Int64 = 0
        var digits = 0
        func flush() {
            if digits > 0, value > 0, value <= Int64(Int32.max) { pids.append(pid_t(value)) }
            value = 0
            digits = 0
        }
        for byte in bytes {
            guard byte >= 0x30, byte <= 0x39 else {
                flush()
                continue
            }
            if value <= Int64(Int32.max) { value = value * 10 + Int64(byte - 0x30) }
            digits += 1
        }
        flush()
    }
}
#endif
