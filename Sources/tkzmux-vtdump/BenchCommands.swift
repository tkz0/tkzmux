// BenchCommands.swift — the multi-session measurement harness (M1.10 / TKZ-16).
//
//   tkzmux-vtdump bench --sessions N [--busy K] [--seconds S] [--json out.json]
//   tkzmux-vtdump bench-compress <file.tkzrec> [--repeats N] [--mode incremental|full]
//   tkzmux-vtdump bench-snapshot <file.tkzrec> [--repeats N]
//
// Everything here measures the *host process*: RSS and phys_footprint, thread count, and CPU over
// the idle window. The N zsh children are separate processes and their cost is deliberately NOT in
// these numbers — see docs/perf.md, which says so next to every table.
//
// Self-contained on purpose: `tkzmux-vtdump` does not depend on `Persistence`, so the snapshot
// file writing below is a local mirror of `SnapshotStore.save` rather than a call into it.
// (Package.swift delta reported with the ticket.)

import Darwin
import Dispatch
import Foundation
import Synchronization
import TkzTerminalCore

// MARK: - Process metrics

/// A point-in-time reading of what this process costs the machine.
struct ProcessMetrics: Sendable {
    /// `mach_task_basic_info.resident_size`.
    var residentBytes: UInt64
    /// `task_vm_info.phys_footprint` — what Activity Monitor calls "Memory".
    var footprintBytes: UInt64
    /// `task_vm_info.internal` — anonymous pages the task owns.
    var internalBytes: UInt64
    /// `task_vm_info.reusable` — pages the task has `MADV_FREE`'d. They stay in `resident_size`
    /// until the system needs them, so a reclamation that works shows up *here* before it shows up
    /// as a drop in RSS. Without this field "RSS unchanged" cannot tell "compressed nothing" from
    /// "freed, but Darwin still counts it".
    var reusableBytes: UInt64
    /// `task_vm_info.compressed` — pages in the OS compressor (unrelated to libghostty's own
    /// scrollback compression, but it moves when memory is reclaimed).
    var compressedBytes: UInt64
    /// `task_threads` count (Mach threads, not GCD queues).
    var threadCount: Int
    /// `proc_pid_rusage` user + system CPU, in seconds. Includes *live* threads, which
    /// `task_basic_info.user_time` does not.
    var cpuSeconds: Double
    /// `mach_absolute_time`-based wall clock, in seconds.
    var wallSeconds: Double

    static func sample() -> ProcessMetrics {
        let vm = machVMInfo()
        return ProcessMetrics(
            residentBytes: machResidentBytes(),
            footprintBytes: vm.footprint,
            internalBytes: vm.internal,
            reusableBytes: vm.reusable,
            compressedBytes: vm.compressed,
            threadCount: machThreadCount(),
            cpuSeconds: rusageCPUSeconds(),
            wallSeconds: Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        )
    }

    /// CPU as a percentage of one core over the interval since `earlier`.
    func cpuPercent(since earlier: ProcessMetrics) -> Double {
        let wall = wallSeconds - earlier.wallSeconds
        guard wall > 0 else { return 0 }
        return (cpuSeconds - earlier.cpuSeconds) / wall * 100
    }
}

private func machResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

private func machVMInfo() -> (footprint: UInt64, `internal`: UInt64, reusable: UInt64, compressed: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0, 0, 0) }
    return (UInt64(info.phys_footprint), UInt64(info.internal), UInt64(info.reusable), UInt64(info.compressed))
}

/// Mach thread count. Every port in the returned array must be deallocated, and the array itself
/// `vm_deallocate`d — leaking them inflates every later reading of this same process.
private func machThreadCount() -> Int {
    var threads: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
    for index in 0..<Int(count) {
        mach_port_deallocate(mach_task_self_, threads[index])
    }
    vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(Int(count) * MemoryLayout<thread_t>.size)
    )
    return Int(count)
}

