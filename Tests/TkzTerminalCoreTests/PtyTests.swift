#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import TkzTerminalCore

#if os(Linux)
import TkzPtyShim
#endif

// MARK: - Helpers

/// Thread-safe collector for everything a `Pty` hands back.
private final class Sink: Sendable {
    private struct Box {
        var data = Data()
        var exit: PtyExit?
    }
    private let box = Mutex(Box())

    func append(_ data: Data) { box.withLock { $0.data.append(data) } }
    func setExit(_ exit: PtyExit) { box.withLock { $0.exit = exit } }

    var text: String { String(decoding: box.withLock { $0.data }, as: UTF8.self) }
    var exit: PtyExit? { box.withLock { $0.exit } }
}

private func makePty(_ spawn: PtySpawn, label: String) throws -> (Pty, Sink) {
    let sink = Sink()
    let queue = DispatchQueue(label: "tkzmux.test.\(label)", qos: .userInitiated)
    let pty = try Pty(
        spawn: spawn,
        ioQueue: queue,
        onData: { sink.append($0) },
        onExit: { sink.setExit($0) }
    )
    return (pty, sink)
}

/// Poll `predicate` until it holds or the deadline passes. Never a fixed sleep.
@discardableResult
private func waitUntil(
    _ timeout: Duration = .seconds(10),
    _ predicate: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

/// Writes happen on the pty's own IO queue, as the API requires.
private func send(_ pty: Pty, _ string: String) {
    pty.ioQueue.async { try? pty.write(Data(string.utf8)) }
}

/// A minimal, hermetic environment: no inherited TERM_PROGRAM, no user rc files worth speaking of.
private func minimalEnvironment(home: String) -> [String: String] {
    var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "TERM": "xterm-ghostty"]
    // Without this an interactive zsh warns about an unknown terminal on a machine that has no
    // system-wide xterm-ghostty, which would pollute the collected output.
    if let terminfo = TerminalEnvironment.bundledTerminfoDirectory { env["TERMINFO"] = terminfo.path }
    return env
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-pty-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func openFileDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}

/// The interactive-shell tests drive zsh. Every Mac has it; a Linux dev box may not, and CI
/// installs it, so there it is a visible skip rather than a failure.
#if os(Linux)
private let zshAvailable = FileManager.default.isExecutableFile(atPath: "/bin/zsh")
#else
private let zshAvailable = true
#endif
private let zshMissing: Comment = "zsh is not installed at /bin/zsh (CI installs it)"

#if os(Linux)
/// Both Linux spawn paths: clone3(CLONE_PIDFD), and the fork() + pidfd_open() fallback.
private let spawnPaths: [UInt32] = [0, TKZ_PTY_SPAWN_FORCE_FORK]

private func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// `/bin/true` on the given spawn path.
private func trueSpawn(flags: UInt32) -> PtySpawn {
    var spawn = PtySpawn(
        executablePath: "/bin/true",
        argv: ["true"],
        environment: ["PATH": "/usr/bin:/bin"],
        size: TerminalSize(rows: 24, cols: 80)
    )
    spawn.shimFlags = flags
    return spawn
}

/// Spawn, wait for the one exit event, drop the Pty. Woken by the event rather than polled, so a
/// thousand cycles stay fast.
private func spawnToExit(
    _ spawn: PtySpawn, queue: DispatchQueue
) async throws -> (exit: PtyExit?, pid: pid_t, pidFD: Int32) {
    let (exits, continuation) = AsyncStream.makeStream(of: PtyExit.self)
    let pty = try Pty(
        spawn: spawn,
        ioQueue: queue,
        onData: { _ in },
        onExit: {
            continuation.yield($0)
            continuation.finish()
        }
    )
    var exit: PtyExit?
    for await e in exits { exit = e }
    return (exit, pty.pid, pty.pidFD)
}
#endif

// MARK: - Tests

@Suite(.serialized)
struct PtyTests {
    /// Acceptance: 40×120 geometry reaches the child, the child owns a real tty, the exit status is
    /// propagated, and nothing is left behind.
    @Test func spawnsWithGeometryAndReportsExitStatus() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (pty, sink) = try makePty(
            PtySpawn(
                executablePath: "/bin/sh",
                argv: ["/bin/sh", "-c", "stty size; tty; exit 3"],
                environment: minimalEnvironment(home: dir.path),
                cwd: dir.path,
                size: TerminalSize(rows: 40, cols: 120, cellWidthPx: 8, cellHeightPx: 17)
            ),
            label: "geometry"
        )
        let pid = pty.pid

