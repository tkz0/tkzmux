// UpdateRelaunch — "Restart to update" (TKZ-50).
//
// A detached `/bin/sh` waits for this process to exit, then `open`s the bundle path, and the app
// terminates normally so `applicationWillTerminate` runs: snapshots, SIGHUP to every pty, and a
// synchronous `state.json` flush — the next launch restores the rows and ⌘R (or auto-resume)
// brings Claude back. Why this shape:
//
//   * `Process` children are their own process group and the script holds no pty and no pipe
//     (all three fds are `/dev/null`), so nothing the quitting app signals can reach it; on exit
//     it is reparented to launchd.
//   * plain `open`, never `open -n` (which would start a second instance if the old one were
//     still alive), and never an exec of `Contents/MacOS/tkzmux`: LaunchServices starts the new
//     app under launchd in a fresh coalition and as its own TCC responsible process, which a
//     child exec'd from here would not be.
//   * pid and path travel as `$1`/`$2`, never interpolated into the script.

import AppKit
import Foundation

public struct RelaunchPlan: Equatable, Sendable {
    public var pid: pid_t
    public var bundlePath: String
    /// Rows with a live terminal — what the confirmation counts.
    public var liveSessionCount: Int

    public init(pid: pid_t, bundlePath: String, liveSessionCount: Int) {
        self.pid = pid
        self.bundlePath = bundlePath
        self.liveSessionCount = liveSessionCount
    }

    /// Bounded: 300 × 0.2 s = 60 s, then give up *without* opening.
    public static let script = """
        i=0; while kill -0 "$1" 2>/dev/null; do sleep 0.2; i=$((i+1)); [ "$i" -ge 300 ] && exit 1; done
        exec /usr/bin/open "$2"
        """
}

public enum UpdateRelaunch {
    /// Spawns the waiter. Call *before* `NSApp.terminate`.
    public static func spawn(_ plan: RelaunchPlan) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RelaunchPlan.script, "sh", String(plan.pid), plan.bundlePath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

extension MainWindowController {
    /// The upgrade finished (or the card's fallback "Restart to update" was clicked): count the
    /// live rows for the plan and go. No dialog (decision 2026-09-11): "Update via Homebrew" was
    /// the consent, and the rows survive the restart. `confirmRestartForUpdate` and
    /// `performRelaunch` (stored on the controller next to `confirmRemove`) are the two injection
    /// points the tests use; unset, the relaunch is unconditional and real.
    public func restartForUpdate(installed: String) {
        let live = store.state.sessions.values.filter { $0.live != nil }.count
        let plan = RelaunchPlan(pid: getpid(), bundlePath: Bundle.main.bundlePath, liveSessionCount: live)
        if let confirm = confirmRestartForUpdate, !confirm(plan) { return }
        do {
            if let perform = performRelaunch {
                try perform(plan)
            } else {
                try UpdateRelaunch.spawn(plan)
                NSApp.terminate(nil)
            }
        } catch {
            showNotice("Could not relaunch: \(error.localizedDescription)")
        }
    }
}