private func rusageCPUSeconds() -> Double {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    if result == 0 {
        return Double(info.ri_user_time + info.ri_system_time) / 1e9
    }
    // Fall back to getrusage, which is also whole-process and thread-inclusive.
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

// MARK: - Tiny JSON writer

/// Enough JSON for a benchmark record, without a dependency and without `JSONSerialization`'s
/// `Any` boxing. Values keep insertion order so a diff between two runs reads sensibly.
indirect enum BenchJSON: Sendable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case array([BenchJSON])
    case object([(String, BenchJSON)])

    func encoded(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .string(let value):
            var escaped = ""
            for character in value.unicodeScalars {
                switch character {
                case "\"": escaped += "\\\""
                case "\\": escaped += "\\\\"
                case "\n": escaped += "\\n"
                case "\t": escaped += "\\t"
                case "\r": escaped += "\\r"
                default:
                    if character.value < 0x20 {
                        escaped += String(format: "\\u%04x", character.value)
                    } else {
                        escaped.unicodeScalars.append(character)
                    }
                }
            }
            return "\"\(escaped)\""
        case .number(let value):
            if value.isFinite {
                // Microsecond resolution: several of these numbers are sub-millisecond.
                return String(format: "%.6f", value)
            }
            return "null"
        case .integer(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let body = items.map { inner + $0.encoded(indent: indent + 1) }.joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            let body = pairs
                .map { inner + BenchJSON.string($0.0).encoded() + ": " + $0.1.encoded(indent: indent + 1) }
                .joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        }
    }
}

// MARK: - One benchmarked session

/// A byte counter shared with the pty read callback. `Mutex` is `Sendable` for any state, which is
/// what lets this be a real `Sendable` class with no `@unchecked` (shared brief, rule 5).
private final class ByteCounter: Sendable {
    private let value = Mutex<Int>(0)
    func add(_ amount: Int) { value.withLock { $0 += amount } }
    var current: Int { value.withLock { $0 } }
}

/// A live session: pty + `TerminalSession`, wired the way `TerminalHost` will wire them.
///
/// Deliberately *not* `Sendable`: it is created, driven and torn down from the harness thread and
/// never escapes it. Only `session` and the counter (both `Sendable`) reach the io queue.
private final class BenchSession {
    let id: String
    let session: TerminalSession
    let queue: DispatchQueue
    var pty: Pty?
    let bytesIn = ByteCounter()

    init(index: Int, cols: UInt16, rows: UInt16, scrollbackMaxBytes: Int, tkzmuxDir: URL) throws {
        self.id = String(format: "bench-%03d", index)
        var options = TerminalSessionOptions()
        options.cols = cols
        options.rows = rows
        options.scrollbackMaxBytes = scrollbackMaxBytes
        self.session = try TerminalSession(options: options, label: "tkzmux.bench.\(index)")
        self.queue = session.ioQueue

        let session = self.session
        let counter = self.bytesIn
        let spawn = TerminalEnvironment.loginShellSpawn(
            sessionID: id,
            cwd: FileManager.default.currentDirectoryPath,
            size: TerminalSize(rows: rows, cols: cols, cellWidthPx: 8, cellHeightPx: 17),
            tkzmuxDir: tkzmuxDir
        )
        self.pty = try Pty(
            spawn: spawn,
            ioQueue: queue,
            onData: { data in
                counter.add(data.count)
                session.write(ptyBytes: data)
            },
            onExit: { _ in }
        )
    }

    /// Writes a shell command. `Pty.write` is documented as io-queue-only.
    func send(_ text: String) {
        guard let pty else { return }
        queue.async {
            try? pty.write(Data(text.utf8))
        }
    }

    var scrollbackRows: Int { session.scrollbackRows }
    var isAlive: Bool { pty.map { !$0.hasExited } ?? false }

    func shutdown() {
        _ = pty?.terminate(signal: SIGKILL)
        pty = nil
    }
}

// MARK: - BenchCommands

