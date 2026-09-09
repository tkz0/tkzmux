// ZshWrapperTests — runs a real `/bin/zsh -l -i -c` against the installed ZDOTDIR wrappers and a
// fake HOME with the user's own dotfiles, verifying every startup file ran, in order, and that
// HISTFILE / PATH / ZDOTDIR end up where the contract in the TKZ-23 ticket says they should. See
// docs/design.md -> Claude integration -> Shim install, and TerminalEnvironment.swift for the env
// contract this wrapper chain assumes (`ZDOTDIR`, `TKZMUX_ZDOTDIR`, `TKZMUX_USER_ZDOTDIR`,
// `TKZMUX_BIN`).
import Foundation
import Testing

@testable import ClaudeBridge

private typealias ProcessResult = ShimTestSupport.ProcessResult
private func makeTempDirectory(_ label: String) throws -> URL {
    try ShimTestSupport.makeTempDirectory(label)
}
private func run(
    _ executable: URL, _ arguments: [String] = [], environment: [String: String]
) throws -> ProcessResult {
    try ShimTestSupport.run(executable, arguments, environment: environment)
}

private struct WrapperFixture {
    var fakeHome: URL
    var tkzmuxZdotdir: URL
    var tkzmuxBin: URL
    var log: URL
}

private func makeWrapperFixture() throws -> WrapperFixture {
    let root = try makeTempDirectory("zsh")
    let fakeHome = root.appendingPathComponent("home", isDirectory: true)
    let tkzmuxZdotdir = root.appendingPathComponent("zsh", isDirectory: true)
    let tkzmuxBin = root.appendingPathComponent("bin", isDirectory: true)
    let localBin = fakeHome.appendingPathComponent(".local/bin", isDirectory: true)
    for dir in [fakeHome, tkzmuxZdotdir, tkzmuxBin, localBin] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let log = root.appendingPathComponent("log.txt")
    FileManager.default.createFile(atPath: log.path, contents: nil)

    // The user's own dotfiles: each appends a marker, and .zshrc prepends ~/.local/bin to PATH,
    // exactly the shape the ticket's design note describes (brew shellenv / ~/.local/bin/env).
    try "echo zshenv >> \"$MARKER_LOG\"\n".write(
        to: fakeHome.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
    try "echo zprofile >> \"$MARKER_LOG\"\n".write(
        to: fakeHome.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
    try """
    echo zshrc >> "$MARKER_LOG"
    path=("$HOME/.local/bin" $path)
    export PATH
    """.write(to: fakeHome.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    try "echo zlogin >> \"$MARKER_LOG\"\n".write(
        to: fakeHome.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)

    // Install tkzmux's wrappers as dotfiles in tkzmuxZdotdir.
    let resources = try ShimResources.bundled()
    for name in ShimResources.zshFileNames {
        try (resources.zshFiles[name] ?? "").write(
            to: tkzmuxZdotdir.appendingPathComponent(".\(name)"), atomically: true, encoding: .utf8)
    }

    return WrapperFixture(
        fakeHome: fakeHome, tkzmuxZdotdir: tkzmuxZdotdir, tkzmuxBin: tkzmuxBin, log: log)
}

private func runInteractiveLoginShell(
    _ fixture: WrapperFixture, extraEnv: [String: String] = [:]
) throws -> ProcessResult {
    var env: [String: String] = [
        "HOME": fixture.fakeHome.path,
        "ZDOTDIR": fixture.tkzmuxZdotdir.path,
        "TKZMUX_ZDOTDIR": fixture.tkzmuxZdotdir.path,
        "TKZMUX_USER_ZDOTDIR": fixture.fakeHome.path,
        "TKZMUX_BIN": fixture.tkzmuxBin.path,
        "MARKER_LOG": fixture.log.path,
        "TERM": "dumb",
        "PATH": "/usr/bin:/bin",
    ]
    for (key, value) in extraEnv { env[key] = value }

    return try run(
        URL(fileURLWithPath: "/bin/zsh"),
        [
            "-l", "-i", "-c",
            "print -r -- $PATH; print -r -- $HISTFILE; print -r -- ${ZDOTDIR:-unset};"
                + " print -r -- $TKZMUX_ZDOTDIR",
        ],
        environment: env)
}

@Test func allFourUserFilesRunInOrder() throws {
    let fixture = try makeWrapperFixture()
    _ = try runInteractiveLoginShell(fixture)
    let markers = (try? String(contentsOf: fixture.log, encoding: .utf8)) ?? ""
    let lines = markers.split(separator: "\n").map(String.init)
    #expect(lines == ["zshenv", "zprofile", "zshrc", "zlogin"])
}

@Test func pathStartsWithTkzmuxBinThenUserLocalBin() throws {
    let fixture = try makeWrapperFixture()
    let result = try runInteractiveLoginShell(fixture)
    let outputLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let path = outputLines[0]
    let pathEntries = path.split(separator: ":").map(String.init)
    #expect(pathEntries.first == fixture.tkzmuxBin.path)
    #expect(pathEntries.dropFirst().first == "\(fixture.fakeHome.path)/.local/bin")
}

@Test func histfileIsRedirectedToTheUsersHome() throws {
    let fixture = try makeWrapperFixture()
    let result = try runInteractiveLoginShell(fixture)
    let outputLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let histfile = outputLines[1]
    #expect(histfile == "\(fixture.fakeHome.path)/.zsh_history")
}

@Test func zdotdirIsRestoredByZloginForNestedShells() throws {
    let fixture = try makeWrapperFixture()
    let result = try runInteractiveLoginShell(fixture)
    let outputLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    #expect(outputLines[2] == "unset")   // TKZMUX_USER_ZDOTDIR == HOME here, so zlogin unsets it
    #expect(outputLines[3] == fixture.tkzmuxZdotdir.path)   // TKZMUX_ZDOTDIR itself stays exported
}

@Test func relocatedUserZdotdirIsFollowed() throws {
    let fixture = try makeWrapperFixture()
    let relocated = fixture.fakeHome.appendingPathComponent(".config/zsh", isDirectory: true)
    try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)

    // The user's .zshenv relocates ZDOTDIR (as people do with ~/.config/zsh) and the *relocated*
    // .zprofile/.zshrc/.zlogin are what should run from here on.
    try """
    echo zshenv >> "$MARKER_LOG"
    export ZDOTDIR="\(relocated.path)"
    """.write(to: fixture.fakeHome.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
    // Remove the originals so a failure to follow the relocation shows up as a missing marker
    // rather than accidentally still passing via the old files.
    for name in [".zprofile", ".zshrc", ".zlogin"] {
        try? FileManager.default.removeItem(at: fixture.fakeHome.appendingPathComponent(name))
    }
    try "echo zprofile-relocated >> \"$MARKER_LOG\"\n".write(
        to: relocated.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
    try """
    echo zshrc-relocated >> "$MARKER_LOG"
    path=("$HOME/.local/bin" $path)
    export PATH
    """.write(to: relocated.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    try "echo zlogin-relocated >> \"$MARKER_LOG\"\n".write(
        to: relocated.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)

    _ = try runInteractiveLoginShell(fixture)
    let markers = (try? String(contentsOf: fixture.log, encoding: .utf8)) ?? ""
    let lines = markers.split(separator: "\n").map(String.init)
    #expect(lines == ["zshenv", "zprofile-relocated", "zshrc-relocated", "zlogin-relocated"])
}

@Test func withoutTkzmuxZdotdirTheWrappersDoNothing() throws {
    let fixture = try makeWrapperFixture()
    // A plain zsh under our ZDOTDIR, but with TKZMUX_ZDOTDIR unset: the wrappers must no-op
    // rather than misbehave, and in particular must not source the user's files a second time
    // or crash under `set -u`-style configs.
    var env: [String: String] = [
        "HOME": fixture.fakeHome.path,
        "ZDOTDIR": fixture.tkzmuxZdotdir.path,
        "TERM": "dumb",
        "PATH": "/usr/bin:/bin",
    ]
    env["TKZMUX_USER_ZDOTDIR"] = fixture.fakeHome.path
    let result = try run(
        URL(fileURLWithPath: "/bin/zsh"), ["-c", "print -r -- ok"], environment: env)
    #expect(result.status == 0)
    #expect(result.stdout.contains("ok"))
}

@Test func chosenAccountWinsOverTheUsersRc() throws {
    // The user's own .zshrc exports a default account; the account picked in tkzmux must win,
    // and when none was picked the user's export must survive untouched (M5.2).
    let fixture = try makeWrapperFixture()
    let rc = fixture.fakeHome.appendingPathComponent(".zshrc")
    try (String(contentsOf: rc, encoding: .utf8) + "\nexport CLAUDE_CONFIG_DIR=\"$HOME/.claude-work\"\n")
        .write(to: rc, atomically: true, encoding: .utf8)
    func configDir(_ extra: [String: String]) throws -> String {
        var env: [String: String] = [
            "HOME": fixture.fakeHome.path,
            "ZDOTDIR": fixture.tkzmuxZdotdir.path,
            "TKZMUX_ZDOTDIR": fixture.tkzmuxZdotdir.path,
            "TKZMUX_USER_ZDOTDIR": fixture.fakeHome.path,
            "TKZMUX_BIN": fixture.tkzmuxBin.path,
            "MARKER_LOG": fixture.log.path,
            "TERM": "dumb",
            "PATH": "/usr/bin:/bin",
        ]
        for (key, value) in extra { env[key] = value }
        let result = try run(
            URL(fileURLWithPath: "/bin/zsh"), ["-l", "-i", "-c", "print -r -- ${CLAUDE_CONFIG_DIR:-unset}"],
            environment: env)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #expect(try configDir([:]) == "\(fixture.fakeHome.path)/.claude-work")
    let pinned = "\(fixture.fakeHome.path)/.claude"
    #expect(try configDir(["CLAUDE_CONFIG_DIR": pinned, "TKZMUX_CLAUDE_CONFIG_DIR": pinned]) == pinned)
}


@Test func theWorkingDirectoryIsReportedAsOSC7OnStartAndOnEveryCd() throws {
    // The sidebar title follows `cd` through OSC 7 (2026-09-08). Percent-encoded path, `localhost`
    // as the host, once at startup and again after every directory change.
    let fixture = try makeWrapperFixture()
    let spaced = fixture.fakeHome.appendingPathComponent("has space", isDirectory: true)
    try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
    var env: [String: String] = [
        "HOME": fixture.fakeHome.path,
        "ZDOTDIR": fixture.tkzmuxZdotdir.path,
        "TKZMUX_ZDOTDIR": fixture.tkzmuxZdotdir.path,
        "TKZMUX_USER_ZDOTDIR": fixture.fakeHome.path,
        "TKZMUX_BIN": fixture.tkzmuxBin.path,
        "MARKER_LOG": fixture.log.path,
        "TERM": "dumb",
        "PATH": "/usr/bin:/bin",
        "TKZMUX_OSC7_TO_STDOUT": "1",
    ]
    let result = try run(
        URL(fileURLWithPath: "/bin/zsh"),
        ["-l", "-i", "-c", "cd \"$HOME/has space\"; cd /tmp; print -r -- end"],
        environment: env)
    let reports = result.stdout.components(separatedBy: "\u{1b}]7;").dropFirst()
        .map { String($0.prefix { $0 != "\u{07}" }) }
    // The startup report is wherever the shell was launched (the test process's cwd; a login zsh
    // does not cd to $HOME), then one per cd.
    #expect(reports.count == 3, "\(reports)")
    #expect(reports.first?.hasPrefix("file://localhost/") == true)
    #expect(reports.dropFirst().first == "file://localhost\(fixture.fakeHome.path)/has%20space")
    #expect(reports.last == "file://localhost/tmp" || reports.last == "file://localhost/private/tmp")

    // Piped stdout without the override: no escape bytes at all.
    env["TKZMUX_OSC7_TO_STDOUT"] = nil
    let quiet = try run(URL(fileURLWithPath: "/bin/zsh"), ["-l", "-i", "-c", "cd /tmp; print -r -- end"], environment: env)
    #expect(!quiet.stdout.contains("\u{1b}]7;"))
}

// MARK: - TKZMUX_BOOT_COMMAND

/// Acceptance (2026-09-09): the command a session is opened to run — `claude --resume <id>`, a
/// preset — actually runs in the shell.
///
/// This replaces the readiness heuristic it used to arrive by. Typing the command into the pty
/// after the spawn could not be made reliable: zsh's line editor calls `tcsetattr(…, TCSAFLUSH, …)`
/// while it starts up, discarding whatever is queued on the tty, and no dependable signal says when
/// the last such flush has happened. Sessions were observed sitting at a bare prompt with Claude
/// never started. `.zlogin` runs after every rc file and before the interactive loop, so there is
/// nothing left to flush.
@Test func bootCommandRuns() throws {
    let fixture = try makeWrapperFixture()
    let result = try runInteractiveLoginShell(
        fixture, extraEnv: ["TKZMUX_BOOT_COMMAND": "print -r -- BOOT-RAN"])
    #expect(result.stdout.contains("BOOT-RAN"), "boot command never ran: \(result.stdout)")
}

/// It must not survive into anything the command starts: `claude` itself re-execs shells, and an
/// inherited value would run the command a second time.
@Test func bootCommandIsUnsetBeforeItRuns() throws {
    let fixture = try makeWrapperFixture()
    let result = try runInteractiveLoginShell(
        fixture,
        extraEnv: ["TKZMUX_BOOT_COMMAND": "print -r -- INNER=${TKZMUX_BOOT_COMMAND:-unset}"])
    #expect(result.stdout.contains("INNER=unset"), "\(result.stdout)")
}

/// The shim has to win: `claude` in the boot command must resolve to `$TKZMUX_BIN/claude`, or the
/// resumed session runs the real binary and the row never gets its pid bound.
@Test func bootCommandSeesTkzmuxBinFirstOnPath() throws {
    let fixture = try makeWrapperFixture()
    let shim = fixture.tkzmuxBin.appendingPathComponent("claude")
    try "#!/bin/sh\n".write(to: shim, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

    let result = try runInteractiveLoginShell(
        fixture, extraEnv: ["TKZMUX_BOOT_COMMAND": "command -v claude"])
    #expect(result.stdout.contains(shim.path), "\(result.stdout)")
}

/// A `.shell` session carries no command, and the block must then do nothing at all.
@Test func noBootCommandIsANoOp() throws {
    let fixture = try makeWrapperFixture()
    let result = try runInteractiveLoginShell(fixture)
    #expect(!result.stdout.contains("BOOT-RAN"))
    let markers = (try? String(contentsOf: fixture.log, encoding: .utf8)) ?? ""
    #expect(markers.split(separator: "\n").map(String.init) == ["zshenv", "zprofile", "zshrc", "zlogin"])
}

/// A `return` in the user's own .zlogin must not skip the boot command — hence the block sitting
/// outside the wrapper's guard.
@Test func bootCommandSurvivesAReturnInTheUsersZlogin() throws {
    let fixture = try makeWrapperFixture()
    try "echo zlogin >> \"$MARKER_LOG\"\nreturn 0\n".write(
        to: fixture.fakeHome.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)
    let result = try runInteractiveLoginShell(
        fixture, extraEnv: ["TKZMUX_BOOT_COMMAND": "print -r -- BOOT-RAN"])
    #expect(result.stdout.contains("BOOT-RAN"), "\(result.stdout)")
}
