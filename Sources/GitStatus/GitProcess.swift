// GitProcess — the one place this module runs a subprocess (M4.1).
//
// Every git call the app makes is a **background** call that runs
// while Claude may be running its own git in the same repo. So all of them go through here, and
// here sets the four things that make a background call harmless:
//
//   * `--no-optional-locks` *and* `GIT_OPTIONAL_LOCKS=0` — belt and braces, because the flag only
//     covers the commands that read it and the variable covers the ones that do not. Without this
//     `git status` refreshes the index and takes `index.lock`, which is exactly the race that would
//     make the user's own `git commit` fail with "another git process seems to be running".
//   * `GIT_PAGER=cat` / `PAGER=cat` — a pager waiting for a tty is a background call that never
//     returns.
//   * `GIT_TERMINAL_PROMPT=0` — credentials must never be asked for; a prompt would hang.
//   * a timeout — a repo on a stalled network mount must cost one abandoned process, not a queue.
//
// Synchronous by design: callers are already on their own serial queue (`GitStatusService` runs one
// per repo root) and a synchronous call is what makes "one in flight per repo, coalesced" true
// without any further machinery.

import Foundation

/// Runs `git` (or another tool, e.g. `gh`) with an environment that cannot block, cannot prompt and
/// cannot take a lock.
public enum GitProcess {
    /// What a finished process produced. A non-zero `status` is *not* an error here: several call
    /// sites treat "git said no" as data (not a repo, no upstream, no origin).
    public struct Output: Equatable, Sendable {
        public var status: Int32
        public var standardOutput: String
        public var standardError: String

        public init(status: Int32, standardOutput: String, standardError: String) {
            self.status = status
            self.standardOutput = standardOutput
            self.standardError = standardError
        }

        public var succeeded: Bool { status == 0 }
        /// stdout with trailing newlines removed — what every single-value `git` query wants.
        public var trimmedOutput: String {
            standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case launchFailed(String)
        /// The process outlived `timeout` and was terminated.
        case timedOut(seconds: Double)
    }

    /// Default executable paths. Overridable per call so tests can point at a stub script.
    public static let gitPath = "/usr/bin/git"

    /// The environment every background tool call runs under: the process environment plus the
    /// no-lock / no-pager / no-prompt overrides.
    public static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var env = base
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        // An *empty* askpass beats an unset one: unset falls through to whatever helper the user
        // configured (a GUI keychain prompt), empty fails immediately, which is what a background
        // call wants.
        env["GIT_ASKPASS"] = ""
        env["LC_ALL"] = "C"               // porcelain is stable, but messages and numbers are not.
        for (key, value) in overrides { env[key] = value }
        return env
    }

