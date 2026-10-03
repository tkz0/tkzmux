// `tkzmux --main-loop-check` (hidden, WOR-314 S1): proves, in this binary, that the main actor
// and libdispatch's main queue run on the thread that iterates the default GMainContext.
//
// Headless: GLib only, no `gtk_init`, no display. The process main thread attaches the
// main-queue GSource (TkzGtkShell's MainQueueBridge) and iterates the context the way
// `g_application_run` will, then reports, one line each:
//
//   fired <primitive> main-thread|other-thread   a @MainActor Task, Task.sleep, a DispatchSource
//                                                on .main and a main-queue DispatchSourceTimer
//   drains <n>                                   GSource dispatches while those ran (a spin shows
//                                                as thousands)
//   latency posts=<n> p50-us=<x> p99-us=<x> max-us=<x> off-thread=<n>
//                                                10,000 DispatchQueue.main.async posts from a
//                                                background queue, post to run
//   idle drains=<n> ms=<n>                       dispatches with nothing posted
//   main-loop-check ok|failed
//
// Exits 0 when every primitive fired on the main thread, every post ran there, the drain count
// stayed small and the idle window saw no dispatch; 1 otherwise. Latency is reported, not gated
// here: TkzGtkShellTests holds it to p99 < 1 ms.

import Dispatch
import Glibc
import TkzGtkShell

@MainActor
enum MainLoopCheck {
    static let primitives = ["task", "task-sleep", "dispatch-source", "dispatch-timer"]
    static let posts = 10_000
    static let idleMilliseconds: UInt32 = 500
    /// Far above the handful a correct drain needs (7 in WOR-300 S2) and far below a spin.
    static let maxDrains: UInt64 = 200

    static func run() -> Int32 {
        MainQueueBridge.attach()
        let probe = Probe()
        var ok = true

        // The four primitives.
        let before = MainQueueBridge.dispatchCount
        probe.start()
        let fired = MainQueueBridge.iterate(timeoutMilliseconds: 5_000) { probe.fired.count == primitives.count }
        let drains = MainQueueBridge.dispatchCount - before
        for name in primitives {
            switch probe.fired[name] {
            case true?: print("fired \(name) main-thread")
            case false?: print("fired \(name) other-thread"); ok = false
            case nil: print("missing \(name)"); ok = false
            }
        }
        ok = ok && fired
        print("drains \(drains)")
        ok = ok && drains <= maxDrains

        // Main-queue latency.
        probe.startPosting(posts)
        let posted = MainQueueBridge.iterate(timeoutMilliseconds: 30_000) { probe.latencies.count == posts }
        let sorted = probe.latencies.sorted()
        func microseconds(_ quantile: Double) -> String {
            guard !sorted.isEmpty else { return "nan" }
            let nanoseconds = sorted[Int(Double(sorted.count - 1) * quantile)]
            return String(Double(nanoseconds) / 1_000)
        }
        print("latency posts=\(sorted.count) p50-us=\(microseconds(0.5)) p99-us=\(microseconds(0.99)) "
              + "max-us=\(microseconds(1)) off-thread=\(probe.offThreadPosts)")
        ok = ok && posted && probe.offThreadPosts == 0

        // Idle: nothing posted, nothing drained.
        let idleBefore = MainQueueBridge.dispatchCount
        _ = MainQueueBridge.iterate(timeoutMilliseconds: idleMilliseconds) { false }
        let idle = MainQueueBridge.dispatchCount - idleBefore
        print("idle drains=\(idle) ms=\(idleMilliseconds)")
        ok = ok && idle == 0

        print("main-loop-check \(ok ? "ok" : "failed")")
        return ok ? 0 : 1
    }

    /// State the primitives write, all on the main actor.
    @MainActor
    final class Probe {
        let mainThread = pthread_self()
        var fired: [String: Bool] = [:]
        var latencies: [UInt64] = []
        var offThreadPosts = 0
        /// Unretained sources are deallocated and never fire on Linux (WOR-300 S2).
        var sources: [any DispatchSourceProtocol] = []

        var onMainThread: Bool { pthread_equal(pthread_self(), mainThread) != 0 }

        func record(_ name: String) { fired[name] = onMainThread }

        func start() {
            Task { @MainActor in self.record("task") }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                self.record("task-sleep")
            }

            let source = DispatchSource.makeUserDataAddSource(queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { self.record("dispatch-source") } }
            source.resume()
            source.add(data: 1)
            sources.append(source)

            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(30))
            timer.setEventHandler { MainActor.assumeIsolated { self.record("dispatch-timer") } }
            timer.resume()
            sources.append(timer)
        }

        /// Posts `count` blocks to the main queue from a background queue, one at a time, each
        /// timed from just before its post to the start of its run.
        func startPosting(_ count: Int) {
            latencies.reserveCapacity(count)
            DispatchQueue(label: "tkzmux.main-loop-check.poster").async {
                let ran = DispatchSemaphore(value: 0)
                for _ in 0..<count {
                    let posted = DispatchTime.now().uptimeNanoseconds
                    DispatchQueue.main.async {
                        let latency = DispatchTime.now().uptimeNanoseconds - posted
                        MainActor.assumeIsolated {
                            self.latencies.append(latency)
                            if !self.onMainThread { self.offThreadPosts += 1 }
                        }
                        ran.signal()
                    }
                    ran.wait()
                }
            }
        }
    }
}
