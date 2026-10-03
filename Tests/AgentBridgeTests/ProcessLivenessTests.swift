#if os(macOS)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
import TkzPlatform

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

        // Give the kernel a moment to publish the new pid's start time (PROC_PIDTBSDINFO, /proc).
        Thread.sleep(forTimeInterval: 0.05)

        let liveness = SystemProcessLiveness()
        #expect(liveness.isAlive(pid: sleepPid, startedAt: nil))

        // pid-reuse guard: a startedAt an hour in the past does not match the real start time.
        let bogusStart = Date().addingTimeInterval(-3600)
        #expect(!liveness.isAlive(pid: sleepPid, startedAt: bogusStart))

        // …but a descriptor written long *after* the process started is the same process: a
        // `WorktreeCreate` hook delays the write by as long as it runs.
        let lateStamp = try #require(ProcessTable.startTime(of: sleepPid)).addingTimeInterval(300)
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

    // MARK: procStart / pidDomain

    @Test func identityCheckPicksTheGuard() {
        let own = "linux:0123:pid:[4026531836]"
        func check(_ procStart: UInt64?, _ domain: String?, own: String? = own) -> SystemProcessLiveness.IdentityCheck {
            SystemProcessLiveness.identityCheck(procStart: procStart, pidDomain: domain, ownDomain: own)
        }
        #expect(check(1630842, own) == .exact(1630842))
        // Another pid namespace or another machine, with or without a procStart.
        #expect(check(1630842, "linux:0123:pid:[4026532999]") == .foreign)
        #expect(check(nil, "linux:9999:pid:[4026531836]") == .foreign)
        // Not enough to go on: the window.
        #expect(check(nil, own) == .window)
        #expect(check(1630842, nil) == .window)
        #expect(check(1630842, "") == .window)
        // No domain of our own (macOS, or an unreadable machine-id): never foreign, never exact.
        #expect(check(1630842, own, own: nil) == .window)
        #expect(check(1630842, "linux:other:pid:[1]", own: nil) == .window)
    }

    @Test func pidDomainIsSpelledLikeClaudeCode() {
        #expect(SystemProcessLiveness.pidDomain(machineID: "0123abcd\n", pidNamespace: "pid:[4026531836]")
            == "linux:0123abcd:pid:[4026531836]")
        #expect(SystemProcessLiveness.pidDomain(machineID: nil, pidNamespace: "pid:[4026531836]") == nil)
        #expect(SystemProcessLiveness.pidDomain(machineID: "", pidNamespace: "pid:[4026531836]") == nil)
        #expect(SystemProcessLiveness.pidDomain(machineID: "0123", pidNamespace: nil) == nil)
        #expect(SystemProcessLiveness.pidDomain(machineID: "0123", pidNamespace: "net:[4026531840]") == nil)
    }

    #if os(macOS)
    /// The Mac has no pid domain, so a descriptor's `procStart`/`pidDomain` never change the answer.
    @Test func macIgnoresTheIdentityStamp() {
        #expect(SystemProcessLiveness.ownPidDomain == nil)
        let liveness = SystemProcessLiveness()
        #expect(liveness.isAlive(pid: getpid(), startedAt: nil, procStart: 1, pidDomain: "linux:x:pid:[1]"))
    }
    #endif

    #if os(Linux)
    /// This process's domain is read from /etc/machine-id and /proc/self/ns/pid.
    @Test func ownPidDomainNamesThisNamespace() throws {
        let domain = try #require(SystemProcessLiveness.ownPidDomain)
        let namespace = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/ns/pid")
        #expect(domain.hasPrefix("linux:"))
        #expect(domain.hasSuffix(":" + namespace))
    }

    /// The exact guard against a spawned child's real start ticks, read from /proc/<pid>/stat by
    /// hand here rather than through `ProcessTable`: equal ticks are the same process, any other
    /// value is a reused pid, and a foreign domain is never ours — even for a live pid.
    @Test func procStartIsAnExactPidReuseGuard() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let stat = try String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8)
        // Field 22, counted from field 3, the first one after the parenthesised comm.
        let afterComm = try #require(stat.range(of: ")", options: .backwards)).upperBound
        let fields = stat[afterComm...].split(separator: " ")
        let ticks = try #require(UInt64(fields[22 - 3]))
        let own = try #require(SystemProcessLiveness.ownPidDomain)
        let liveness = SystemProcessLiveness()
        // A startedAt an hour off would fail the window; the exact guard does not consult it.
        let wrongStartedAt = Date().addingTimeInterval(-3600)

        #expect(liveness.isAlive(pid: pid, startedAt: wrongStartedAt, procStart: ticks, pidDomain: own))
        #expect(!liveness.isAlive(pid: pid, startedAt: nil, procStart: ticks + 1, pidDomain: own))
        #expect(!liveness.isAlive(pid: pid, startedAt: nil, procStart: ticks - 1, pidDomain: own))
        #expect(!liveness.isAlive(pid: pid, startedAt: nil, procStart: ticks, pidDomain: own + "0"))
        // Without a domain the window decides, as before.
        #expect(liveness.isAlive(pid: pid, startedAt: nil, procStart: ticks + 1, pidDomain: nil))
        #expect(!liveness.isAlive(pid: pid, startedAt: wrongStartedAt, procStart: ticks, pidDomain: nil))

        kill(pid, SIGKILL)
        process.waitUntilExit()
        #expect(!liveness.isAlive(pid: pid, startedAt: nil, procStart: ticks, pidDomain: own))
    }

    /// A descriptor the watcher decodes carries the stamp through to the guard.
    @Test func decodedDescriptorDrivesTheExactGuard() throws {
        let pid = getpid()
        let ticks = try #require(ProcessTable.startTicks(of: pid))
        let own = try #require(SystemProcessLiveness.ownPidDomain)
        func info(_ procStart: String, _ domain: String) throws -> ClaudeSessionInfo {
            let json = #"{"pid":\#(pid),"sessionId":"s","procStart":"\#(procStart)","pidDomain":"\#(domain)"}"#
            return try ClaudeSessionInfo.decode(Data(json.utf8), configDir: "/tmp/.claude")
        }
        let liveness = SystemProcessLiveness()
        for (descriptor, alive) in [
            (try info(String(ticks), own), true),
            (try info(String(ticks + 1), own), false),
            (try info(String(ticks), "linux:distrobox:pid:[4026532999]"), false),
        ] {
            #expect(liveness.isAlive(
                pid: descriptor.pid, startedAt: descriptor.startedAt,
                procStart: descriptor.procStart, pidDomain: descriptor.pidDomain) == alive)
        }
    }
    #endif
}

/// The descendant walk the liveness and ownership callers use, now TkzPlatform's `ProcessTable`
/// (it was AgentBridge's own `ProcessTree` until WOR-306 S3).
@Suite(.serialized)
struct ProcessTableWalkTests {
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
            let kids = ProcessTable.descendants(of: shPid)
            if let found = kids.first(where: { $0 != shPid }) {
                sleepPid = found
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let sleep = try #require(sleepPid)

        #expect(ProcessTable.descendants(of: shPid).contains(sleep))
        #expect(ProcessTable.parent(of: sleep) == shPid)
        #expect(ProcessTable.children(of: getpid()).contains(shPid))

        kill(sleep, SIGKILL)
        kill(shPid, SIGKILL)
        process.waitUntilExit()
    }
}
