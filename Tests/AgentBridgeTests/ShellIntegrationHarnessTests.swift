// ShellIntegrationHarnessTests — the login-shell work's shared harness: every login shell tkzmux supports, spawned
// the way the app spawns it (`TerminalEnvironment.loginShellSpawn` on a real `Pty`, wrappers
// written by the real `ShimInstaller`), against a fake HOME with the user's own startup files.
//
// One test body, run once per shell found on the machine (macOS: `/bin/zsh`, `/bin/bash` 3.2,
// Homebrew bash, fish; Linux: whatever `/etc/shells` and PATH hold). What it proves for each:
//
//   - `command -v claude` inside tkzmux is the shim, and the user's own PATH prepend comes second;
//   - `TERM_PROGRAM`, `TKZMUX_SESSION_ID`, `TKZMUX_BIN` and the app's `CLAUDE_CONFIG_DIR` are
//     visible, the last one beating an export in the user's rc;
//   - the user's startup files ran, in login order, and the boot command ran exactly once at the
//     first prompt, bracketed in OSC 9;4, and landed in the history;
//   - OSC 7 reports the working directory at start and after `cd`;
//   - a nested interactive shell behaves like a normal one (reads the user's rc, no ZDOTDIR) and
//     still finds the shim through the inherited PATH;
//   - the same shell outside tkzmux is untouched.
//
// A real pty rather than `Process`: `Process` cannot set argv[0] (the login signal), and prompt
// hooks -- zsh precmd, bash PROMPT_COMMAND, fish_prompt -- do not fire dependably without a tty.
// The pattern follows `TerminalEnvironmentTests.loginZshSeesTheEnvironmentContract`: type one short
// line into the pty, poll a report file. Long lines are avoided on purpose (canonical-mode
// MAX_INPUT ~1 KiB), so the shell is asked to source a script file instead of being fed the script.
import Foundation
import Synchronization
import Testing
import TkzCore
import TkzTerminalCore

@testable import AgentBridge

// MARK: - Which shells

struct HarnessShell: CustomTestStringConvertible, Sendable {
    var shell: LoginShell
    var testDescription: String { shell.path }
}

/// Every supported shell present on this machine. fish is not part of a stock macOS install, nor
/// of most Linux ones; its absence is reported by `fishIsPresentForTheHarness` rather than silently
/// shrinking this list.
let installedHarnessShells: [HarnessShell] = {
    #if os(macOS)
    let candidates = [
        "/bin/zsh", "/bin/bash", "/opt/homebrew/bin/bash", "/opt/homebrew/bin/fish",
        "/usr/local/bin/fish",
    ]
    #else
    let candidates = harnessShellCandidates(
        etcShells: try? String(contentsOfFile: "/etc/shells", encoding: .utf8),
        path: ProcessInfo.processInfo.environment["PATH"])
    #endif
    return candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
        .map { HarnessShell(shell: LoginShell(path: $0)) }
}()

/// Linux has no fixed place for a shell: zsh and fish are wherever the package manager put them,
/// and a merged /usr makes `/bin/bash`, `/usr/bin/bash` and `/bin/sh` one binary. So the candidates
/// are every `/etc/shells` entry and every `<PATH dir>/{zsh,bash,fish}`, in that order, that names
/// a supported shell, deduplicated by realpath (the first spelling wins). `/bin/sh` is never one,
/// even when it is bash: `LoginShell` goes by the name, as the app does.
func harnessShellCandidates(etcShells: String?, path: String?) -> [String] {
    let listed = (etcShells ?? "").split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("/") }
    let onPath = (path ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
        .flatMap { directory in ["zsh", "bash", "fish"].map { "\(directory)/\($0)" } }
    var seen = Set<String>()
    return (listed + onPath).filter { candidate in
        guard LoginShell(path: candidate).family != .other,
            FileManager.default.isExecutableFile(atPath: candidate)
        else { return false }
        return seen.insert(realPath(URL(fileURLWithPath: candidate))).inserted
    }
}

// MARK: - Fixture

private struct HarnessFixture {
    var root: URL
    var home: URL
    var tkzmuxDir: URL
    var report: URL
    var markerLog: URL
    var shell: LoginShell

