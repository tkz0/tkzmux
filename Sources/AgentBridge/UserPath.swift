// UserPath — the `PATH` tkzmux answers "is this agent installed?" against.
//
// **The bug this file exists to fix.** `AgentAdapter.isInstalled(path:)` defaults to the *app
// process's* `PATH`, and a `.app` launched from Finder or the Dock inherits launchd's, not the
// user's shell's. On a machine with no `launchctl setenv PATH` that is exactly:
//
//     PATH=/usr/bin:/bin:/usr/sbin:/sbin
//
// Every agent tkzmux supports installs somewhere else — `~/.local/bin`, `/opt/homebrew/bin`, an
// nvm prefix — so every adapter reported "not installed", which emptied the ＋ menu, emptied both
// group agent pickers, and silently dropped Codex and Antigravity from `AgentIntegration`'s
// adapter table along with their accounts and hook routing. Panes were never affected and that is
// what hid it: a pane spawns a *login shell*, which reads the user's own startup files, so typing
// `claude` in one has always worked no matter what the app process could see.
//
// **So ask the same shell the pane will ask.** The only PATH that predicts whether a launch
// succeeds is the one the pane's shell ends up with, and the only thing that knows it is that
// shell. A list of likely install directories would be a guess that goes stale the first time a
// binary moves; this is measured.
//
// Two details that are load-bearing rather than incidental:
//
//   * **Interactive**, not just login. `TerminalEnvironment` already documents that this machine's
//     `.zshrc` ends by sourcing `~/.local/bin/env`, and a non-interactive `zsh -lc` never reads
//     `.zshrc` at all (`man zsh`, STARTUP/SHUTDOWN FILES). Probing without `-i` would miss exactly
//     the directory most agents install into.
//   * **A sentinel**, not "the output". An interactive rc may print a banner, a version notice or a
//     motd on stdout, and the answer has to survive that, so the shell marks its own line.
//
// Resolved once per launch, synchronously, after the window is on screen — never cached to disk. A
// cache would have to answer "is it stale?" on every launch, and the honest answer is unknowable:
// installing an agent does not touch anything tkzmux could watch. Half a second once per launch
// buys an answer that is never wrong, and `deadline` bounds the pathological rc.
//
// A probe that misses its deadline is **not** the final answer. At login the same shell can take
// several seconds, so the caller gets a `Resolution` that says the shell never answered and then
// calls `retry` on a background queue, which keeps asking with longer deadlines and hands back the
// real `PATH` when it arrives.

import Foundation
import Synchronization
import TkzCore
import os

public enum UserPath {
    private static let log = Logger(subsystem: "se.tkz.tkzmux", category: "user-path")

    /// Marks the line carrying the answer, so an rc file's own chatter on stdout cannot be mistaken
    /// for it. Deliberately not a plausible fragment of any real `PATH`.
    static let sentinel = "__tkzmux_path__"

    /// The `PATH` every "is this agent installed?" question in the app is answered against.
    ///
    /// The login shell's own `PATH`, unioned with the process's so the result can never be *worse*
    /// than what tkzmux used before: a probe that fails, times out or returns nothing leaves
    /// today's behaviour exactly as it was.
    ///
    /// - Parameters:
    ///   - shell: whose startup files to read. The same `LoginShell.detect` a pane uses, so the
    ///     probe and the launch agree about which shell speaks for this machine.
    ///   - processPath: the app process's own `PATH`, kept as the floor of the union.
    ///   - deadline: how long the shell gets. An rc that loads nvm, pyenv and a prompt framework is
    ///     slow but finite; one that blocks forever must not take the launch with it.
    ///   - probe: the spawn itself, injected so tests can drive `resolve` without a real shell.
    public static func resolve(
        shell: LoginShell = .detect(environment: ProcessInfo.processInfo.environment),
        processPath: String? = ProcessInfo.processInfo.environment["PATH"],
        deadline: TimeInterval = 2,
        probe: (LoginShell, TimeInterval) -> String? = UserPath.probeLoginShell
    ) -> String {
        resolution(shell: shell, processPath: processPath, deadline: deadline, probe: probe).path
    }

    /// What ``resolve(shell:processPath:deadline:probe:)`` settled on, and whether the shell
    /// actually answered.
    public struct Resolution: Sendable, Equatable {
        /// The merged `PATH`. Never worse than the process's own.
        public let path: String
        /// `false` when the probe failed and `path` is only the process's `PATH`: under a Finder
        /// or login-item launch that is launchd's four system directories, so the caller should
        /// ``retry(shell:processPath:deadlines:pause:probe:sleep:)`` instead of trusting it.
        public let fromShell: Bool
    }

    /// ``resolve(shell:processPath:deadline:probe:)``, saying whether the answer came from the
    /// shell.
    ///
    /// The flag exists because a failed probe used to be final. tkzmux is a login item, and the
    /// launch that matters most is the one at login, when the disk cache is cold and every other
    /// login item is starting too. That is exactly when an interactive `zsh -l -i` misses its
    /// deadline, and a miss left every agent "not installed" until the next relaunch, days later.
    public static func resolution(
        shell: LoginShell = .detect(environment: ProcessInfo.processInfo.environment),
        processPath: String? = ProcessInfo.processInfo.environment["PATH"],
        deadline: TimeInterval = 2,
        probe: (LoginShell, TimeInterval) -> String? = UserPath.probeLoginShell
    ) -> Resolution {
        let started = Date()
        let probed = probe(shell, deadline)
        if probed == nil {
            log.notice("login shell PATH unavailable; falling back to the process PATH")
        } else {
            let elapsed = Date().timeIntervalSince(started)
            log.info("login shell PATH resolved in \(elapsed, format: .fixed(precision: 2), privacy: .public)s")
        }
        return Resolution(path: merge(probed, with: processPath), fromShell: probed != nil)
    }

