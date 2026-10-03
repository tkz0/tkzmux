// The Linux `ProcessTable` (WOR-304 S6): /proc.
//
//   children     /proc/<pid>/task/*/children: one file per thread, listing the children that
//                thread forked. Kernels built without CONFIG_PROC_CHILDREN have no such file
//                (ENOENT), and then every /proc/<n>/stat is scanned for a matching ppid. Which of
//                the two applies is decided once, from this process's own main thread.
//   parent       field 4 of /proc/<pid>/stat
//   startTicks   field 22 of /proc/<pid>/stat: clock ticks after boot (proc_pid_stat(5))
//   startTime    `btime` from /proc/stat plus startTicks / sysconf(_SC_CLK_TCK)
//   name         /proc/<pid>/comm
//   exe, cwd     readlink /proc/<pid>/{exe,cwd}, without the ` (deleted)` the kernel appends once
//                the file is gone (an auto-update replaces the executable)
//
// `stat` puts `comm` in parentheses as field 2, and `comm` may itself hold spaces and parentheses
// (any 15 bytes the process chose), so fields are counted from after the LAST `)`.

#if os(Linux)
import Foundation
import Glibc

public enum ProcfsProcessTable: ProcessTableBackend {
    public static func children(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        guard kernelListsChildren else { return childrenFromStat(of: pid) }
        guard let tasks = Procfs.numericEntries(in: "/proc/\(pid)/task") else { return [] }
        var children: [pid_t] = []
        for tid in tasks {
            // A thread that exits between the listing and here has no file left; skip it.
            guard let bytes = Procfs.read("/proc/\(pid)/task/\(tid)/children") else { continue }
            Procfs.appendPids(in: bytes, to: &children)
        }
        return children
    }

    public static func parent(of pid: pid_t) -> pid_t? {
        stat(of: pid)?.ppid
    }

    public static func name(of pid: pid_t) -> String? {
        guard pid > 0, var bytes = Procfs.read("/proc/\(pid)/comm") else { return nil }
        if bytes.last == 0x0A { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func startTime(of pid: pid_t) -> Date? {
        guard let ticks = startTicks(of: pid), let bootTime, clockTicksPerSecond > 0 else { return nil }
        return Date(timeIntervalSince1970: bootTime + Double(ticks) / Double(clockTicksPerSecond))
    }

    public static func startTicks(of pid: pid_t) -> UInt64? {
        stat(of: pid)?.startTicks
    }

    public static func exe(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        return Procfs.readLink("/proc/\(pid)/exe").map(strippingDeleted)
    }

    public static func cwd(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        return Procfs.readLink("/proc/\(pid)/cwd").map(strippingDeleted)
    }

    // MARK: stat

    /// The fields of /proc/<pid>/stat that tkzmux reads.
    struct Stat: Hashable {
        /// Field 2, without its parentheses.
        var comm: String
        /// Field 3: R, S, D, Z, T, …
        var state: UInt8
        /// Field 4.
        var ppid: pid_t
        /// Field 22, `starttime`.
        var startTicks: UInt64
    }

    static func stat(of pid: pid_t) -> Stat? {
        guard pid > 0, let bytes = Procfs.read("/proc/\(pid)/stat") else { return nil }
        return parseStat(bytes)
    }

    /// Parses a /proc/<pid>/stat line, or nil when it is malformed. `comm` runs from the first
    /// `(` to the last `)`; the fields after it are split on spaces.
    static func parseStat(_ bytes: [UInt8]) -> Stat? {
        guard let open = bytes.firstIndex(of: 0x28), let close = bytes.lastIndex(of: 0x29), open < close
        else { return nil }
        let comm = String(decoding: bytes[(open + 1)..<close], as: UTF8.self)
        // fields[0] is field 3 (state), so field n is fields[n - 3].
        let fields = bytes[(close + 1)...].split(separator: 0x20, omittingEmptySubsequences: true)
        guard fields.count > 19, fields[0].count == 1,
            let ppid = decimal(fields[1]).flatMap({ pid_t(exactly: $0) }),
            let startTicks = decimal(fields[19])
        else { return nil }
        return Stat(comm: comm, state: fields[0].first!, ppid: ppid, startTicks: startTicks)
    }

    /// An unsigned decimal field (a trailing newline allowed), or nil.
    private static func decimal(_ field: ArraySlice<UInt8>) -> UInt64? {
        var value: UInt64 = 0
        var digits = 0
        for byte in field {
            if byte == 0x0A { break }
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            let (shifted, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = shifted.addingReportingOverflow(UInt64(byte - 0x30))
            guard !overflow1, !overflow2 else { return nil }
            value = sum
            digits += 1
        }
        return digits > 0 ? value : nil
    }

    // MARK: Children without CONFIG_PROC_CHILDREN

    /// Whether this kernel has /proc/<pid>/task/<tid>/children, judged from this process's main
    /// thread (whose tid is its pid, and which exists for as long as the process does).
    static let kernelListsChildren: Bool = access("/proc/self/task/\(getpid())/children", F_OK) == 0

    /// The children of `pid` found by reading every /proc/<n>/stat. Slower than the children files
    /// (one read per process on the machine), and the fallback when they are missing.
    static func childrenFromStat(of pid: pid_t) -> [pid_t] {
        guard pid > 0, let all = Procfs.numericEntries(in: "/proc") else { return [] }
        return all.filter { stat(of: $0)?.ppid == pid }
    }

    // MARK: Clock

    /// `btime` from /proc/stat: the boot time in whole seconds since 1970. Read once; it moves
    /// only when the wall clock is stepped.
    static let bootTime: Double? = {
        guard let bytes = Procfs.read("/proc/stat") else { return nil }
        for line in bytes.split(separator: 0x0A) where line.starts(with: Array("btime ".utf8)) {
            return decimal(line.dropFirst(6)).map { Double($0) }
        }
        return nil
    }()

    /// `sysconf(_SC_CLK_TCK)`: the unit of `startTicks` (100 on every common kernel).
    static let clockTicksPerSecond: Int = sysconf(Int32(_SC_CLK_TCK))

    // MARK: readlink

    private static let deletedSuffix = " (deleted)"

    /// `target` without the ` (deleted)` the kernel appends to a link whose file is gone.
    static func strippingDeleted(_ target: String) -> String {
        target.hasSuffix(deletedSuffix) ? String(target.dropLast(deletedSuffix.count)) : target
    }
}
#endif