        #expect(await waitUntil { sink.exit != nil }, "child never exited")
        #expect(sink.text.contains("40 120"), "stty size reported: \(sink.text)")
        #if os(Linux)
        #expect(sink.text.contains("/dev/pts/"), "tty reported: \(sink.text)")
        #else
        #expect(sink.text.contains("/dev/ttys"), "tty reported: \(sink.text)")
        #endif
        #expect(sink.exit?.exitCode == 3)
        #expect(sink.exit?.signal == nil)
        #expect(pty.hasExited)

        // A zombie still answers kill(pid, 0); only ESRCH proves it was reaped.
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "child \(pid) was not reaped")
        _ = pty
    }

    /// Acceptance: TIOCSWINSZ reaches a running shell.
    @Test(.enabled(if: zshAvailable, zshMissing))
    func resizeIsVisibleToTheShell() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (pty, sink) = try makePty(
            PtySpawn(
                executablePath: "/bin/zsh",
                argv: ["zsh", "-f", "-i"],
                environment: minimalEnvironment(home: dir.path),
                cwd: dir.path,
                size: TerminalSize(rows: 24, cols: 80)
            ),
            label: "resize"
        )
        defer { pty.terminate(signal: SIGKILL) }

        #expect(await waitUntil { !sink.text.isEmpty }, "shell produced no prompt")
        try pty.resize(TerminalSize(rows: 50, cols: 100, cellWidthPx: 8, cellHeightPx: 17))
        #expect(pty.size == TerminalSize(rows: 50, cols: 100, cellWidthPx: 8, cellHeightPx: 17))

        send(pty, "stty size > size.txt\r")
        // Read via a file, not the echoing tty: the echoed command line is not the answer.
        // The redirect creates the file before stty writes to it, so wait for a complete line.
        let path = dir.appending(path: "size.txt").path
        #expect(
            await waitUntil {
                ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").contains("\n")
            },
            "stty never wrote a size"
        )
        let reported = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(reported == "50 100", "stty size after resize: \(reported ?? "nil")")

        send(pty, "exit\r")
        #expect(await waitUntil { sink.exit != nil })
    }

    /// Acceptance: the foreground job of the pty is visible without any shell integration — which is
    /// also the observable proof that job control works (the child runs in its *own* process group).
    @Test(.enabled(if: zshAvailable, zshMissing))
    func foregroundProcessTracksTheRunningJob() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (pty, sink) = try makePty(
            PtySpawn(
                executablePath: "/bin/zsh",
                argv: ["zsh", "-f", "-i"],
                environment: minimalEnvironment(home: dir.path),
                cwd: dir.path,
                size: TerminalSize(rows: 24, cols: 80)
            ),
            label: "foreground"
        )
        defer { pty.terminate(signal: SIGKILL) }
        let shellPid = pty.pid

        #expect(await waitUntil { !sink.text.isEmpty }, "shell produced no prompt")
        // At the prompt the shell itself is the foreground group.
        #expect(await waitUntil { pty.foregroundProcess()?.pgid == shellPid })

        #if os(Linux)
        // /proc/<pid>/exe is the resolved path, and /bin is a symlink on a merged-/usr system.
        let sleepPath = realPath("/bin/sleep")
        #else
        let sleepPath = "/bin/sleep"
        #endif
        send(pty, "/bin/sleep 5\r")
        #expect(
            await waitUntil { pty.foregroundProcess()?.executablePath == sleepPath },
            "foreground never became sleep: \(String(describing: pty.foregroundProcess()))"
        )
        let fg = try #require(pty.foregroundProcess())
        #expect(fg.pgid > 0)
        // Job control: the job is in a different process group than the shell.
        #expect(fg.pgid != shellPid)
        #expect(fg.executablePath == sleepPath)
        let expected = URL(fileURLWithPath: dir.path).resolvingSymlinksInPath().path
        let actual = URL(fileURLWithPath: fg.currentDirectory ?? "").resolvingSymlinksInPath().path
        #expect(actual == expected, "cwd of the job: \(actual)")

        kill(fg.pgid, SIGKILL)  // don't orphan `sleep` past the end of the test
        pty.terminate(signal: SIGKILL)
        #expect(await waitUntil { sink.exit != nil }, "shell never exited after SIGKILL")
        #expect(sink.exit?.signal == SIGKILL)
        #expect(kill(shellPid, 0) == -1 && errno == ESRCH)
    }

    /// Acceptance: a bad executable surfaces as ENOENT, promptly, with no fd or process left over.
    @Test func execFailureReportsErrnoWithoutLeaking() async throws {
        let before = openFileDescriptorCount()
        // 256 rather than 8 iterations: the check below is a *process-wide* fd count, so it
        // competes with every test running in parallel. Making the leak *signal* larger, rather
        // than the tolerance looser, is what keeps a one-fd-per-spawn leak detectable. Widened
        // twice for exactly that reason — first for M5.1's `state.json` tests, then for M4's
        // `GitStatusTests`, which spawn `git` and `gh` (two pipes each) and open `FSEventStream`s,
        // and which pushed the observed concurrent-fd noise from single digits to 20–41.
        let iterations = 256
        for _ in 0..<iterations {
            #expect(throws: PtyError.spawnFailed(code: ENOENT)) {
                _ = try Pty(
                    spawn: PtySpawn(
                        executablePath: "/nonexistent/tkzmux/definitely-not-here",
                        argv: ["definitely-not-here"],
                        environment: ["PATH": "/usr/bin:/bin"],
                        cwd: nil,
                        size: TerminalSize(rows: 24, cols: 80)
                    ),
                    ioQueue: DispatchQueue(label: "tkzmux.test.enoent"),
                    onData: { _ in },
                    onExit: { _ in }
                )
            }
        }
        let after = openFileDescriptorCount()
        // A real leak is at least one fd per iteration, i.e. ≥256; the tolerance sits far above the
        // measured noise and far below the leak signal, so neither a busy suite nor a real leak is
        // ambiguous.
        #expect(
            after - before < iterations / 2,
            "fd count went \(before) → \(after) over \(iterations) failed spawns")
        // The failed child is reaped inside the shim, so there is nothing left to wait for here
        // (a waitpid(-1) probe would steal another test's child).
    }

    /// Large writes exercise the EAGAIN → pending-buffer → write-source path. The payload is split
    /// into short lines because a tty in canonical mode only accepts ~1 KiB per line (MAX_INPUT).
    @Test func writesLargerThanThePtyBufferAreDrained() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (pty, sink) = try makePty(
            PtySpawn(
                executablePath: "/bin/cat",
                argv: ["cat"],
                environment: minimalEnvironment(home: dir.path),
                cwd: dir.path,
                size: TerminalSize(rows: 24, cols: 80)
            ),
            label: "write"
        )
        defer { pty.terminate(signal: SIGKILL) }

        let lines = 800
        let lineLength = 60
        let payload = String(repeating: String(repeating: "z", count: lineLength) + "\r", count: lines)
        #expect(payload.utf8.count > 48000)
        send(pty, payload)

        // cat echoes the bytes back (the tty echoes them a second time); the first full copy is proof.
        let expected = lines * lineLength
        #expect(
            await waitUntil(.seconds(30)) { sink.text.filter { $0 == "z" }.count >= expected },
            "only \(sink.text.filter { $0 == "z" }.count) of \(expected) bytes came back"
        )
        #expect(pty.didQueuePendingWrite, "the write never hit EAGAIN, so the pending path is untested")

        pty.terminate(signal: SIGKILL)
        #expect(await waitUntil { sink.exit != nil })
    }

    #if os(Linux)
    /// A child that is gone before the exit source is even resumed is still reaped (the pidfd is
    /// readable from the start, and the one-shot poll after resume covers it too).
    @Test(.timeLimit(.minutes(1)), arguments: spawnPaths)
    func childThatExitsImmediatelyIsReaped(flags: UInt32) async throws {
        let result = try await spawnToExit(trueSpawn(flags: flags), queue: DispatchQueue(label: "tkzmux.test.true"))
        #expect(result.pidFD >= 0, "the shim returned no pidfd")
        #expect(result.exit?.exitCode == 0)
        #expect(kill(result.pid, 0) == -1 && errno == ESRCH, "child \(result.pid) was not reaped")
    }

    /// The exit is reported through the pidfd, not the hangup: a background job that ignores SIGHUP
    /// keeps the slave open, so the master never reads EOF while it lives. Without the pidfd source
    /// the exit would wait for the holder (60 s); the `sleep 0.2` puts the exit after the one-shot
    /// poll that follows resume().
    @Test(.timeLimit(.minutes(1)), arguments: spawnPaths)
    func exitArrivesThroughThePidfdWhileTheSlaveIsHeldOpen(flags: UInt32) async throws {
        var spawn = PtySpawn(
            executablePath: "/bin/sh",
            argv: ["/bin/sh", "-c", "(trap '' HUP; exec sleep 60) & echo \"holder=$!\"; sleep 0.2; exit 7"],
            environment: ["PATH": "/usr/bin:/bin"],
            size: TerminalSize(rows: 24, cols: 80)
        )
        spawn.shimFlags = flags
        let (pty, sink) = try makePty(spawn, label: "pidfd")
        #expect(pty.pidFD >= 0, "the shim returned no pidfd")

        #expect(await waitUntil(.seconds(10)) { sink.exit != nil }, "exit never arrived: \(sink.text)")
        let holder = try #require(
            sink.text.split(whereSeparator: \.isNewline)
                .first { $0.hasPrefix("holder=") }
                .flatMap { pid_t($0.dropFirst("holder=".count).trimmingCharacters(in: .whitespaces)) },
            "no holder pid in: \(sink.text)"
        )
        defer { kill(holder, SIGKILL) }
        #expect(kill(holder, 0) == 0, "the holder was gone, so this proves nothing about the pidfd")
        #expect(sink.exit?.exitCode == 7)
        #expect(kill(pty.pid, 0) == -1 && errno == ESRCH, "child \(pty.pid) was not reaped")
    }

    /// 1000 spawn/exit cycles per spawn path leave no fd behind: not the master, not the pidfd
    /// (closed by the exit source's cancel handler), not the shim's error pipe. The tolerance has the
    /// same reasoning as `execFailureReportsErrnoWithoutLeaking`: the count is process-wide, and a
    /// leak of one fd per cycle is twice the tolerance.
    @Test(.timeLimit(.minutes(2)), arguments: spawnPaths)
    func spawnExitCyclesLeakNoDescriptors(flags: UInt32) async throws {
        let queue = DispatchQueue(label: "tkzmux.test.cycles")
        let iterations = 1000
        let before = openFileDescriptorCount()
        var failures = 0
        var noPidfd = 0
        var lastPid: pid_t = 0
        for _ in 0..<iterations {
            let result = try await spawnToExit(trueSpawn(flags: flags), queue: queue)
            if result.exit?.exitCode != 0 { failures += 1 }
            if result.pidFD < 0 { noPidfd += 1 }
            lastPid = result.pid
        }
        // The cancel handlers that close the last master and pidfd run on `queue` after the exit.
        queue.sync {}
        let after = openFileDescriptorCount()

        #expect(failures == 0, "\(failures) of \(iterations) cycles did not exit 0")
        #expect(noPidfd == 0, "\(noPidfd) of \(iterations) spawns had no pidfd")
        #expect(
            after - before < iterations / 2,
            "fd count went \(before) → \(after) over \(iterations) spawn/exit cycles")
        #expect(kill(lastPid, 0) == -1 && errno == ESRCH, "child \(lastPid) was not reaped")
    }

    /// glibc (2.44) makes sigaction(SIGABRT) take its abort lock, which posix_spawn() holds for
    /// reading while it clones. A raw clone3() child inherits that lock in whatever state another
    /// thread left it, so the child resets its signals with bare system calls. With the glibc
    /// wrappers, a pane spawn racing any posix_spawn (Foundation's Process, `git` from GitStatus)
    /// hung the child before exec, and the spawn with it; this reproduced it within 300 spawns.
    @Test(.timeLimit(.minutes(1)), arguments: spawnPaths)
    func spawnsWhileAnotherThreadPosixSpawns(flags: UInt32) async throws {
        let stop = Mutex(false)
        let hammer = Thread {
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup("true"), nil]
            defer { free(argv[0]) }
            while !stop.withLock({ $0 }) {
                var pid: pid_t = 0
                guard posix_spawn(&pid, "/bin/true", nil, nil, argv, nil) == 0 else { continue }
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        hammer.start()
        defer { stop.withLock { $0 = true } }

        let queue = DispatchQueue(label: "tkzmux.test.posix-spawn")
        var failures = 0
        for _ in 0..<300 {
            let result = try await spawnToExit(trueSpawn(flags: flags), queue: queue)
            if result.exit?.exitCode != 0 { failures += 1 }
        }
        #expect(failures == 0, "\(failures) of 300 spawns did not exit 0")
    }
    #endif
}
