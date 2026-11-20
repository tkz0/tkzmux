import Darwin
import Foundation
import Testing

@testable import GitStatus

/// `GitProcess.run` against `/bin/sh` scripts: what it returns, and — the reason this suite exists —
/// that it returns when the process exits even if something else still holds its stdout.
struct GitProcessTests {
    private func sh(_ script: String, timeout: Double = 5) throws -> GitProcess.Output {
        try GitProcess.run("/bin/sh", ["-c", script], timeout: timeout)
    }

    @Test func capturesOutputErrorAndStatus() throws {
        let output = try sh("echo out; echo err >&2; exit 3")
        #expect(output.standardOutput == "out\n")
        #expect(output.standardError == "err")
        #expect(output.status == 3)
    }

    /// More than the 64 KiB pipe buffer: stdout has to be drained while the process runs, or it
    /// blocks writing and the call times out.
    @Test func drainsOutputLargerThanThePipeBuffer() throws {
        let output = try sh("/usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' x")
        #expect(output.standardOutput.utf8.count == 300_000)
        #expect(output.succeeded)
    }

    @Test func timesOutAndTerminates() throws {
        let start = ContinuousClock.now
        #expect(throws: GitProcess.Failure.timedOut(seconds: 0.3)) {
            try sh("exec /bin/sleep 30", timeout: 0.3)
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// Regression: the process has exited but a longer-lived process still holds its stdout — what
    /// happened when a shell forked by the pty shim inherited a `rev-parse`'s pipe. Waiting for EOF
    /// blocked the app's git queue for as long as that shell lived.
    @Test func returnsWhenTheProcessExitsEvenIfItsStdoutIsStillHeld() throws {
        let start = ContinuousClock.now
        // The backgrounded sleep inherits stdout and keeps it open for 30 s after `sh` exits.
        let output = try sh("echo hi; /bin/sleep 30 & echo $!; exit 0", timeout: 5)
        let elapsed = ContinuousClock.now - start

        let lines = output.standardOutput.split(separator: "\n")
        if let last = lines.last, let pid = pid_t(last) { kill(pid, SIGKILL) }
        #expect(lines.first == "hi")
        #expect(output.succeeded)
        #expect(elapsed < .seconds(3), "waited \(elapsed) — for EOF rather than for the exit")
    }
}