public enum BenchCommands {
    /// What to fill a busy session's scrollback with.
    public enum Fill: String, Sendable {
        /// 20 000 identical 100-column coloured lines — the same shape the M1.3 spike used, and the
        /// worst case for memory (it fills the 24 MiB cap fastest). Uniform by construction, which
        /// is exactly the corpus the spike's compression result was criticised for.
        case uniform
        /// Real, varied terminal output: a recursive long listing of `/usr/share` and `/usr/lib`,
        /// which is what a build log or a tool run actually looks like — mixed line lengths, mixed
        /// bytes, no repetition the allocator can luck into.
        case varied

        func command(lines: Int) -> String {
            switch self {
            case .uniform:
                return "yes $'\\e[32m" + String(repeating: "x", count: 100) + "\\e[0m' | head -n \(lines)\n"
            case .varied:
                return "{ ls -laRG /usr/share /usr/lib /usr/local 2>/dev/null; "
                    + "ls -laRG /System/Library/Frameworks 2>/dev/null; } | head -n \(lines)\n"
            }
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("tkzmux-vtdump bench: " + message + "\n").utf8))
        exit(2)
    }

    static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Blocks the calling thread for `seconds` without burning CPU (a `sleep` in the middle of a
    /// CPU measurement must not itself show up as CPU).
    static func idle(seconds: Double) {
        guard seconds > 0 else { return }
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: bench --sessions

    /// `tkzmux-vtdump bench --sessions N [--busy K] [--seconds S] [--json out.json]`
    public static func sessions(
        count: Int, busy: Int, seconds: Double, json: URL?, fill: Fill = .uniform, lines: Int = 20_000
    ) throws {
        guard count > 0 else { fail("--sessions must be > 0") }
        let busyCount = min(max(busy, 0), count)
        let cols: UInt16 = 120
        let rows: UInt16 = 40
        let scrollbackMaxBytes = 24 * 1024 * 1024

        // A throwaway tkzmux dir: the ZDOTDIR it points at does not exist, so zsh sources no user
        // rc file. That makes the run reproducible, and it is stated as such in docs/perf.md.
        let tkzmuxDir = FileManager.default.temporaryDirectory
            .appending(path: "tkzmux-bench-\(getpid())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tkzmuxDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tkzmuxDir) }

        let baseline = ProcessMetrics.sample()
        note("baseline: rss \(mib(baseline.residentBytes)) MiB, threads \(baseline.threadCount)")

        // 1. Spawn.
        let spawnStart = DispatchTime.now().uptimeNanoseconds
        var sessions: [BenchSession] = []
        sessions.reserveCapacity(count)
        for index in 0..<count {
            sessions.append(
                try BenchSession(
                    index: index, cols: cols, rows: rows,
                    scrollbackMaxBytes: scrollbackMaxBytes, tkzmuxDir: tkzmuxDir
                )
            )
        }
        let spawnElapsed = Double(DispatchTime.now().uptimeNanoseconds - spawnStart) / 1e9
        defer { for session in sessions { session.shutdown() } }

        // Let every shell reach its first prompt.
        idle(seconds: 1.5)
        let afterSpawn = ProcessMetrics.sample()

        // 2. Busy load in the first `busyCount` sessions.
        var busyElapsed = 0.0
        if busyCount > 0 {
            let start = DispatchTime.now().uptimeNanoseconds
            for session in sessions.prefix(busyCount) {
                session.send(fill.command(lines: lines))
            }
            // Done when every busy session's scrollback stops growing for three polls in a row —
            // a fixed sleep would either truncate the load or pad the measurement.
            var stable = 0
            var previous = -1
            var waited = 0.0
            while stable < 3 && waited < 120 {
                idle(seconds: 0.25)
                waited += 0.25
                let total = sessions.prefix(busyCount).reduce(0) { $0 + $1.scrollbackRows }
                stable = (total == previous) ? stable + 1 : 0
                previous = total
            }
            busyElapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        }
        let afterBusy = ProcessMetrics.sample()

        // 3. Idle window — the headline CPU number.
        let idleStart = ProcessMetrics.sample()
        idle(seconds: seconds)
        let idleEnd = ProcessMetrics.sample()
        let idleCPUPercent = idleEnd.cpuPercent(since: idleStart)

        // Liveness gate: an exited shell holds no scrollback and would make RSS look wonderful.
        let alive = sessions.filter(\.isAlive).count
        let scrollbackRows = sessions.map(\.scrollbackRows)
        let bytesIn = sessions.map { $0.bytesIn.current }

        // 4. Compression on *live* sessions — the M1.3 re-measurement design.md asked for.
        // `reusable` is the field that matters: Darwin keeps MADV_FREE'd pages in `resident_size`
        // until something needs them, so a reclamation that worked shows up there first.
        let beforeCompress = ProcessMetrics.sample()
        let rowsBeforeCompress = sessions.map(\.scrollbackRows).reduce(0, +)
        var compressSteps = 0
        let compressStart = DispatchTime.now().uptimeNanoseconds
        for session in sessions {
            var more = true
            var steps = 0
            while more, steps < 1000 {
                more = session.session.compress(full: false)
                steps += 1
            }
            compressSteps += steps
        }
        let compressSeconds = Double(DispatchTime.now().uptimeNanoseconds - compressStart) / 1e9
        idle(seconds: 0.5)
        let afterCompress = ProcessMetrics.sample()
        let rowsAfterCompress = sessions.map(\.scrollbackRows).reduce(0, +)

        // 5. Snapshot all N.
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appending(path: "tkzmux-bench-snap-\(getpid())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: snapshotDirectory) }

        var snapshotBytes = 0
        var encodeSeconds = 0.0
        var writeSeconds = 0.0
        for session in sessions {
            let encodeStart = DispatchTime.now().uptimeNanoseconds
            let data = try session.session.snapshot()
            encodeSeconds += Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 1e9
            snapshotBytes += data.count
            let writeStart = DispatchTime.now().uptimeNanoseconds
            try atomicWrite(data, to: snapshotDirectory.appending(path: "\(session.id).ghsnap"))
            writeSeconds += Double(DispatchTime.now().uptimeNanoseconds - writeStart) / 1e9
        }
        let afterSnapshot = ProcessMetrics.sample()

        // 6. Restore all N, from disk, and check the content survived.
        var readSeconds = 0.0
        var restoreSeconds = 0.0
        var contentMatches = 0
        var scrollbackMatches = 0
        for session in sessions {
            let before = (try? session.session.formatted()) ?? ""
            let rowsBefore = session.scrollbackRows
            let readStart = DispatchTime.now().uptimeNanoseconds
            let data = try Data(contentsOf: snapshotDirectory.appending(path: "\(session.id).ghsnap"))
            readSeconds += Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1e9
            let restoreStart = DispatchTime.now().uptimeNanoseconds
            try session.session.restore(from: data)
            restoreSeconds += Double(DispatchTime.now().uptimeNanoseconds - restoreStart) / 1e9
            let after = (try? session.session.formatted()) ?? ""
            if before == after && !before.isEmpty { contentMatches += 1 }
            if session.scrollbackRows == rowsBefore && rowsBefore > 0 { scrollbackMatches += 1 }
        }
        let afterRestore = ProcessMetrics.sample()

        let perSessionRSS = Double(afterBusy.residentBytes &- baseline.residentBytes) / Double(count)
        let perSessionFootprint = Double(afterBusy.footprintBytes &- baseline.footprintBytes) / Double(count)

        let record = BenchJSON.object([
            ("kind", .string("bench.sessions")),
            ("date", .string(ISO8601DateFormatter().string(from: Date()))),
            ("configuration", .string(buildConfiguration)),
            ("sessions", .integer(count)),
            ("busy", .integer(busyCount)),
            ("idle_seconds", .number(seconds)),
            ("cols", .integer(Int(cols))),
            ("rows", .integer(Int(rows))),
            ("scrollback_max_bytes", .integer(scrollbackMaxBytes)),
            ("fill_lines", .integer(lines)),
            ("fill", .string(fill.rawValue)),
            ("busy_command", .string(fill.command(lines: lines).trimmingCharacters(in: .newlines))),
            ("alive_sessions", .integer(alive)),
            ("scrollback_rows_min", .integer(scrollbackRows.min() ?? 0)),
            ("scrollback_rows_max", .integer(scrollbackRows.max() ?? 0)),
            ("pty_bytes_total", .integer(bytesIn.reduce(0, +))),
            ("spawn_seconds", .number(spawnElapsed)),
            ("busy_seconds", .number(busyElapsed)),
            ("rss", .object([
                ("baseline_bytes", .integer(Int(baseline.residentBytes))),
                ("after_spawn_bytes", .integer(Int(afterSpawn.residentBytes))),
                ("after_busy_bytes", .integer(Int(afterBusy.residentBytes))),
                ("after_snapshot_bytes", .integer(Int(afterSnapshot.residentBytes))),
                ("after_restore_bytes", .integer(Int(afterRestore.residentBytes))),
                ("per_session_bytes", .number(perSessionRSS)),
            ])),
            ("footprint", .object([
                ("baseline_bytes", .integer(Int(baseline.footprintBytes))),
                ("after_spawn_bytes", .integer(Int(afterSpawn.footprintBytes))),
                ("after_busy_bytes", .integer(Int(afterBusy.footprintBytes))),
                ("per_session_bytes", .number(perSessionFootprint)),
            ])),
            ("threads", .object([
                ("baseline", .integer(baseline.threadCount)),
                ("after_spawn", .integer(afterSpawn.threadCount)),
                ("after_busy", .integer(afterBusy.threadCount)),
                ("idle_end", .integer(idleEnd.threadCount)),
            ])),
            ("cpu", .object([
                ("idle_window_seconds", .number(idleEnd.wallSeconds - idleStart.wallSeconds)),
                ("idle_cpu_seconds", .number(idleEnd.cpuSeconds - idleStart.cpuSeconds)),
                ("idle_percent_of_one_core", .number(idleCPUPercent)),
                ("total_cpu_seconds", .number(afterRestore.cpuSeconds - baseline.cpuSeconds)),
            ])),
            ("compression", .object([
                ("incremental_steps", .integer(compressSteps)),
                ("elapsed_seconds", .number(compressSeconds)),
                ("scrollback_rows_before", .integer(rowsBeforeCompress)),
                ("scrollback_rows_after", .integer(rowsAfterCompress)),
                ("rss_before_bytes", .integer(Int(beforeCompress.residentBytes))),
                ("rss_after_bytes", .integer(Int(afterCompress.residentBytes))),
                ("footprint_before_bytes", .integer(Int(beforeCompress.footprintBytes))),
                ("footprint_after_bytes", .integer(Int(afterCompress.footprintBytes))),
                ("internal_before_bytes", .integer(Int(beforeCompress.internalBytes))),
                ("internal_after_bytes", .integer(Int(afterCompress.internalBytes))),
                ("reusable_before_bytes", .integer(Int(beforeCompress.reusableBytes))),
                ("reusable_after_bytes", .integer(Int(afterCompress.reusableBytes))),
                ("os_compressed_before_bytes", .integer(Int(beforeCompress.compressedBytes))),
                ("os_compressed_after_bytes", .integer(Int(afterCompress.compressedBytes))),
            ])),
            ("snapshot", .object([
                ("total_bytes", .integer(snapshotBytes)),
                ("per_session_bytes", .number(Double(snapshotBytes) / Double(count))),
                ("encode_seconds", .number(encodeSeconds)),
                ("write_seconds", .number(writeSeconds)),
                ("read_seconds", .number(readSeconds)),
                ("restore_seconds", .number(restoreSeconds)),
                ("active_screen_identical_after_restore", .integer(contentMatches)),
                ("scrollback_rows_identical_after_restore", .integer(scrollbackMatches)),
            ])),
        ])

        let text = record.encoded()
        print(text)
        if let json {
            try Data(text.utf8).write(to: json)
        }
    }

    // MARK: bench-compress

    /// `tkzmux-vtdump bench-compress <file.tkzrec> [--repeats N] [--mode incremental|full]`
    ///
    /// Re-measures the M1.3 spike result (`compress(FULL)` reclaimed nothing on *synthetic*
    /// scrollback) against a **real** recording, which is what design.md asked for before anyone
    /// wires the idle timer.
    public static func compression(recording: URL, repeats: Int, full: Bool, json: URL?) throws {
        let reader = try RecordingReader(contentsOf: recording)
        var options = TerminalSessionOptions()
        options.cols = reader.header.cols
        options.rows = reader.header.rows
        options.scrollbackMaxBytes = 24 * 1024 * 1024
        let session = try TerminalSession(options: options, label: "tkzmux.bench.compress")

        let before = ProcessMetrics.sample()
        for _ in 0..<max(repeats, 1) {
            try reader.replay(into: session)
        }
        // Settle: give the allocator a moment so the reading is not mid-flight.
        idle(seconds: 0.2)
        let filled = ProcessMetrics.sample()
        let rowsBefore = session.scrollbackRows

        var steps = 0
        let start = DispatchTime.now().uptimeNanoseconds
        if full {
            _ = session.compress(full: true)
            steps = 1
        } else {
            // INCREMENTAL is bounded work: `compress` returns true for PENDING, so loop until it
            // stops asking to be called again.
            var more = true
            while more, steps < 10_000 {
                more = session.compress(full: false)
                steps += 1
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        idle(seconds: 0.2)
        let after = ProcessMetrics.sample()
        let rowsAfter = session.scrollbackRows

        let record = BenchJSON.object([
            ("kind", .string("bench.compress")),
            ("date", .string(ISO8601DateFormatter().string(from: Date()))),
            ("configuration", .string(buildConfiguration)),
            ("recording", .string(recording.lastPathComponent)),
            ("repeats", .integer(max(repeats, 1))),
            ("mode", .string(full ? "full" : "incremental")),
            ("replayed_bytes", .integer(reader.outputByteCount * max(repeats, 1))),
            ("scrollback_rows_before", .integer(rowsBefore)),
            ("scrollback_rows_after", .integer(rowsAfter)),
            ("steps", .integer(steps)),
            ("elapsed_seconds", .number(elapsed)),
            ("rss_empty_bytes", .integer(Int(before.residentBytes))),
            ("rss_filled_bytes", .integer(Int(filled.residentBytes))),
            ("rss_after_compress_bytes", .integer(Int(after.residentBytes))),
            ("rss_delta_bytes", .integer(Int(after.residentBytes) - Int(filled.residentBytes))),
            ("footprint_filled_bytes", .integer(Int(filled.footprintBytes))),
            ("footprint_after_compress_bytes", .integer(Int(after.footprintBytes))),
            ("footprint_delta_bytes", .integer(Int(after.footprintBytes) - Int(filled.footprintBytes))),
            ("reusable_filled_bytes", .integer(Int(filled.reusableBytes))),
            ("reusable_after_compress_bytes", .integer(Int(after.reusableBytes))),
            ("internal_filled_bytes", .integer(Int(filled.internalBytes))),
            ("internal_after_compress_bytes", .integer(Int(after.internalBytes))),
        ])
        let text = record.encoded()
        print(text)
        if let json { try Data(text.utf8).write(to: json) }
    }

    // MARK: bench-snapshot

    /// `tkzmux-vtdump bench-snapshot <file.tkzrec> [--repeats N]` — snapshot size and restore time
    /// as a function of how much real scrollback the terminal is holding.
    public static func snapshotCurve(recording: URL, repeatCounts: [Int], json: URL?) throws {
        let reader = try RecordingReader(contentsOf: recording)
        var points: [BenchJSON] = []
        for repeats in repeatCounts {
            var options = TerminalSessionOptions()
            options.cols = reader.header.cols
            options.rows = reader.header.rows
            options.scrollbackMaxBytes = 24 * 1024 * 1024
            let session = try TerminalSession(options: options, label: "tkzmux.bench.snap")
            let before = ProcessMetrics.sample()
            for _ in 0..<repeats { try reader.replay(into: session) }
            let filled = ProcessMetrics.sample()

            let encodeStart = DispatchTime.now().uptimeNanoseconds
            let data = try session.snapshot()
            let encode = Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 1e9

            let restoreStart = DispatchTime.now().uptimeNanoseconds
            try session.restore(from: data)
            let restore = Double(DispatchTime.now().uptimeNanoseconds - restoreStart) / 1e9

            points.append(.object([
                ("repeats", .integer(repeats)),
                ("scrollback_rows", .integer(session.scrollbackRows)),
                ("live_rss_delta_bytes", .integer(Int(filled.residentBytes) - Int(before.residentBytes))),
                ("snapshot_bytes", .integer(data.count)),
                ("encode_seconds", .number(encode)),
                ("restore_seconds", .number(restore)),
            ]))
        }
        let record = BenchJSON.object([
            ("kind", .string("bench.snapshot")),
            ("date", .string(ISO8601DateFormatter().string(from: Date()))),
            ("configuration", .string(buildConfiguration)),
            ("recording", .string(recording.lastPathComponent)),
            ("points", .array(points)),
        ])
        let text = record.encoded()
        print(text)
        if let json { try Data(text.utf8).write(to: json) }
    }

    // MARK: Helpers

    static var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    static func mib(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1024 / 1024)
    }

    /// tmp + fsync + `rename(2)`, the same shape as `Persistence.SnapshotStore.save`. Duplicated
    /// because `tkzmux-vtdump` does not depend on `Persistence` (see the ticket's delta).
    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UInt64.random(in: 0..<UInt64.max)).tmp")
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        let code = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target -> Int32 in
                guard let source, let target else { return -1 }
                return rename(source, target)
            }
        }
        if code != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The dispatch `main.swift` needs (reported, not added — main.swift is owned elsewhere):
    ///
    /// ```swift
    /// case "bench": try BenchCommands.run(Array(CommandLine.arguments.dropFirst(2)))
    /// ```
    public static func run(_ argv: [String]) throws {
        var flags: [String: String] = [:]
        var positionals: [String] = []
        var index = argv.startIndex
        let valueFlags: Set<String> = ["sessions", "busy", "seconds", "json", "repeats", "points", "fill", "lines"]
        while index < argv.endIndex {
            let argument = argv[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if valueFlags.contains(name), argv.index(after: index) < argv.endIndex {
                    flags[name] = argv[argv.index(after: index)]
                    index = argv.index(index, offsetBy: 2)
                    continue
                }
                flags[name] = ""
            } else {
                positionals.append(argument)
            }
            index = argv.index(after: index)
        }
        let json = flags["json"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

        if let recording = positionals.first {
            let url = URL(fileURLWithPath: recording)
            if flags["compress"] != nil || flags["full"] != nil || flags["incremental"] != nil {
                try compression(
                    recording: url,
                    repeats: flags["repeats"].flatMap(Int.init) ?? 1,
                    full: flags["full"] != nil,
                    json: json
                )
                return
            }
            let points = (flags["points"] ?? "1,10,50,200")
                .split(separator: ",").compactMap { Int($0) }
            try snapshotCurve(recording: url, repeatCounts: points, json: json)
            return
        }

        try sessions(
            count: flags["sessions"].flatMap(Int.init) ?? 1,
            busy: flags["busy"].flatMap(Int.init) ?? 0,
            seconds: flags["seconds"].flatMap(Double.init) ?? 60,
            json: json,
            fill: flags["fill"].flatMap(Fill.init(rawValue:)) ?? .uniform,
            lines: flags["lines"].flatMap(Int.init) ?? 20_000
        )
    }
}
