#if os(Linux)
import Glibc
import Dispatch
import Foundation
import Synchronization
import Testing

import TkzCore

@testable import TkzTerminalCore

// The Linux half of the environment contract: what a desktop launch hands tkzmux that must not
// reach a pane, what a pane needs from the desktop session, the base-environment overrides, the
// `LANG` fallback and terminfo resolution in a real pane.

private func tempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "tkzmux-env-linux-tests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A hermetic host environment, bash as the shell: nothing comes from the real process env.
private func hostEnvironment(home: String) -> [String: String] {
    [
        "HOME": home,
        "SHELL": "/bin/bash",
        "PATH": "/usr/bin:/bin",
        "TERM": "xterm-256color",
        "LANG": "sv_SE.UTF-8",
    ]
}

/// Every variable a Linux launch (systemd, a launcher, another terminal) may hand tkzmux that
/// must not reach a pane, with the prefixed ones represented by real examples.
private let launchVariables = [
    "JOURNAL_STREAM": "8:123456",
    "INVOCATION_ID": "0123456789abcdef0123456789abcdef",
    "MANAGERPID": "1234",
    "MANAGERPIDFDID": "5678",
    "SYSTEMD_EXEC_PID": "4321",
    "XDG_ACTIVATION_TOKEN": "hyprland-1-token",
    "DESKTOP_STARTUP_ID": "launcher-1_TIME0",
    "GIO_LAUNCHED_DESKTOP_FILE": "/usr/share/applications/tkzmux.desktop",
    "GIO_LAUNCHED_DESKTOP_FILE_PID": "4321",
    "VTE_VERSION": "7800",
    "WINDOWID": "62914563",
    "VK_LOADER_DRIVERS_SELECT": "*radeon*",
    "KITTY_WINDOW_ID": "1",
    "KITTY_PID": "999",
    "KITTY_INSTALLATION_DIR": "/usr/lib/kitty",
    "ALACRITTY_WINDOW_ID": "94",
    "ALACRITTY_SOCKET": "/run/user/1000/Alacritty-wayland-1.sock",
    "WEZTERM_PANE": "0",
    "WEZTERM_EXECUTABLE": "/usr/bin/wezterm-gui",
    "GHOSTTY_RESOURCES_DIR": "/usr/share/ghostty",
    "GHOSTTY_SHELL_FEATURES": "cursor,title",
    "GHOSTTY_BIN_DIR": "/usr/bin",
]

/// What a pane needs from the desktop session: the display, the compositor's IPC, the session
/// bus, the agent socket, and the XDG base and session variables.
private let sessionVariables = [
    "WAYLAND_DISPLAY": "wayland-1",
    "DISPLAY": ":0",
    "HYPRLAND_INSTANCE_SIGNATURE": "abc_1700000000_123",
    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
    "SSH_AUTH_SOCK": "/run/user/1000/ssh-agent.socket",
    "XDG_RUNTIME_DIR": "/run/user/1000",
    "XDG_SESSION_TYPE": "wayland",
    "XDG_SESSION_ID": "2",
    "XDG_SESSION_CLASS": "user",
    "XDG_CURRENT_DESKTOP": "Hyprland",
    "XDG_SESSION_DESKTOP": "Hyprland",
    "XDG_CONFIG_HOME": "/home/someone/.config",
    "XDG_DATA_HOME": "/home/someone/.local/share",
    "XDG_DATA_DIRS": "/usr/local/share:/usr/share",
    "XDG_CONFIG_DIRS": "/etc/xdg",
    "XDG_STATE_HOME": "/home/someone/.local/state",
    "XDG_CACHE_HOME": "/home/someone/.cache",
    "XDG_SEAT": "seat0",
    "XDG_VTNR": "1",
]

