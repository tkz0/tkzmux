// UserPathTests — the PATH a Finder-launched app has to ask its shell for.
//
// The parsing and merging halves are driven with fixed strings, and the spawn half against a real
// `/bin/sh`: a shell that exists on every macOS, is in the `.other` family (so it exercises the
// login-only argument form), and reads no user file, which is what makes its answer the same on
// every machine this suite runs on. The interactive `-i -l -c` form is deliberately not exercised
// against the developer's own `.zshrc` — that would assert on whatever this machine's rc happens
// to export.

import Foundation
import TkzCore
import Testing

@testable import AgentBridge

@Suite("UserPath")
struct UserPathTests {
    // MARK: parse

    @Test("the sentinel's own line is the answer")
    func parsesSentinelLine() {
        let output = "\n\(UserPath.sentinel)/opt/homebrew/bin:/usr/bin\n"
        #expect(UserPath.parse(output) == "/opt/homebrew/bin:/usr/bin")
    }

    @Test("an rc file's banner on stdout is not the answer")
    func ignoresPrecedingChatter() {
        let output = """
            Last login: Fri Sep 19 10:00:00
            nvm: loaded v24.11.0

            \(UserPath.sentinel)/Users/x/.local/bin:/usr/bin
            """
        #expect(UserPath.parse(output) == "/Users/x/.local/bin:/usr/bin")
    }

    @Test("the last sentinel wins, so an echoed command line cannot")
    func prefersTheLastSentinel() {
        let output = """
            + printf '\\n%s%s\\n' \(UserPath.sentinel) $PATH
            \(UserPath.sentinel)/real/bin
            """
        #expect(UserPath.parse(output) == "/real/bin")
    }

    @Test("no sentinel is no answer, not an empty PATH")
    func missingSentinelIsNil() {
        #expect(UserPath.parse("") == nil)
        #expect(UserPath.parse("command not found\n") == nil)
    }

    @Test("a sentinel with nothing after it is no answer either")
    func emptyAnswerIsNil() {
        #expect(UserPath.parse("\(UserPath.sentinel)\n") == nil)
        #expect(UserPath.parse("\(UserPath.sentinel)   \n") == nil)
    }

    // MARK: merge

    @Test("the shell's entries come first, the process's are kept behind them")
    func mergeKeepsBothInOrder() {
        let merged = UserPath.merge("/opt/homebrew/bin:/usr/bin", with: "/usr/bin:/bin:/usr/sbin")
        #expect(merged == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin")
    }

    @Test("a failed probe leaves the process PATH exactly as it was")
    func mergeFallsBackToProcessPath() {
        #expect(UserPath.merge(nil, with: "/usr/bin:/bin") == "/usr/bin:/bin")
    }

    @Test("empty entries are dropped rather than becoming the cwd")
    func mergeDropsEmptyEntries() {
        #expect(UserPath.merge("/a::/b:", with: nil) == "/a:/b")
    }

    @Test("resolve unions the probe with the process PATH")
    func resolveUnions() {
        let path = UserPath.resolve(
            shell: LoginShell(path: "/bin/zsh"),
            processPath: "/usr/bin:/bin",
            probe: { _, _ in "/Users/x/.local/bin:/usr/bin" })
        #expect(path == "/Users/x/.local/bin:/usr/bin:/bin")
    }

    @Test("resolve survives a probe that answers nothing")
    func resolveSurvivesAFailedProbe() {
        let path = UserPath.resolve(
            shell: LoginShell(path: "/bin/zsh"), processPath: "/usr/bin:/bin", probe: { _, _ in nil })
        #expect(path == "/usr/bin:/bin")
    }

    // MARK: arguments

    @Test("zsh and bash are asked interactively, or they never read .zshrc / .bashrc")
    func interactiveForShellsWithAnRc() {
        for family in [LoginShell.Family.zsh, .bash, .fish] {
            #expect(UserPath.arguments(for: family).prefix(2) == ["-i", "-l"])
        }
    }

    @Test("an unknown shell is asked login-only, since -i -l -c is not portable")
    func loginOnlyForOtherShells() {
        #expect(UserPath.arguments(for: .other).prefix(2) == ["-l", "-c"])
    }

    @Test("fish joins its PATH list itself, since \"$PATH\" would be space-separated there")
    func fishJoinsItsList() {
        #expect(UserPath.command(for: .fish).contains(#"string join ":" $PATH"#))
        #expect(UserPath.command(for: .zsh).contains(#""$PATH""#))
    }

    // MARK: the real spawn

    @Test("a real shell answers with the PATH it was given")
    func probesARealShell() throws {
        // `/bin/sh` is `.other`, so this runs the login-only form — and `sh -l` reads only
        // `/etc/profile`, never a user file, which is what keeps the expectation machine-independent.
        let probed = UserPath.probeLoginShell(shell: LoginShell(path: "/bin/sh"), deadline: 10)
        let answer = try #require(probed)
        #expect(!answer.isEmpty)
        // Whatever `/etc/profile` adds, the system directories are always in it.
        #expect(answer.split(separator: ":").contains("/usr/bin"))
    }

    @Test("a shell that cannot be run answers nothing rather than throwing")
    func missingShellIsNil() {
        #expect(UserPath.probeLoginShell(shell: LoginShell(path: "/nonexistent/sh"), deadline: 1) == nil)
    }

    @Test("a shell that never answers is abandoned at the deadline")
    func deadlineIsEnforced() throws {
        // A "shell" that ignores its arguments and never prints anything. The real
        // `probeLoginShell` runs it exactly as it would run zsh, so this exercises the production
        // timeout rather than a copy of it.
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkzmux-slow-shell-\(UUID().uuidString)")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let started = Date()
        let probed = UserPath.probeLoginShell(shell: LoginShell(path: script.path), deadline: 0.5)
        let elapsed = Date().timeIntervalSince(started)
        #expect(probed == nil)
        // Generous, but far below the 30 s the script would take if the deadline did nothing.
        #expect(elapsed < 10)
    }
}