    /// Asks the shell again, more patiently, after a launch-time probe failed. Returns the merged
    /// `PATH` from the first attempt that answers, or `nil` if none does.
    ///
    /// **Blocking**: up to the sum of `deadlines` and the pauses between them, by design, so it
    /// belongs on a background queue (never the main thread, never a Swift concurrency thread).
    /// The deadlines grow because the usual cause of a miss is a machine still busy logging in,
    /// and that settles in seconds, not instantly.
    public static func retry(
        shell: LoginShell = .detect(environment: ProcessInfo.processInfo.environment),
        processPath: String? = ProcessInfo.processInfo.environment["PATH"],
        deadlines: [TimeInterval] = [5, 10, 20],
        pause: TimeInterval = 3,
        probe: (LoginShell, TimeInterval) -> String? = UserPath.probeLoginShell,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> String? {
        for (attempt, deadline) in deadlines.enumerated() {
            // Before every attempt, the first included: it comes straight after a miss.
            sleep(pause)
            if let probed = probe(shell, deadline) {
                log.notice("login shell PATH resolved on retry \(attempt + 1, privacy: .public)")
                return merge(probed, with: processPath)
            }
        }
        log.error("login shell PATH still unavailable after \(deadlines.count, privacy: .public) retries")
        return nil
    }

    /// `probed` first, then whatever the process had that it did not already carry, deduped with
    /// order preserved — `PATH` order decides which of two same-named binaries wins, and the
    /// shell's own order is the one the pane will use.
    static func merge(_ probed: String?, with processPath: String?) -> String {
        var out: [String] = []
        for source in [probed, processPath] {
            guard let source else { continue }
            for entry in source.split(separator: ":", omittingEmptySubsequences: true) {
                let directory = String(entry)
                if !out.contains(directory) { out.append(directory) }
            }
        }
        return out.joined(separator: ":")
    }

    /// The command the shell runs. `$PATH` is a *list* in fish, where `"$PATH"` would join with
    /// spaces and produce a path no directory in it exists at, so fish gets its own spelling.
    static func command(for family: LoginShell.Family) -> String {
        switch family {
        case .fish:
            return #"printf '\n%s%s\n' "\#(sentinel)" (string join ":" $PATH)"#
        case .zsh, .bash, .other:
            return #"printf '\n%s%s\n' "\#(sentinel)" "$PATH""#
        }
    }

    /// How to ask each family for a *startup-files-read* shell.
    ///
    /// `-i` is what makes zsh read `.zshrc` and bash read `.bashrc`; see this file's header for why
    /// that is the whole point. The families tkzmux has no wrapper for (tcsh, dash, ksh…) get
    /// login-only: `-i -l -c` is not portable across them, and a shell that refuses the arguments
    /// answers nothing at all rather than answering wrongly.
    static func arguments(for family: LoginShell.Family) -> [String] {
        switch family {
        case .zsh, .bash, .fish:
            return ["-i", "-l", "-c", command(for: family)]
        case .other:
            return ["-l", "-c", command(for: family)]
        }
    }

    /// The text after the **last** sentinel, up to the end of that line.
    ///
    /// Last, not first: an rc file that echoes the probe command back (`set -x`, a tracing
    /// `PS4`) would put an earlier, unexpanded copy of the sentinel on stdout ahead of the real
    /// one. Empty output, or output with no sentinel, is `nil` — a shell that printed a banner and
    /// then failed must not be read as "PATH is empty".
    static func parse(_ output: String) -> String? {
        guard let marker = output.range(of: sentinel, options: .backwards) else { return nil }
        let rest = output[marker.upperBound...]
        let line = rest.prefix { $0 != "\n" && $0 != "\r" }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Runs `shell` and returns what it says its `PATH` is, or `nil` if it could not be asked.
    ///
    /// stdin is `/dev/null` so an interactive rc that reads a line cannot hang the launch waiting
    /// for one, and stderr is discarded: an interactive shell with no tty routinely warns about job
    /// control, and none of that is an answer.
    public static func probeLoginShell(shell: LoginShell, deadline: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell.path)
        process.arguments = arguments(for: shell.family)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.notice("could not run \(shell.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // The read runs off this thread so the deadline can fire while the shell is still writing —
        // `readDataToEndOfFile` on this one would block past it, which is the hang being guarded
        // against. `Mutex` rather than a captured `var` because the closure is `@Sendable`.
        let output = Mutex<Data>(Data())
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.withLock { $0 = data }
            finished.signal()
        }

        if finished.wait(timeout: .now() + deadline) == .timedOut {
            log.notice("\(shell.name, privacy: .public) did not answer within \(deadline, privacy: .public)s")
            // SIGKILL, not `terminate()`'s SIGTERM: an interactive bash ignores SIGTERM (bash(1),
            // SIGNALS), so a timed-out probe would otherwise outlive the deadline it missed, and
            // every retry would leave another one behind.
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        process.waitUntilExit()
        let data = output.withLock { $0 }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }
}
