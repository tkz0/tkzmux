// GitProcess — the one place this module runs a subprocess (M4.1 / TKZ-26).
//
// design.md → *Git integration*: every git call the app makes is a **background** call that runs
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
import Synchronization

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

        // **Read stdout on this thread, stderr after the exit.** The obvious shape — one
        // background reader per pipe plus `waitUntilExit` — costs two libdispatch threads per call
        // on top of the blocked caller, and libdispatch's pool is finite: with several repos
        // refreshing at once (and, sharply, with a parallel test run) the pool starves, the reads
        // never get scheduled and every call hits its timeout. Draining stdout here needs no thread
        // at all, and reaching EOF *is* the process finishing.
        //
        // Reading stderr only afterwards is safe for what this module runs: git and `gh` write at
        // most a line or two there, far inside the 64 KiB pipe buffer, so it cannot fill and block
        // the child while we drain stdout. A tool that streams to stderr would need the two-reader
        // shape back.
        let killed = Mutex(false)
        let timer = DispatchWorkItem {
            guard process.isRunning else { return }
            killed.withLock { $0 = true }
            process.terminate()
        }
        Self.timerQueue.asyncAfter(deadline: .now() + timeout, execute: timer)

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

        if killed.withLock({ $0 }) { throw Failure.timedOut(seconds: timeout) }
        return Output(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One queue for every call's timeout, rather than `DispatchQueue.global()`: the timers are the
    /// only asynchronous work left here, and they cost one thread in total instead of one per call.
    private static let timerQueue = DispatchQueue(label: "se.tkz.tkzmux.GitProcess.timeout")

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