    /// Runs `executable arguments…`, returning what it printed. Blocks the calling thread until the
    /// process exits or `timeout` elapses; **never** call it on the main actor.
    ///
    /// stdin is `/dev/null`, so anything that would read from a tty gets EOF instead of hanging.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: String? = nil,
        environment overrides: [String: String] = [:],
        timeout: Double = 5
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment(overrides: overrides)
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(String(describing: error))
        }

        // **Drain stdout on this thread, stderr after the exit.** The obvious shape — one
        // background reader per pipe plus `waitUntilExit` — costs two libdispatch threads per call
        // on top of the blocked caller, and libdispatch's pool is finite: with several repos
        // refreshing at once (and, sharply, with a parallel test run) the pool starves, the reads
        // never get scheduled and every call hits its timeout. One kqueue on this thread watches
        // both the pipe and the process, so the call needs no other thread at all.
        //
        // **The process exiting ends the call, not EOF.** EOF only arrives once *every* copy of
        // the pipe's write end is closed, and a copy can outlive git: any fork elsewhere in the
        // app while this pipe is open (Foundation's pipes are not FD_CLOEXEC) hands one to a
        // child that may live for hours. That is what blocked the git queue at launch — a login
        // shell inherited a `rev-parse`'s stdout and every later git call queued behind it.
        // TkzPtyShim now closes foreign fds in its children; this keeps the next leak to one call.
        //
        // Reading stderr only afterwards is safe for what this module runs: git and `gh` write at
        // most a line or two there, far inside the 64 KiB pipe buffer, so it cannot fill and block
        // the child while we drain stdout. A tool that streams to stderr would need it watched too.
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        setNonBlocking(outFD)
        setNonBlocking(errFD)

        var outputData = Data()
        let finished = wait(for: process, draining: outFD, into: &outputData, timeout: timeout)
        // Whatever the process wrote before it exited is still in the pipes.
        drain(outFD, into: &outputData)
        var errorData = Data()
        drain(errFD, into: &errorData)

        guard finished else { throw Failure.timedOut(seconds: timeout) }
        // The kernel has reported the exit; this only waits for Foundation to record the status.
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// How long a process that was sent SIGTERM at the deadline gets to exit before the call
    /// gives up on it. Past this the process is abandoned, not waited for.
    static let terminationGrace: Double = 1

    /// Blocks until `process` exits, draining `fd` into `data` as it becomes readable. At
    /// `timeout` the process is terminated; returns `false` if that was needed (it timed out),
    /// `true` if it exited on its own.
    private static func wait(
        for process: Process, draining fd: Int32, into data: inout Data, timeout: Double
    ) -> Bool {
        let kq = kqueue()
        guard kq >= 0 else {
            process.terminate()
            return false
        }
        defer { close(kq) }

        var exited = false
        var change = kevent(
            ident: UInt(process.processIdentifier), filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        // ESRCH: gone before we could watch it — it has exited already.
        if kevent(kq, &change, 1, nil, 0, nil) < 0 { exited = true }
        change = kevent(
            ident: UInt(fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD),
            fflags: 0, data: 0, udata: nil)
        var readWatched = kevent(kq, &change, 1, nil, 0, nil) == 0

        var killed = false
        var deadline = DispatchTime.now().uptimeNanoseconds + nanoseconds(timeout)
        var events = Array(
            repeating: kevent(ident: 0, filter: 0, flags: 0, fflags: 0, data: 0, udata: nil), count: 2)
        while !exited {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                if killed { return false }          // did not even die in the grace period
                process.terminate()
                killed = true
                deadline = now + nanoseconds(terminationGrace)
                continue
            }
            let remaining = deadline - now
            var wait = timespec(
                tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
            let count = kevent(kq, nil, 0, &events, Int32(events.count), &wait)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            for event in events.prefix(Int(count)) {
                if event.filter == Int16(EVFILT_PROC) {
                    exited = true
                } else if event.filter == Int16(EVFILT_READ), drain(fd, into: &data), readWatched {
                    // EOF stays readable; stop watching it or the loop spins until the exit lands.
                    change = kevent(
                        ident: UInt(fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_DELETE),
                        fflags: 0, data: 0, udata: nil)
                    _ = kevent(kq, &change, 1, nil, 0, nil)
                    readWatched = false
                }
            }
        }
        return exited && !killed
    }

    /// Reads everything `fd` (non-blocking) has right now. `true` at EOF or on an error that
    /// will not go away; `false` when the pipe is merely empty for the moment.
    @discardableResult
    private static func drain(_ fd: Int32, into data: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return true
            } else if errno == EINTR {
                continue
            } else {
                return errno != EAGAIN
            }
        }
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    private static func nanoseconds(_ seconds: Double) -> UInt64 {
        UInt64(max(seconds, 0) * 1_000_000_000)
    }

    /// `git -C <directory> --no-optional-locks <arguments…>`.
    public static func git(
        _ arguments: [String],
        in directory: String,
        gitPath: String = GitProcess.gitPath,
        timeout: Double = 5
    ) throws -> Output {
        try run(gitPath, ["-C", directory, "--no-optional-locks"] + arguments, timeout: timeout)
    }
}
