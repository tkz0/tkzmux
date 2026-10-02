// ProcessExitWatcher (WOR-304 S5): the exit event arrives promptly after `kill`, exactly once, for
// processes that exited before the watch too; the watcher never reaps, so the owner's
// `waitpid(WNOHANG)` in the handler always finds the child. On Linux also: 100 children reaped
// on their exit events leave no zombie in /proc/self/task/*/children, pidfds do not leak over
// 1,000 watch/cancel cycles, and the shim's pidfd_send_signal works.
//
// The latency budget is 50 ms, for CI runners; on the reference machine it is under 5 ms, and the
// test prints the measured times so a local run can be recorded.

import Dispatch
import Foundation
import Synchronization
import Testing
@testable import TkzPlatform

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
import TkzPlatformShim
#endif

extension WatcherTests {
    @Suite struct ProcessExitWatcherTests {
        let queue = DispatchQueue(label: "se.tkz.tkzmux.tests.ProcessExitWatcher")

        @Test func exitArrivesWithinBudgetOfKill() async throws {
            let watcher = SystemProcessExitWatcher(queue: queue)
            var latencies: [UInt64] = []
            for _ in 0..<20 {
                let pid = try spawnChild("/bin/sleep", ["30"])
                let exitedAt = Recorder<UInt64>()
                try watcher.watch(pid: pid) { exitedAt.append(Clocks.monotonicNanos) }
                try await Task.sleep(for: .milliseconds(2))  // let the source arm
                let killedAt = Clocks.monotonicNanos
                #expect(kill(pid, SIGKILL) == 0)
                #expect(await exitedAt.wait { !$0.isEmpty })
                if let at = exitedAt.all.first { latencies.append(at - killedAt) }
                #expect(reapBlocking(pid) == pid)
            }
            latencies.sort()
            let median = Double(latencies[latencies.count / 2]) / 1e6
            let worst = Double(latencies.last ?? 0) / 1e6
            print("ProcessExitWatcher kill → exit event: median \(median) ms, max \(worst) ms over \(latencies.count)")
            #expect(latencies.count == 20)
            #expect(worst < 50)
            #expect(watcher.watchCount == 0)
        }

        @Test func firesOnceAndNeverReaps() async throws {
            let watcher = SystemProcessExitWatcher(queue: queue)
            let pid = try spawnChild("/bin/sh", ["-c", "exit 3"])
            let reaped = Recorder<Int32>()
            try watcher.watch(pid: pid) {
                // The contract: the owner reaps, and the child is still there to reap.
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                reaped.append(result == pid ? (status >> 8) & 0xFF : -1)
            }
            #expect(await reaped.wait { !$0.isEmpty })
            try await Task.sleep(for: .milliseconds(50))
            #expect(reaped.all == [3])
        }

        /// A child that is already a zombie when the watch starts is reported straight away.
        @Test func zombieIsReportedImmediately() async throws {
            let watcher = SystemProcessExitWatcher(queue: queue)
            let pid = try spawnChild("/bin/sh", ["-c", "exit 0"])
            var info = siginfo_t()
            // Waits for the exit but leaves the child unreaped.
            #expect(waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0)
            let fired = Recorder<Bool>()
            try watcher.watch(pid: pid) { fired.append(true) }
            #expect(await fired.wait { !$0.isEmpty })
            #expect(reapBlocking(pid) == pid)
        }

        /// A pid that no longer exists at all (reaped already) counts as exited.
        @Test func reapedProcessIsReportedImmediately() async throws {
            let watcher = SystemProcessExitWatcher(queue: queue)
            let pid = try spawnChild("/bin/sh", ["-c", "exit 0"])
            #expect(reapBlocking(pid) == pid)
            let fired = Recorder<Bool>()
            try watcher.watch(pid: pid) { fired.append(true) }
            #expect(await fired.wait { !$0.isEmpty })
            try await Task.sleep(for: .milliseconds(20))
            #expect(fired.all.count == 1)
        }

        @Test func cancelledWatchNeverFires() async throws {
            let watcher = SystemProcessExitWatcher(queue: queue)
            let pid = try spawnChild("/bin/sleep", ["30"])
            let fired = Recorder<Bool>()
            let id = try watcher.watch(pid: pid) { fired.append(true) }
            #expect(watcher.watchCount == 1)
            watcher.cancel(id)
            #expect(watcher.watchCount == 0)
            #expect(kill(pid, SIGKILL) == 0)
            #expect(reapBlocking(pid) == pid)
            try await Task.sleep(for: .milliseconds(50))
            queue.sync {}
            #expect(fired.all.isEmpty)
        }

