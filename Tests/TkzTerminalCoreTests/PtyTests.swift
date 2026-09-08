import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import TkzTerminalCore

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
        #expect(sink.text.contains("/dev/ttys"), "tty reported: \(sink.text)")
        #expect(sink.exit?.exitCode == 3)
        #expect(sink.exit?.signal == nil)
        #expect(pty.hasExited)

        // A zombie still answers kill(pid, 0); only ESRCH proves it was reaped.
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "child \(pid) was not reaped")
        _ = pty
    }

    /// Acceptance (M2.5 / TKZ-43): a command handed to `writeWhenReady` reaches a login zsh and
    /// **runs**, rather than being discarded before the shell ever sees it.
    ///
    /// The failure this guards against (measured in M1.10) is that a login zsh calls
    /// `tcsetattr(…, TCSAFLUSH, …)` while it brings up its line editor, which discards whatever is
    /// already sitting in the tty's input queue — a command written in the same turn as the spawn
    /// is silently swallowed.
    ///
    /// **The mirror-image control is deliberately not asserted.** It was tried: writing the same
    /// command straight after the spawn, in this hermetic single-session setup, reliably *runs*
    /// (three marker occurrences, three runs out of three) — so the M1.10 loss is not a property
    /// of every spawn, and a `#expect` on it would be a flaky claim about someone else's timing.
    /// M1.10 measured it at 30 simultaneous spawns under the full tkzmux environment; what is
    /// reproducible here is the positive, which is also what the app depends on.
    ///
    /// Asserted by counting: the marker must appear **twice** — once as the tty's echo of the
    /// typed line, once as the command's own output. A line typed but never run appears once.
    @Test func deferredWritesReachTheShellAndRun() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var environment = minimalEnvironment(home: dir.path)
        // An empty ZDOTDIR: zsh finds no rc files, so nothing the developer has configured can
        // change what this shell prints or when.
        environment["ZDOTDIR"] = dir.path

        let (pty, sink) = try makePty(
            PtySpawn(
                executablePath: TerminalEnvironment.shellPath,
                argv: TerminalEnvironment.shellArgv,
                environment: environment,
                cwd: dir.path,
                size: TerminalSize(rows: 40, cols: 120, cellWidthPx: 8, cellHeightPx: 17)
            ),
            label: "deferred-write"
        )
        defer { _ = pty.terminate(signal: SIGKILL) }

        pty.writeWhenReady(Data("echo TKZMUX-DEFERRED\r".utf8))

        let ran = await waitUntil {
            sink.text.components(separatedBy: "TKZMUX-DEFERRED").count - 1 >= 2
        }
        #expect(ran, "the deferred command was never executed by the shell: \(sink.text)")
    }

    /// A child that prints nothing before it reads still gets the write, via the outer timeout.
    @Test func deferredWritesFallBackToTheTimeout() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (pty, sink) = try makePty(
            PtySpawn(
                executablePath: "/bin/sh",
                argv: ["/bin/sh", "-c", "read line; echo GOT:$line"],
                environment: minimalEnvironment(home: dir.path),
                cwd: dir.path,
                size: TerminalSize(rows: 40, cols: 120)
            ),
            label: "deferred-timeout"
        )
        defer { _ = pty.terminate(signal: SIGKILL) }

        pty.writeWhenReady(
            Data("hello\r".utf8), settle: .milliseconds(50), timeout: .milliseconds(300))

        #expect(await waitUntil { sink.text.contains("GOT:hello") }, "timeout never fired: \(sink.text)")
    }

    /// Acceptance: TIOCSWINSZ reaches a running shell.
    @Test func resizeIsVisibleToTheShell() async throws {
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
    @Test func foregroundProcessTracksTheRunningJob() async throws {
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

        send(pty, "/bin/sleep 5\r")
        #expect(
            await waitUntil { pty.foregroundProcess()?.executablePath == "/bin/sleep" },
            "foreground never became sleep: \(String(describing: pty.foregroundProcess()))"
        )
        let fg = try #require(pty.foregroundProcess())
        #expect(fg.pgid > 0)
        // Job control: the job is in a different process group than the shell.
        #expect(fg.pgid != shellPid)
        #expect(fg.executablePath == "/bin/sleep")
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
        for _ in 0..<8 {
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
        // A real leak would be at least one master + one pipe end per iteration; the small slack
        // absorbs fds that other tests in this process open concurrently.
        #expect(after - before < 8, "fd count went \(before) → \(after) over 8 failed spawns")
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
}
