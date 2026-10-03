// The macOS `ProcessTable` (WOR-304 S6): libproc.
//
// `children`, `startTime`, `name` and `parent` are AgentBridge's `ProcessTree` (ProcessLiveness.swift)
// lifted verbatim; `descendants` is shared with Linux in ProcessTable.swift. `startTicks` reads the
// same `proc_bsdinfo` as `startTime`, to the microsecond. `exe` and `cwd` are TkzPtyShim's
// `tkz_proc_path` and `tkz_proc_cwd` (`proc_pidpath`, PROC_PIDVNODEPATHINFO) in Swift.

#if canImport(Darwin)
import Darwin
import Foundation

public enum LibprocProcessTable: ProcessTableBackend {
    /// Direct children of `pid` via `proc_listchildpids`.
    ///
    /// Unlike `proc_listallpids`, this call does not support the "pass NULL to size the buffer"
    /// idiom (it ignores `pid` and returns a bogus system-wide count), and its return value is the
    /// **number of pids** written, not a byte count — so a fixed, generous buffer is used and the
    /// return value indexes directly into it.
    public static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_listchildpids(pid, raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    /// The process's start time via `PROC_PIDTBSDINFO.pbi_start_tvsec`, or `nil` if unavailable.
    public static func startTime(of pid: pid_t) -> Date? {
        guard let info = bsdInfo(of: pid) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    /// `pbi_start_tvsec` and `pbi_start_tvusec` as microseconds since 1970.
    public static func startTicks(of pid: pid_t) -> UInt64? {
        guard let info = bsdInfo(of: pid) else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    /// The process's short name (`p_comm`, the executable's file name capped at `MAXCOMLEN`)
    /// via `proc_name`, or `nil` when the pid is gone or not readable. Used on both sides of the
    /// comparison in `ProcessOwnership`, so the cap cannot make two names disagree.
    public static func name(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_name(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard written > 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// The parent pid via `PROC_PIDTBSDINFO.pbi_ppid`, or `nil` if unavailable.
    public static func parent(of pid: pid_t) -> pid_t? {
        guard let info = bsdInfo(of: pid) else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// `proc_pidpath`, or nil.
    public static func exe(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, a macro Swift does not import.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let written = buffer.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard written > 0 else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// `PROC_PIDVNODEPATHINFO.pvi_cdir.vip_path`, or nil.
    public static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard result == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// `PROC_PIDTBSDINFO` for `pid`, or nil.
    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard result == size else { return nil }
        return info
    }
}
#endif
