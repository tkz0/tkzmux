import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

import TkzCore

@testable import TkzTerminalCore

private func tempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-env-tests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Everything a session inherits in these tests is explicit — nothing depends on the real `~`,
/// and `SHELL` is zsh whatever the machine's login shell is (TKZ-33).
private func hostEnvironment(home: String, shell: String = "/bin/zsh") -> [String: String] {
    [
        "HOME": home,
        "SHELL": shell,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TERM": "xterm-256color",
        "TERM_PROGRAM": "Apple_Terminal",
        "TERM_SESSION_ID": "should-not-survive",
        "TERMINFO_DIRS": "/opt/somewhere/terminfo",
        "LANG": "sv_SE.UTF-8",
    ]
}

@Suite struct TerminalEnvironmentTests {
    @Test func identifiesAsGhostty() throws {
        let home = try tempDir("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = TerminalEnvironment.make(
            sessionID: "S1",
            tkzmuxDir: home.appending(path: "support"),
            baseEnvironment: hostEnvironment(home: home.path),
            home: home.path
        )
        #expect(env["TERM"] == "xterm-ghostty")
        #expect(env["TERM_PROGRAM"] == "ghostty")
        #expect(env["TERM_PROGRAM_VERSION"] == TerminalEnvironment.version)
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TKZMUX_SESSION_ID"] == "S1")
    }

    @Test func stripsHostTerminalVariables() throws {
        let home = try tempDir("strip")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = TerminalEnvironment.make(
            sessionID: "S1",
            tkzmuxDir: home.appending(path: "support"),
            baseEnvironment: hostEnvironment(home: home.path),
            home: home.path
        )
        #expect(env["TERM_SESSION_ID"] == nil)
        #expect(env["TERMINFO_DIRS"] == nil)
    }