/// Run `command` under `/bin/sh -c` on a real pty with `environment`, and return everything it
/// printed once it has exited.
private func runInPane(_ command: String, environment: [String: String], cwd: String) async throws -> String {
    let output = Mutex(Data())
    let (exits, continuation) = AsyncStream.makeStream(of: PtyExit.self)
    let pty = try Pty(
        spawn: PtySpawn(
            executablePath: "/bin/sh",
            argv: ["/bin/sh", "-c", command],
            environment: environment,
            cwd: cwd,
            size: TerminalSize(rows: 24, cols: 200)
        ),
        ioQueue: DispatchQueue(label: "tkzmux.test.env-linux"),
        onData: { data in output.withLock { $0.append(data) } },
        onExit: {
            continuation.yield($0)
            continuation.finish()
        }
    )
    defer { pty.terminate(signal: SIGKILL) }
    let timeout = Task {
        try await Task.sleep(for: .seconds(15))
        continuation.finish()
    }
    var exit: PtyExit?
    for await e in exits { exit = e }
    timeout.cancel()
    #expect(exit?.exitCode == 0, "`\(command)` did not exit cleanly: \(String(describing: exit))")
    // The pty is drained before the exit is reported, so everything printed is in by now.
    return String(decoding: output.withLock { $0 }, as: UTF8.self)
        .replacingOccurrences(of: "\r\n", with: "\n")
}