        @Test func watchAfterCancelThrows() throws {
            let watcher = SystemProcessExitWatcher(queue: queue)
            watcher.cancel()
            #expect(throws: ProcessExitWatcherError.cancelled) { try watcher.watch(pid: getpid()) {} }
            #expect(throws: ProcessExitWatcherError.system(EINVAL)) {
                try SystemProcessExitWatcher(queue: queue).watch(pid: 0) {}
            }
        }

        #if os(Linux)
        /// Spawn 100 children, reap each one from its own exit event, and check that none of them
        /// is left in /proc/self/task/*/children, as a zombie or otherwise.
        @Test(.timeLimit(.minutes(1))) func hundredChildrenLeaveNoZombies() async throws {
            let watcher = SystemProcessExitWatcher(queue: queue)
            let reaped = Recorder<pid_t>()
            var pids: [pid_t] = []
            for index in 0..<100 {
                // A mix of children that exit at once (often a zombie before the watch starts)
                // and children that exit a little later.
                let pid = try spawnChild("/bin/sh", ["-c", index.isMultiple(of: 2) ? "exit 0" : "sleep 0.05"])
                pids.append(pid)
                try watcher.watch(pid: pid) {
                    var status: Int32 = 0
                    if waitpid(pid, &status, WNOHANG) == pid { reaped.append(pid) }
                }
            }
            #expect(await reaped.wait(timeout: .seconds(20)) { $0.count == 100 })
            #expect(Set(reaped.all) == Set(pids))

            let children = currentChildren()
            let ours = children.intersection(pids)
            #expect(ours.isEmpty, "still children: \(ours.sorted())")
            let zombies = children.filter { processState($0) == "Z" }
            #expect(zombies.isEmpty, "zombie children: \(zombies.sorted())")
            #expect(watcher.watchCount == 0)
        }

        @Test(.timeLimit(.minutes(1))) func pidfdsDoNotLeakOverAThousandCycles() async throws {
            let pid = try spawnChild("/bin/sleep", ["30"])
            defer {
                kill(pid, SIGKILL)
                reapBlocking(pid)
            }
            let before = watcherDescriptorCounts().pidfd
            let watcher = SystemProcessExitWatcher(queue: queue)
            for _ in 0..<1_000 {
                let id = try watcher.watch(pid: pid) {}
                watcher.cancel(id)
            }
            // A thousand more that are dropped with the watcher instead of cancelled one by one.
            do {
                let dropped = SystemProcessExitWatcher(queue: queue)
                for _ in 0..<1_000 { try dropped.watch(pid: pid) {} }
                #expect(dropped.watchCount == 1_000)
            }
            #expect(watcher.watchCount == 0)
            let deadline = ContinuousClock.now + .seconds(5)
            while watcherDescriptorCounts().pidfd != before, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(watcherDescriptorCounts().pidfd == before)
        }

        /// The shim's pidfd_send_signal reaches the process its pidfd names.
        @Test func shimSendsSignalsThroughAPidfd() async throws {
            let pid = try spawnChild("/bin/sleep", ["30"])
            let pidfd = tkz_pidfd_open(pid, 0)
            #expect(pidfd >= 0)
            defer { close(pidfd) }
            #expect(fcntl(pidfd, F_GETFD) & FD_CLOEXEC != 0)

            let watcher = SystemProcessExitWatcher(queue: queue)
            let fired = Recorder<Bool>()
            try watcher.watch(pid: pid) { fired.append(true) }
            // SIGKILL, because a child spawned from the test runner inherits its blocked signals.
            #expect(tkz_pidfd_send_signal(pidfd, SIGKILL, 0) == 0)
            #expect(await fired.wait { !$0.isEmpty })
            var status: Int32 = 0
            #expect(waitpid(pid, &status, 0) == pid)
            #expect(status & 0x7F == SIGKILL)
            // Once reaped, the pidfd still names that process and nothing else.
            #expect(tkz_pidfd_send_signal(pidfd, SIGKILL, 0) == -1)
            #expect(errno == ESRCH)
        }

        @Test func errnoMapping() {
            #expect(ProcessExitWatcherError.pidfdError(errno: ENOSYS) == .unsupported)
            #expect(ProcessExitWatcherError.pidfdError(errno: EMFILE) == .descriptorLimitReached)
            #expect(ProcessExitWatcherError.pidfdError(errno: EINVAL) == .system(EINVAL))
        }
        #endif
    }
}