    /// tkzmux manages Claude Code sessions, so it gets launched from inside one — and `open
    /// tkzmux.app` propagates the caller's environment. An inherited `CLAUDE_CODE_CHILD_SESSION`
    /// turns transcript saving off in every managed session and stops Claude Code publishing the
    /// descriptor whose `status: busy` is the only source of the green `working` status.
    /// Found running the notarized build, 2026-09-09.
    @Test func stripsInheritedClaudeCodeSessionMarkers() throws {
        let home = try tempDir("claude-markers")
        defer { try? FileManager.default.removeItem(at: home) }
        var host = hostEnvironment(home: home.path)
        for key in [
            "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
            "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_BRIDGE_SESSION_ID", "CLAUDE_CODE_MESSAGING_SOCKET",
            "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXECPATH",
            "CLAUDE_CODE_SOMETHING_INVENTED_LATER",
        ] { host[key] = "should-not-survive" }

        let env = TerminalEnvironment.make(
            sessionID: "S1",
            tkzmuxDir: home.appending(path: "support"),
            baseEnvironment: host,
            home: home.path
        )

        #expect(env.keys.filter { $0.hasPrefix("CLAUDE_CODE_") } == [])
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["CLAUDE_PID"] == nil)
        #expect(env["CLAUDE_EFFORT"] == nil)
        // The session still gets everything it is supposed to have.
        #expect(env["TKZMUX_SESSION_ID"] == "S1")
        #expect(env["TERM"] == "xterm-ghostty")
    }

    /// The one CLAUDE_* variable that must survive: design.md → *Accounts are generic* says an
    /// inherited config dir is left alone so the environment decides the account. Stripping it by
    /// an over-broad `CLAUDE_` prefix would silently move sessions to the wrong Claude account.
    @Test func keepsInheritedClaudeConfigDir() throws {
        let home = try tempDir("config-dir")
        defer { try? FileManager.default.removeItem(at: home) }
        var host = hostEnvironment(home: home.path)
        host["CLAUDE_CONFIG_DIR"] = "\(home.path)/.claude-work"
        host["CLAUDE_CODE_CHILD_SESSION"] = "should-not-survive"

        let env = TerminalEnvironment.make(
            sessionID: "S1",
            tkzmuxDir: home.appending(path: "support"),
            baseEnvironment: host,
            home: home.path
        )
        #expect(env["CLAUDE_CONFIG_DIR"] == "\(home.path)/.claude-work")
        #expect(env["CLAUDE_CODE_CHILD_SESSION"] == nil)
    }

    /// A chosen account still wins over whatever the host had.
    @Test func chosenAccountOverridesInheritedConfigDir() throws {
        let home = try tempDir("config-dir-override")
        defer { try? FileManager.default.removeItem(at: home) }
        var host = hostEnvironment(home: home.path)
        host["CLAUDE_CONFIG_DIR"] = "\(home.path)/.claude-inherited"

        let env = TerminalEnvironment.make(
            sessionID: "S1",
            accountConfigDir: "\(home.path)/.claude-chosen",
            tkzmuxDir: home.appending(path: "support"),
            baseEnvironment: host,
            home: home.path
        )
        #expect(env["CLAUDE_CONFIG_DIR"] == "\(home.path)/.claude-chosen")
    }

    @Test func keepsPathExactlyAsInherited() throws {
        let home = try tempDir("path")
        defer { try? FileManager.default.removeItem(at: home) }
        let base = hostEnvironment(home: home.path)
        let support = home.appending(path: "support")
        let env = TerminalEnvironment.make(
            sessionID: "S1", tkzmuxDir: support, baseEnvironment: base, home: home.path
        )
        // The ZDOTDIR wrapper (M3.3) prepends TKZMUX_BIN *after* the user's rc files; not here.
        #expect(env["PATH"] == base["PATH"])
        #expect(env["TKZMUX_BIN"] == support.appending(path: "bin").path)
        #expect(env["TKZMUX_BIN"].map { env["PATH"]!.contains($0) } == false)
    }

    @Test func zdotdirPointsAtTkzmuxAndKeepsTheUserHome() throws {
        let home = try tempDir("zdotdir")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "support")
        let env = TerminalEnvironment.make(
            sessionID: "S1", tkzmuxDir: support,
            baseEnvironment: hostEnvironment(home: home.path), home: home.path
        )
        #expect(env["ZDOTDIR"] == support.appending(path: "zsh").path)
        #expect(env["TKZMUX_ZDOTDIR"] == env["ZDOTDIR"])
        #expect(env["TKZMUX_USER_ZDOTDIR"] == home.path)
        #expect(env["TKZMUX_SOCKET"] == support.appending(path: "tkzmux.sock").path)
    }

    /// TKZ-33: the ZDOTDIR trio is zsh's mechanism. Set for a bash or fish session, a nested
    /// `zsh` started from it would read tkzmux's wrappers. Everything else in the contract stays.
    @Test func bashAndFishGetNoZdotdir() throws {
        let home = try tempDir("nozdotdir")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "support")
        for shellPath in ["/bin/bash", "/opt/homebrew/bin/fish"] {
            let env = TerminalEnvironment.make(
                sessionID: "S1", tkzmuxDir: support,
                baseEnvironment: hostEnvironment(home: home.path, shell: shellPath), home: home.path,
                shell: LoginShell(path: shellPath)
            )
            #expect(env["ZDOTDIR"] == nil, "\(shellPath)")
            #expect(env["TKZMUX_ZDOTDIR"] == nil, "\(shellPath)")
            #expect(env["TKZMUX_USER_ZDOTDIR"] == nil, "\(shellPath)")
            #expect(env["TKZMUX_BIN"] == support.appending(path: "bin").path)
            #expect(env["TKZMUX_SESSION_ID"] == "S1")
            #expect(env["TERM_PROGRAM"] == "ghostty")
            // The wrapper does the prepend, after the user's files.
            #expect(env["PATH"] == hostEnvironment(home: home.path)["PATH"])
        }
    }

    /// A shell tkzmux has no wrapper for gets the best available: `TKZMUX_BIN` first on PATH from
    /// the pty, exactly once, and a plain login argv.
    @Test func unsupportedShellsGetThePathPrependHere() throws {
        let home = try tempDir("tcsh")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "support")
        let bin = support.appending(path: "bin").path
        var base = hostEnvironment(home: home.path, shell: "/bin/tcsh")
        base["PATH"] = "/usr/bin:\(bin):/bin"
        let spawn = TerminalEnvironment.loginShellSpawn(
            sessionID: "S1", cwd: home.path, size: TerminalSize(rows: 24, cols: 80),
            tkzmuxDir: support, baseEnvironment: base, home: home.path,
            shell: LoginShell(path: "/bin/tcsh"), wrapperPresent: false
        )
        #expect(spawn.executablePath == "/bin/tcsh")
        #expect(spawn.argv == ["-tcsh"])
        #expect(spawn.environment["PATH"] == "\(bin):/usr/bin:/bin")
        #expect(spawn.environment["ZDOTDIR"] == nil)
    }

    /// The spawn follows `SHELL` when no shell is passed, and the argv follows whether the
    /// wrapper is on disk: a `bash --rcfile <missing file>` would print an error into the
    /// user's terminal, so without the wrapper bash is a plain login shell.
    @Test func spawnFollowsShellAndWrapperPresence() throws {
        let home = try tempDir("bashspawn")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "support")
        let base = hostEnvironment(home: home.path, shell: "/bin/bash")

        let plain = TerminalEnvironment.loginShellSpawn(
            sessionID: "S1", cwd: home.path, size: TerminalSize(rows: 24, cols: 80),
            tkzmuxDir: support, baseEnvironment: base, home: home.path
        )
        #expect(plain.executablePath == "/bin/bash")
        #expect(plain.argv == ["-bash", "-l"])

        let wrapper = support.appending(path: "bash/tkzmux.bashrc")
        try FileManager.default.createDirectory(
            at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# wrapper\n".write(to: wrapper, atomically: true, encoding: .utf8)
        let integrated = TerminalEnvironment.loginShellSpawn(
            sessionID: "S1", cwd: home.path, size: TerminalSize(rows: 24, cols: 80),
            tkzmuxDir: support, baseEnvironment: base, home: home.path
        )
        #expect(integrated.argv == ["bash", "--rcfile", wrapper.path])
    }

    @Test func claudeConfigDirOnlyForNonPrimaryAccounts() throws {
        let home = try tempDir("account")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "support")
        let base = hostEnvironment(home: home.path)

        let primary = TerminalEnvironment.make(
            sessionID: "S1", accountConfigDir: nil, tkzmuxDir: support,
            baseEnvironment: base, home: home.path
        )
        #expect(primary["CLAUDE_CONFIG_DIR"] == nil)

        let alt = TerminalEnvironment.make(
            sessionID: "S2", accountConfigDir: "\(home.path)/.claude-work", tkzmuxDir: support,
            baseEnvironment: base, home: home.path
        )
        #expect(alt["CLAUDE_CONFIG_DIR"] == "\(home.path)/.claude-work")
    }

    @Test func langFallsBackWhenNotInherited() throws {
        let home = try tempDir("lang")
        defer { try? FileManager.default.removeItem(at: home) }
        var base = hostEnvironment(home: home.path)
        base.removeValue(forKey: "LANG")
        let support = home.appending(path: "support")
        #expect(
            TerminalEnvironment.make(
                sessionID: "S1", tkzmuxDir: support, baseEnvironment: base, home: home.path
            )["LANG"] == "en_US.UTF-8"
        )
        #expect(
            TerminalEnvironment.make(
                sessionID: "S1", tkzmuxDir: support,
                baseEnvironment: hostEnvironment(home: home.path), home: home.path
            )["LANG"] == "sv_SE.UTF-8"
        )
    }

    @Test func terminfoPointsAtTheBundledDatabase() throws {
        let home = try tempDir("terminfo")
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = try #require(TerminalEnvironment.bundledTerminfoDirectory, "terminfo missing from Bundle.module")
        let env = TerminalEnvironment.make(
            sessionID: "S1", tkzmuxDir: home.appending(path: "support"),
            baseEnvironment: hostEnvironment(home: home.path), home: home.path
        )
        let terminfo = try #require(env["TERMINFO"])
        #expect(terminfo == dir.path)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: terminfo, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: "\(terminfo)/78/xterm-ghostty"))
        #expect(FileManager.default.fileExists(atPath: "\(terminfo)/67/ghostty"))
    }

    @Test func missingTerminfoIsSurvivable() throws {
        let home = try tempDir("noterminfo")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = TerminalEnvironment.make(
            sessionID: "S1", tkzmuxDir: home.appending(path: "support"),
            baseEnvironment: hostEnvironment(home: home.path), home: home.path,
            terminfoDirectory: nil
        )
        #expect(env["TERMINFO"] == nil)
        #expect(env["TERM"] == "xterm-ghostty")
    }

    /// End to end: a real login zsh on a real pty sees `TERM_PROGRAM=ghostty` and resolves
    /// `xterm-ghostty` from *our* bundled terminfo. `TERMINFO_DIRS` is absent from the child env
    /// (we strip it and the test's base env never sets it), so a machine-wide install cannot mask
    /// the result — the assertion is on the path infocmp reports, not merely on its exit code.
    @Test func loginZshSeesTheEnvironmentContract() async throws {
        let home = try tempDir("loginzsh")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "support")
        let terminfo = try #require(TerminalEnvironment.bundledTerminfoDirectory)

        let spawn = TerminalEnvironment.loginShellSpawn(
            sessionID: "S-login",
            cwd: home.path,
            size: TerminalSize(rows: 40, cols: 200),
            tkzmuxDir: support,
            baseEnvironment: hostEnvironment(home: home.path),
            home: home.path
        )
        #expect(spawn.executablePath == "/bin/zsh")
        #expect(spawn.argv == ["-zsh", "-l"])
        #expect(spawn.environment["TERMINFO_DIRS"] == nil)

        let done = Mutex(false)
        let queue = DispatchQueue(label: "tkzmux.test.loginzsh")
        let pty = try Pty(
            spawn: spawn, ioQueue: queue,
            onData: { _ in }, onExit: { _ in done.withLock { $0 = true } }
        )
        defer { pty.terminate(signal: SIGKILL) }

        queue.async {
            let script = """
                printf 'TP=%s\\n' "$TERM_PROGRAM" > tp.txt
                printf 'TI=%s\\n' "$TERMINFO" >> tp.txt
                infocmp -1 xterm-ghostty > ic.txt 2>&1; printf 'RC=%s\\n' "$?" >> tp.txt

                """
            try? pty.write(Data(script.utf8))
        }

        let tp = home.appending(path: "tp.txt").path
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOfFile: tp, encoding: .utf8), text.contains("RC=") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let report = try #require(try? String(contentsOfFile: tp, encoding: .utf8), "login zsh produced nothing")
        #expect(report.contains("TP=ghostty"), "report: \(report)")
        #expect(report.contains("TI=\(terminfo.path)"), "report: \(report)")
        #expect(report.contains("RC=0"), "infocmp failed: \(report)")

        let infocmp = try #require(try? String(contentsOfFile: home.appending(path: "ic.txt").path, encoding: .utf8))
        #expect(infocmp.contains(terminfo.path), "infocmp used another terminfo:\n\(infocmp.prefix(300))")
        #expect(infocmp.contains("xterm-ghostty"))

        pty.terminate(signal: SIGKILL)
        let exitDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < exitDeadline, !done.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(done.withLock { $0 })
    }
}