@Suite struct TerminalEnvironmentLinuxTests {
    @Test func stripsLaunchAndHostTerminalVariables() throws {
        let home = try tempDir("strip")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = TerminalEnvironment.make(
            sessionID: "S1", tkzmuxDir: home.appending(path: "support"),
            baseEnvironment: hostEnvironment(home: home.path).merging(launchVariables) { $1 },
            home: home.path
        )
        for key in launchVariables.keys.sorted() {
            #expect(env[key] == nil, "\(key) reached the pane")
        }
        // Every Linux key really is on the list, not removed by accident of the test.
        for key in TerminalEnvironment.platformStrippedKeys {
            #expect(launchVariables[key] != nil, "\(key) is stripped but not tested")
        }
        // The shared (macOS) lists come first and are unchanged.
        #expect(Array(TerminalEnvironment.strippedKeys.prefix(5)) == [
            "TERM_SESSION_ID", "TERMINFO_DIRS", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
        ])
        #expect(TerminalEnvironment.strippedKeyPrefixes.first == "CLAUDE_CODE_")
        #expect(env["TERM"] == "xterm-ghostty")
        #expect(env["TKZMUX_SESSION_ID"] == "S1")
    }

    @Test func keepsDesktopSessionVariables() throws {
        let home = try tempDir("passthrough")
        defer { try? FileManager.default.removeItem(at: home) }
        let base = hostEnvironment(home: home.path)
            .merging(sessionVariables) { $1 }
            .merging(launchVariables) { $1 }
        let env = TerminalEnvironment.make(
            sessionID: "S1", tkzmuxDir: home.appending(path: "support"),
            baseEnvironment: base, home: home.path
        )
        for (key, value) in sessionVariables.sorted(by: { $0.key < $1.key }) {
            #expect(env[key] == value, "\(key) did not pass through")
        }
        // The one XDG_* that is not the session's: the activation token was meant for our window.
        let xdg = env.keys.filter { $0.hasPrefix("XDG_") }.sorted()
        #expect(xdg == sessionVariables.keys.filter { $0.hasPrefix("XDG_") }.sorted())
        #expect(env["XDG_ACTIVATION_TOKEN"] == nil)
    }

    /// GTK has `GDK_SCALE`/`GDK_DPI_SCALE` unset by the time a pane spawns (WOR-314), so the
    /// user's values come back through `overrides`. They beat whatever was inherited, can put
    /// back a stripped key, and lose to tkzmux's own variables and the agent's.
    @Test func overridesApplyAfterStripping() throws {
        let home = try tempDir("overrides")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "support")
        var base = hostEnvironment(home: home.path)
        base["GDK_DPI_SCALE"] = "1.5"
        base["VK_LOADER_DRIVERS_SELECT"] = "*radeon*"
        let overrides = [
            "GDK_SCALE": "2",
            "GDK_DPI_SCALE": "0.5",
            "WINDOWID": "77",
            "TERM": "dumb",
            "TKZMUX_SESSION_ID": "not-ours",
            "CLAUDE_CONFIG_DIR": "/from/overrides",
        ]
        let env = TerminalEnvironment.make(
            sessionID: "S1", agentEnvironment: ["CLAUDE_CONFIG_DIR": "/from/agent"],
            tkzmuxDir: support, baseEnvironment: base, overrides: overrides, home: home.path
        )
        #expect(env["GDK_SCALE"] == "2")
        #expect(env["GDK_DPI_SCALE"] == "0.5")
        #expect(env["WINDOWID"] == "77")
        #expect(env["VK_LOADER_DRIVERS_SELECT"] == nil)
        #expect(env["TERM"] == "xterm-ghostty")
        #expect(env["TKZMUX_SESSION_ID"] == "S1")
        #expect(env["CLAUDE_CONFIG_DIR"] == "/from/agent")

        let spawn = TerminalEnvironment.loginShellSpawn(
            sessionID: "S1", cwd: home.path, size: TerminalSize(rows: 24, cols: 80),
            tkzmuxDir: support, baseEnvironment: base, overrides: ["GDK_SCALE": "2"],
            home: home.path, wrapperPresent: false
        )
        #expect(spawn.environment["GDK_SCALE"] == "2")
        // Without overrides nothing appears.
        let plain = TerminalEnvironment.make(
            sessionID: "S1", tkzmuxDir: support, baseEnvironment: base, home: home.path)
        #expect(plain["GDK_SCALE"] == nil)
    }

    /// `en_US.UTF-8` is not generated on a minimal image; glibc's built-in `C.UTF-8` always is.
    @Test func langFallbackProbesTheLocale() {
        #expect(TerminalEnvironment.pickFallbackLanguage(isAvailable: { _ in true }) == "en_US.UTF-8")
        #expect(TerminalEnvironment.pickFallbackLanguage(isAvailable: { _ in false }) == "C.UTF-8")
        #expect(TerminalEnvironment.pickFallbackLanguage(isAvailable: { $0 == "C.UTF-8" }) == "C.UTF-8")
        #expect(TerminalEnvironment.localeIsAvailable("C.UTF-8"))
        #expect(!TerminalEnvironment.localeIsAvailable("xx_YY.UTF-8"))
        #expect(
            TerminalEnvironment.fallbackLanguage
                == TerminalEnvironment.pickFallbackLanguage(isAvailable: TerminalEnvironment.localeIsAvailable))
    }

    /// With no `SHELL` and no zsh, the chain (`SHELL`, account database, `/bin/zsh`, `/bin/bash`)
    /// ends at bash, and the spawn is a bash one: no `ZDOTDIR`, bash's login argv.
    @Test func noShellAndNoZshSpawnsBash() throws {
        let home = try tempDir("nozsh")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "support")
        var base = hostEnvironment(home: home.path)
        base.removeValue(forKey: "SHELL")
        let shell = LoginShell.detect(
            environment: base, passwordDatabaseShell: nil,
            isExecutable: { $0 != "/bin/zsh" && FileManager.default.isExecutableFile(atPath: $0) }
        )
        #expect(shell.path == "/bin/bash")
        let spawn = TerminalEnvironment.loginShellSpawn(
            sessionID: "S1", cwd: home.path, size: TerminalSize(rows: 24, cols: 80),
            tkzmuxDir: support, baseEnvironment: base, home: home.path,
            shell: shell, wrapperPresent: false
        )
        #expect(spawn.executablePath == "/bin/bash")
        #expect(spawn.argv == ["-bash", "-l"])
        #expect(spawn.environment["ZDOTDIR"] == nil)
        #expect(spawn.environment["SHELL"] == nil)
    }

    /// The same on the real machine, when it has no zsh and its account database names bash (or
    /// nothing usable): the default `make`/`loginShellSpawn` path, nothing injected.
    @Test(.enabled(if: !zshAvailable && accountShellIsBashOrUnusable,
                   "needs a machine without /bin/zsh whose account shell is bash"))
    func noShellAndNoZshSpawnsBashOnThisMachine() throws {
        let home = try tempDir("nozsh-host")
        defer { try? FileManager.default.removeItem(at: home) }
        var base = hostEnvironment(home: home.path)
        base.removeValue(forKey: "SHELL")
        let spawn = TerminalEnvironment.loginShellSpawn(
            sessionID: "S1", cwd: home.path, size: TerminalSize(rows: 24, cols: 80),
            tkzmuxDir: home.appending(path: "support"), baseEnvironment: base, home: home.path,
            wrapperPresent: false
        )
        #expect(LoginShell(path: spawn.executablePath).family == .bash, "\(spawn.executablePath)")
        #expect(spawn.argv == ["-bash", "-l"])
        #expect(spawn.environment["ZDOTDIR"] == nil)
    }

    /// End to end on a real pty: the pane resolves `xterm-ghostty` from *our* terminfo (this
    /// machine may have none of its own, and `TERMINFO_DIRS` is stripped), and `tput` reads it.
    @Test func paneResolvesTheBundledTerminfo() async throws {
        let home = try tempDir("terminfo")
        defer { try? FileManager.default.removeItem(at: home) }
        let terminfo = try #require(TerminalEnvironment.bundledTerminfoDirectory)
        var base = hostEnvironment(home: home.path)
        base["TERMINFO_DIRS"] = home.appending(path: "nowhere").path
        let env = TerminalEnvironment.make(
            sessionID: "S1", tkzmuxDir: home.appending(path: "support"),
            baseEnvironment: base, home: home.path
        )
        #expect(env["TERMINFO"] == terminfo.path)
        #expect(env["TERMINFO_DIRS"] == nil)

        let output = try await runInPane(
            "infocmp -x xterm-ghostty | head -n 1; infocmp -x xterm-ghostty >/dev/null && tput colors",
            environment: env, cwd: home.path)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.last == "256", "output: \(output)")
        // The header names the file infocmp read (ncurses spells it `<TERMINFO>/./x/…`): ours, in
        // the letter layout Linux ncurses reads.
        let header = lines.first ?? ""
        #expect(header.contains("from file: \(terminfo.path)/"), "output: \(output)")
        #expect(header.hasSuffix("/x/xterm-ghostty"), "output: \(output)")
    }

    /// End to end on a real pty: a pane shows the overrides and none of the launch variables.
    @Test func paneSeesOverridesAndNoLaunchVariables() async throws {
        let home = try tempDir("pane-env")
        defer { try? FileManager.default.removeItem(at: home) }
        let base = hostEnvironment(home: home.path).merging(launchVariables) { $1 }
        #expect(base["GDK_SCALE"] == nil)
        let env = TerminalEnvironment.make(
            sessionID: "S1", tkzmuxDir: home.appending(path: "support"),
            baseEnvironment: base, overrides: ["GDK_SCALE": "2"], home: home.path
        )

        let echoed = try await runInPane("echo $GDK_SCALE", environment: env, cwd: home.path)
        #expect(echoed == "2\n", "output: \(echoed)")

        let printed = try await runInPane("env", environment: env, cwd: home.path)
        var seen: [String: String] = [:]
        for line in printed.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            seen[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        for key in launchVariables.keys.sorted() {
            #expect(seen[key] == nil, "\(key) reached the pane")
        }
        #expect(seen["TERM"] == "xterm-ghostty", "output: \(printed)")
        #expect(seen["GDK_SCALE"] == "2", "output: \(printed)")
    }
}

/// Whether the account database names bash, or a shell `LoginShell.detect` would skip.
private let accountShellIsBashOrUnusable: Bool = {
    guard let path = LoginShell.passwordDatabaseShell(), path.hasPrefix("/"),
        FileManager.default.isExecutableFile(atPath: path)
    else { return true }
    return LoginShell(path: path).family == .bash
}()
#endif