    var bin: URL { tkzmuxDir.appendingPathComponent("bin", isDirectory: true) }
    var shim: URL { bin.appendingPathComponent("claude") }
    var localBin: URL { home.appendingPathComponent(".local/bin", isDirectory: true) }
    var chosenConfigDir: URL { home.appendingPathComponent(".claude-chosen", isDirectory: true) }

    func reportFile(_ name: String) -> String? {
        try? String(contentsOf: report.appendingPathComponent(name), encoding: .utf8)
    }
    var markers: [String] {
        ((try? String(contentsOf: markerLog, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

/// A fake HOME with the user's own startup files for `shell`, plus a tkzmux directory the real
/// installer has written into. Each user file appends a marker to `$MARKER_LOG`; the rc file also
/// prepends `~/.local/bin` to PATH, again from a prompt hook at every prompt (mise's
/// `activate_aggressive` does that, and direnv), and exports its own `CLAUDE_CONFIG_DIR` -- the
/// things the wrapper has to beat.
private func makeFixture(for shell: LoginShell) throws -> HarnessFixture {
    let root = try ShimTestSupport.makeTempDirectory("harness-\(shell.name)")
    let home = root.appendingPathComponent("home", isDirectory: true)
    let tkzmuxDir = root.appendingPathComponent("tkzmux", isDirectory: true)
    let report = root.appendingPathComponent("report", isDirectory: true)
    let fixture = HarnessFixture(
        root: root, home: home, tkzmuxDir: tkzmuxDir, report: report,
        markerLog: root.appendingPathComponent("markers.txt"), shell: shell)
    for dir in [home, tkzmuxDir, report, fixture.localBin, fixture.chosenConfigDir] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    FileManager.default.createFile(atPath: fixture.markerLog.path, contents: nil)

    // The real installer, with a fake hook binary: bin/claude, the wrappers, VERSION.
    let hook = try ShimTestSupport.writeExecutable(
        "#!/bin/sh\nexit 0\n", to: root.appendingPathComponent("tkzmux-hook"))
    let installer = ShimInstaller(
        directory: tkzmuxDir, hookBinary: hook, resources: try ShimResources.bundled())
    #expect(try installer.ensureInstalled() == .installed)

    switch shell.family {
    case .zsh:
        try write("echo zshenv >> \"$MARKER_LOG\"\n", to: home.appendingPathComponent(".zshenv"))
        try write("echo zprofile >> \"$MARKER_LOG\"\n", to: home.appendingPathComponent(".zprofile"))
        try write(
            """
            echo zshrc >> "$MARKER_LOG"
            path=("$HOME/.local/bin" $path)
            export PATH
            export CLAUDE_CONFIG_DIR="$HOME/.claude-from-rc"
            __user_path_first() { path=("$HOME/.local/bin" ${path:#$HOME/.local/bin}) }
            precmd_functions=(__user_path_first $precmd_functions)

            """, to: home.appendingPathComponent(".zshrc"))
        try write("echo zlogin >> \"$MARKER_LOG\"\n", to: home.appendingPathComponent(".zlogin"))
    case .bash:
        // A login bash reads .bash_profile and not .bashrc; the nested interactive bash reads
        // .bashrc. The user's PROMPT_COMMAND ends in `;` on purpose -- the wrapper must append to
        // it without producing `;;`.
        try write(
            """
            echo bash_profile >> "$MARKER_LOG"
            export PATH="$HOME/.local/bin:$PATH"
            export CLAUDE_CONFIG_DIR="$HOME/.claude-from-rc"
            PROMPT_COMMAND='echo user_prompt_command >> "$MARKER_LOG"; PATH="$HOME/.local/bin:$PATH";'

            """, to: home.appendingPathComponent(".bash_profile"))
        try write("echo bashrc >> \"$MARKER_LOG\"\n", to: home.appendingPathComponent(".bashrc"))
    case .fish:
        // The PATH prepend the fish way: a *universal* `fish_user_paths`, which fish prepends to
        // PATH itself and persists in `~/.config/fish/fish_variables` -- the file the wrapper must
        // leave alone (the ticket's XDG_CONFIG_HOME idea would have hidden it).
        try write(
            """
            echo config.fish >> "$MARKER_LOG"
            set -U fish_user_paths $HOME/.local/bin
            set -gx CLAUDE_CONFIG_DIR $HOME/.claude-from-rc
            function __user_path_first --on-event fish_prompt
                set -gx PATH $HOME/.local/bin (string match -v -- $HOME/.local/bin $PATH)
            end

            """, to: home.appendingPathComponent(".config/fish/config.fish"))
    case .other:
        break
    }
    return fixture
}

/// The script the interactive shell is asked to source: every fact goes to a file under
/// `$REPORT`, `cd` triggers OSC 7, the nested shell is the same binary started interactively.
private func probeScript(_ fixture: HarnessFixture) -> String {
    let shell = fixture.shell.path
    switch fixture.shell.family {
    case .fish:
        return """
            command -v claude > $REPORT/which.txt
            string join : -- $PATH > $REPORT/path.txt
            begin
                echo TP=$TERM_PROGRAM
                echo SID=$TKZMUX_SESSION_ID
                echo BIN=$TKZMUX_BIN
                echo CCD=$CLAUDE_CONFIG_DIR
                if set -q ZDOTDIR; echo ZD=$ZDOTDIR; else; echo ZD=unset; end
                if set -q TKZMUX_BOOT_COMMAND; echo BOOT=set; else; echo BOOT=unset; end
            end > $REPORT/env.txt
            \(shell) -i -c 'command -v claude; if set -q ZDOTDIR; echo $ZDOTDIR; else; echo unset; end' > $REPORT/nested.txt 2>&1
            cd $REPORT
            history > $REPORT/history.txt
            echo DONE > $REPORT/done.txt

            """
    case .zsh, .bash, .other:
        let historyCommand = fixture.shell.family == .zsh ? "history -20" : "history 20"
        return """
            command -v claude > "$REPORT/which.txt"
            printf '%s\\n' "$PATH" > "$REPORT/path.txt"
            {
                printf 'TP=%s\\n' "$TERM_PROGRAM"
                printf 'SID=%s\\n' "$TKZMUX_SESSION_ID"
                printf 'BIN=%s\\n' "$TKZMUX_BIN"
                printf 'CCD=%s\\n' "$CLAUDE_CONFIG_DIR"
                printf 'ZD=%s\\n' "${ZDOTDIR:-unset}"
                printf 'BOOT=%s\\n' "${TKZMUX_BOOT_COMMAND:+set}${TKZMUX_BOOT_COMMAND:-unset}"
            } > "$REPORT/env.txt"
            \(shell) -i -c 'command -v claude; printf "%s\\n" "${ZDOTDIR:-unset}"' > "$REPORT/nested.txt" 2>&1
            cd "$REPORT"
            \(historyCommand) > "$REPORT/history.txt"
            echo DONE > "$REPORT/done.txt"

            """
    }
}

// MARK: - Driving the pty

private struct SessionRun {
    var output: String
    var exited: Bool
}

/// Spawns `fixture.shell` exactly as `TerminalViewHost` would, waits for the boot command to have
/// run (the first prompt has been reached, so the tty is past its startup flushes), types the
/// source line, waits for `done.txt`, and returns everything the shell wrote to the terminal.
private func runSession(_ fixture: HarnessFixture, bootCommand: String) async throws -> SessionRun {
    let base: [String: String] = [
        "HOME": fixture.home.path,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "USER": ProcessInfo.processInfo.userName,
        "LANG": "en_US.UTF-8",
        "MARKER_LOG": fixture.markerLog.path,
        "REPORT": fixture.report.path,
        // TKZ-84 generalized the single hard-coded re-export into TKZMUX_REEXPORT / TKZMUX_ENV_<NAME>
        // (see SessionLauncher.environment(accountKey:bootCommand:)) -- this is what it looks like
        // for the one variable Claude needs today.
        "TKZMUX_REEXPORT": "CLAUDE_CONFIG_DIR",
        "TKZMUX_ENV_CLAUDE_CONFIG_DIR": fixture.chosenConfigDir.path,
        "TKZMUX_BOOT_COMMAND": bootCommand,
    ]
    let spawn = TerminalEnvironment.loginShellSpawn(
        sessionID: "S-harness-\(fixture.shell.name)", cwd: fixture.home.path,
        size: TerminalSize(rows: 40, cols: 200), tkzmuxDir: fixture.tkzmuxDir,
        baseEnvironment: base, home: fixture.home.path, shell: fixture.shell)
    #expect(spawn.executablePath == fixture.shell.path)
    #expect(spawn.environment["TERM_PROGRAM"] == "ghostty")

    let output = Mutex(Data())
    let exited = Mutex(false)
    let queue = DispatchQueue(label: "tkzmux.test.harness.\(fixture.shell.name)")
    let ptyBox = Mutex<Pty?>(nil)
    let pty = try Pty(
        spawn: spawn, ioQueue: queue,
        onData: { data in
            output.withLock { $0.append(data) }
            // fish probes the terminal at startup (kitty keyboard, XTGETTCAP, background colour)
            // and waits up to ten seconds for the Primary Device Attributes reply that tells it
            // the probing is over. In the app libghostty-vt answers; here nothing does, so answer
            // DA1 the way a VT100-class terminal would. Everything else fish asks it copes without.
            if data.contains(0x63 /* c */), String(decoding: data, as: UTF8.self).contains("\u{1b}[c")
                || String(decoding: data, as: UTF8.self).contains("\u{1b}[0c") {
                if let pty = ptyBox.withLock({ $0 }) { try? pty.write(Data("\u{1b}[?62;22c".utf8)) }
            }
        },
        onExit: { _ in exited.withLock { $0 = true } })
    ptyBox.withLock { $0 = pty }
    defer { pty.terminate(signal: SIGKILL) }

    func waitFor(_ condition: @escaping () -> Bool, seconds: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    let booted = await waitFor({ fixture.markers.contains("BOOT-RAN") }, seconds: 20)
    #expect(booted, "\(fixture.shell.path): boot command never ran; markers: \(fixture.markers)")

    let scriptName = fixture.shell.family == .fish ? "probe.fish" : "probe.sh"
    let script = fixture.root.appendingPathComponent(scriptName)
    try probeScript(fixture).write(to: script, atomically: true, encoding: .utf8)
    let sourceLine = fixture.shell.family == .fish
        ? "source \(script.path)\n" : ". \(script.path)\n"
    queue.async { try? pty.write(Data(sourceLine.utf8)) }

    let done = await waitFor(
        { FileManager.default.fileExists(atPath: fixture.report.appendingPathComponent("done.txt").path) },
        seconds: 20)
    #expect(done, "\(fixture.shell.path): probe never finished")
    // Let the prompt after `cd` -- and its OSC 7 -- reach the output before reading it.
    _ = await waitFor(
        { String(decoding: output.withLock { $0 }, as: UTF8.self).contains(osc7(forPath: fixture.report.path)) },
        seconds: 5)

    return SessionRun(
        output: String(decoding: output.withLock { $0 }, as: UTF8.self),
        exited: exited.withLock { $0 })
}

/// The OSC 7 the wrapper emits for `path`. Every character in these paths is one the wrappers
/// leave unencoded.
private func osc7(forPath path: String) -> String {
    "\u{1b}]7;file://localhost\(path)\u{7}"
}

/// `realpath(3)`: the start directory is reported as the shell's `getcwd()`, with `/var`
/// resolved to `/private/var`. (Foundation's `resolvingSymlinksInPath` strips `/private` again,
/// which is the opposite of what the shell prints.) A `cd` to the logical path keeps it logical.
private func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

// MARK: - The harness

#if os(macOS)
private let harnessNeedsEveryShell = true
#else
/// zsh and fish are packages a Linux developer machine may not have; there the harness covers
/// what is installed. CI (`CI` set, as on GitHub Actions) installs both, and a missing one fails.
private let harnessNeedsEveryShell = ProcessInfo.processInfo.environment["CI"] != nil
#endif

@Suite(.serialized)
struct ShellIntegrationHarnessTests {
    /// fish is a Homebrew install on macOS and a package on Linux, and the ticket's acceptance is
    /// all three shells. A missing fish would otherwise shrink the argument list without a word.
    @Test(.enabled(if: harnessNeedsEveryShell, "not in CI: the harness covers the shells installed"))
    func fishIsPresentForTheHarness() {
        let hasFish = installedHarnessShells.contains { $0.shell.family == .fish }
        if !hasFish {
            #if os(macOS)
            Issue.record("fish is not installed; the harness cannot cover it (brew install fish)")
            #else
            Issue.record(
                "fish is not installed; the harness cannot cover it (pacman -S fish, apt install fish)")
            #endif
        }
        #expect(installedHarnessShells.contains { $0.shell.family == .zsh })
        #expect(installedHarnessShells.contains { $0.shell.family == .bash })
    }

    #if os(Linux)
    /// A merged /usr lists one bash under several names; the harness runs it once, under the
    /// first, and never as `sh` or `rbash`.
    @Test func linuxCandidatesAreDeduplicatedByRealpath() {
        let etcShells = "# Valid login shells.\n/bin/sh\n/bin/bash\n/usr/bin/bash\n/usr/bin/rbash\n"
        let candidates = harnessShellCandidates(etcShells: etcShells, path: "/usr/bin:/bin")
        let bashes = candidates.filter { LoginShell(path: $0).family == .bash }
        #expect(bashes == ["/bin/bash"], "\(candidates)")
        #expect(candidates.allSatisfy { LoginShell(path: $0).family != .other }, "\(candidates)")
    }
    #endif

    @Test(arguments: installedHarnessShells)
    func shellIntegration(_ harness: HarnessShell) async throws {
        let fixture = try makeFixture(for: harness.shell)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bootCommand = "echo BOOT-RAN >> \"$MARKER_LOG\""

        let run = try await runSession(fixture, bootCommand: bootCommand)
        let tag = harness.shell.path

        // The shim wins, the user's prepend is right behind it -- also after the prompts at which
        // the user's hook put `~/.local/bin` first again.
        #expect(fixture.reportFile("which.txt")?.trimmingCharacters(in: .whitespacesAndNewlines)
            == fixture.shim.path, "\(tag): \(fixture.reportFile("which.txt") ?? "no which.txt")")
        let path = (fixture.reportFile("path.txt") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":").map(String.init)
        #expect(path.first == fixture.bin.path, "\(tag): PATH=\(path)")
        #expect(path.dropFirst().first == fixture.localBin.path, "\(tag): PATH=\(path)")
        #expect(path.filter { $0 == fixture.bin.path }.count == 1, "\(tag): PATH=\(path)")

        // The environment contract, and the app's account over the rc file's.
        let env = fixture.reportFile("env.txt") ?? ""
        #expect(env.contains("TP=ghostty\n"), "\(tag): \(env)")
        #expect(env.contains("SID=S-harness-\(harness.shell.name)\n"), "\(tag): \(env)")
        #expect(env.contains("BIN=\(fixture.bin.path)\n"), "\(tag): \(env)")
        #expect(env.contains("CCD=\(fixture.chosenConfigDir.path)\n"), "\(tag): \(env)")
        // zsh: `.zlogin` unset it again (the user had none); bash/fish never had it.
        #expect(env.contains("ZD=unset\n"), "\(tag): \(env)")
        #expect(env.contains("BOOT=unset\n"), "\(tag): \(env)")

        // Startup files in login order, boot command once at the first prompt, then the nested
        // shell's own startup. The user's PROMPT_COMMAND (bash) fires at every prompt and is
        // filtered out of the sequence, but must have run *before* the boot command.
        let markers = fixture.markers
        let sequence = markers.filter { $0 != "user_prompt_command" }
        let expected: [String]
        switch harness.shell.family {
        case .zsh: expected = ["zshenv", "zprofile", "zshrc", "zlogin", "BOOT-RAN", "zshenv", "zshrc"]
        case .bash: expected = ["bash_profile", "BOOT-RAN", "bashrc"]
        case .fish: expected = ["config.fish", "BOOT-RAN", "config.fish"]
        case .other: expected = []
        }
        #expect(sequence == expected, "\(tag): markers \(markers)")
        #expect(markers.filter { $0 == "BOOT-RAN" }.count == 1, "\(tag): markers \(markers)")
        if harness.shell.family == .bash {
            let userHook = markers.firstIndex(of: "user_prompt_command")
            let boot = markers.firstIndex(of: "BOOT-RAN")
            #expect(userHook != nil && boot != nil && userHook! < boot!, "\(tag): markers \(markers)")
        }

        // The title is tkzmux's (from OSC 7), as on macOS: no OSC 0/2 from the system files.
        // (Arch's /etc/bash.bashrc sets one at every prompt; this fixture's PROMPT_COMMAND
        // assignment overwrites that element, so `BashWrapperTests` checks it.) fish's own default
        // fish_title sends OSC 0 on both OSes. And no OSC 3008 (Arch's systemd profile script).
        if harness.shell.family != .fish {
            #expect(!run.output.contains("\u{1b}]0;"), "\(tag): an OSC 0 title")
            #expect(!run.output.contains("\u{1b}]2;"), "\(tag): an OSC 2 title")
        }
        #expect(!run.output.contains("\u{1b}]3008;"), "\(tag): an OSC 3008 context report")

        // OSC 9;4 around the boot command, OSC 7 for the start directory and after `cd`.
        #expect(run.output.contains("\u{1b}]9;4;3\u{7}"), "\(tag): no progress start")
        #expect(run.output.contains("\u{1b}]9;4;0\u{7}"), "\(tag): no progress end")
        #expect(run.output.contains(osc7(forPath: realPath(fixture.home))), "\(tag): no OSC 7 for HOME")
        #expect(run.output.contains(osc7(forPath: fixture.report.path)), "\(tag): no OSC 7 after cd")

        // Up repeats the boot command.
        #expect(fixture.reportFile("history.txt")?.contains("echo BOOT-RAN") == true,
            "\(tag): history \(fixture.reportFile("history.txt") ?? "none")")

        // The nested shell: still the shim (inherited PATH), no tkzmux ZDOTDIR.
        let nested = (fixture.reportFile("nested.txt") ?? "").split(separator: "\n").map(String.init)
        #expect(nested.first == fixture.shim.path, "\(tag): nested \(nested)")
        #expect(nested.dropFirst().first == "unset", "\(tag): nested \(nested)")

        #expect(!run.exited, "\(tag): the shell exited during the probe")

        // fish keeps its universal variables in the fake HOME: the user's `fish_user_paths` is
        // there, tkzmux's bin is not.
        if harness.shell.family == .fish {
            let variables = fixture.home.appendingPathComponent(".config/fish/fish_variables")
            let content = (try? String(contentsOf: variables, encoding: .utf8)) ?? ""
            // fish stores values escaped (`\x2e` for `.`, `\x2d` for `-`); `/tkzmux/bin` has
            // nothing to escape, and the temp directory's own name contains "tkzmux", so the
            // check is on the bin path's tail rather than on the word.
            #expect(content.contains("SETUVAR fish_user_paths:"), "\(tag): fish_variables \(content)")
            #expect(content.contains("/home/\\x2elocal/bin"), "\(tag): fish_variables \(content)")
            #expect(!content.contains("/tkzmux/bin"), "\(tag): fish_variables \(content)")
        }
    }

    /// Outside tkzmux the same shell, same HOME, is untouched: no `TKZMUX_*` in the environment
    /// means no shim on PATH, and the bash/fish wrapper sourced by hand without `TKZMUX_BIN` does
    /// nothing at all.
    @Test(arguments: installedHarnessShells)
    func outsideTkzmuxNothingChanges(_ harness: HarnessShell) throws {
        let fixture = try makeFixture(for: harness.shell)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside: [String: String] = [
            "HOME": fixture.home.path, "PATH": "/usr/bin:/bin", "MARKER_LOG": fixture.markerLog.path,
            "TERM": "dumb",
        ]
        let probe: String
        switch harness.shell.family {
        case .fish: probe = "command -v claude; string join : -- $PATH"
        default: probe = "command -v claude; printf '%s\\n' \"$PATH\""
        }
        let result = try ShimTestSupport.run(
            URL(fileURLWithPath: harness.shell.path), ["-l", "-i", "-c", probe], environment: outside)
        #expect(!result.stdout.contains(fixture.bin.path), "\(harness.shell.path): \(result.stdout)")

        // Sourcing the wrapper by hand, with no `TKZMUX_BIN`, must leave PATH exactly as it was.
        // fish reads config.fish even for `fish -c`, and the fixture's config prepends to PATH, so
        // it runs with `--no-config` here to isolate the wrapper's own effect.
        guard let wrapper = harness.shell.entryWrapper(in: fixture.tkzmuxDir) else { return }
        let sourced: [String]
        switch harness.shell.family {
        case .fish: sourced = ["--no-config", "-c", "source \(wrapper.path); string join : -- $PATH"]
        default: sourced = ["-c", ". \(wrapper.path); printf '%s\\n' \"$PATH\""]
        }
        let after = try ShimTestSupport.run(
            URL(fileURLWithPath: harness.shell.path), sourced, environment: outside)
        #expect(after.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/usr/bin:/bin",
            "\(harness.shell.path): \(after.stdout) \(after.stderr)")
        #expect(after.stderr.isEmpty, "\(harness.shell.path): \(after.stderr)")
    }
}
