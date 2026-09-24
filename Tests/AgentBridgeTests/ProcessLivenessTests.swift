import Foundation
import Testing

@testable import AgentBridge

@Suite(.serialized)
struct ProcessLivenessTests {
    @Test func systemLivenessSelfIsAlive() {
        let liveness = SystemProcessLiveness()
        #expect(liveness.isAlive(pid: getpid(), startedAt: nil))
    }

    @Test func realProcessLivenessAndReuseGuard() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let sleepPid = process.processIdentifier
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }

        // Give the kernel a moment to publish PROC_PIDTBSDINFO for the new pid.
        Thread.sleep(forTimeInterval: 0.05)

        let liveness = SystemProcessLiveness()
        #expect(liveness.isAlive(pid: sleepPid, startedAt: nil))

        // pid-reuse guard: a startedAt an hour in the past does not match the real start time.
        let bogusStart = Date().addingTimeInterval(-3600)
        #expect(!liveness.isAlive(pid: sleepPid, startedAt: bogusStart))

        // …but a descriptor written long *after* the process started is the same process: a
        // `WorktreeCreate` hook delays the write by as long as it runs.
        let lateStamp = try #require(ProcessTree.startTime(of: sleepPid)).addingTimeInterval(300)
        #expect(liveness.isAlive(pid: sleepPid, startedAt: lateStamp))

        // kill -9 and wait for exit.
        kill(sleepPid, SIGKILL)
        process.waitUntilExit()

        let deadline = Date().addingTimeInterval(1)
        var alive = true
        while Date() < deadline {
            alive = liveness.isAlive(pid: sleepPid, startedAt: nil)
            if !alive { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(!alive)
    }

    @Test func startTimeGuardIsOneSided() {
        let process = Date(timeIntervalSince1970: 1_790_237_820)
        func matches(descriptorAfterProcess seconds: TimeInterval) -> Bool {
            SystemProcessLiveness.startTimeMatches(
                actualStart: process, descriptorStartedAt: process.addingTimeInterval(seconds))
        }
        #expect(matches(descriptorAfterProcess: 0))
        // The aira `claude -w` case: its WorktreeCreate hook ran 31.5 s before the descriptor.
        #expect(matches(descriptorAfterProcess: 31.5))
        #expect(matches(descriptorAfterProcess: 15 * 60))
        // A process that started after the descriptor was written: slack, then pid reuse.
        #expect(matches(descriptorAfterProcess: -29))
        #expect(!matches(descriptorAfterProcess: -31))
    }

    @Test func deadPidIsNotAlive() {
        // A pid vanishingly unlikely to be in use; kill(pid, 0) should report ESRCH.
        let liveness = SystemProcessLiveness()
        #expect(!liveness.isAlive(pid: 999_999, startedAt: nil))
    }
}

@Suite(.serialized)
struct ProcessTreeTests {
    @Test func childrenAndDescendantsAndParent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A trailing no-op after `sleep 30` defeats the shell's tail-call exec optimization (a
        // bare `sh -c 'sleep 30'` execs sleep *in place of* sh, leaving no distinct child pid), so
        // this genuinely forks sleep as a child of sh.
        process.arguments = ["-c", "sleep 30; true"]
        try process.run()
        let shPid = process.processIdentifier
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }

        var sleepPid: pid_t?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let kids = ProcessTree.descendants(of: shPid)
            if let found = kids.first(where: { $0 != shPid }) {
                sleepPid = found
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let sleep = try #require(sleepPid)

        #expect(ProcessTree.descendants(of: shPid).contains(sleep))
        #expect(ProcessTree.parent(of: sleep) == shPid)
        #expect(ProcessTree.children(of: getpid()).contains(shPid))

        kill(sleep, SIGKILL)
        kill(shPid, SIGKILL)
        process.waitUntilExit()
    }
}
