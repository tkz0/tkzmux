// TerminalEnvironment — the environment contract every tkzmux session runs under.
// See docs/design.md → Terminal engine → Pty. M1.2 (TKZ-8).
import Foundation

/// Builds the environment (and the shell command line) for a session's pty.
///
/// We identify as Ghostty on purpose: we literally run Ghostty's VT, and Claude Code gates
/// Shift+Enter (kitty keyboard) and synchronized output on a `TERM_PROGRAM` allow-list.
public enum TerminalEnvironment {
    /// Reported as `TERM_PROGRAM_VERSION`. Keep in sync with `CFBundleShortVersionString`.
    public static let version = "0.1.0"

    /// The shell we spawn. Login semantics come from `-l` + an argv[0] starting with `-`, not from
    /// `/usr/bin/login`, so the environment we hand over survives.
    public static let shellPath = "/bin/zsh"
    public static let shellArgv = ["-zsh", "-l"]

    /// Variables the host terminal may have set that must not leak into the session: the session id
    /// belongs to whoever spawned *us*, and `TERMINFO_DIRS` could point ncurses at a different
    /// (older) xterm-ghostty than the one we ship.
    public static let strippedKeys = ["TERM_SESSION_ID", "TERMINFO_DIRS"]

    /// The terminfo database shipped with tkzmux (`terminfo/78/xterm-ghostty`, `terminfo/67/ghostty`),
    /// or nil if it is missing.
    ///
    /// Two places are tried: the `TkzTerminalCore` resource bundle (what `swift run`/`swift test`
    /// see) and `Contents/Resources/terminfo` of the app bundle (what `make app` copies).
    public static var bundledTerminfoDirectory: URL? {
        let candidates = [
            Bundle.module.url(forResource: "terminfo", withExtension: nil),
            Bundle.main.resourceURL?.appending(path: "terminfo", directoryHint: .isDirectory),
        ]
        for case let url? in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
               FileManager.default.fileExists(atPath: url.appending(path: "78/xterm-ghostty").path) {
                return url
            }
        }
        return nil
    }

    /// Build the environment for one session.
    ///
    /// - Parameters:
    ///   - sessionID: tkzmux's own session id (`TKZMUX_SESSION_ID`).
    ///   - accountConfigDir: `CLAUDE_CONFIG_DIR` for a *non-primary* Claude account; nil for the
    ///     primary account, where Claude Code's own default (`~/.claude`) must win.
    ///   - tkzmuxDir: tkzmux's application-support directory; `zsh/`, `bin/` and `tkzmux.sock`
    ///     inside it are handed to the shell.
    ///   - baseEnvironment: what to inherit. Injectable so tests never depend on the real process env.
    ///   - home: the user's home directory (`TKZMUX_USER_ZDOTDIR`). Defaults to `HOME` from
    ///     `baseEnvironment`, then to `NSHomeDirectory()`.
    ///   - terminfoDirectory: overrides the bundled terminfo database (tests, or a bundle-less build).
    ///
    /// **No PATH prepend on purpose**: this machine's `.zshrc` ends by sourcing `~/.local/bin/env`,
    /// which prepends to PATH, so anything we set here loses. The `ZDOTDIR` wrapper (M3.3) puts
    /// `TKZMUX_BIN` on PATH *after* the user's rc files have run.
    public static func make(
        sessionID: String,
        accountConfigDir: String? = nil,
        tkzmuxDir: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = nil,
        terminfoDirectory: URL? = TerminalEnvironment.bundledTerminfoDirectory
    ) -> [String: String] {
        var env = baseEnvironment
        for key in strippedKeys { env.removeValue(forKey: key) }

        let userHome = home ?? baseEnvironment["HOME"] ?? NSHomeDirectory()

        env["TERM"] = "xterm-ghostty"
        env["TERM_PROGRAM"] = "ghostty"
        env["TERM_PROGRAM_VERSION"] = version
        env["COLORTERM"] = "truecolor"
        // Missing terminfo is survivable (the system copy, if any, is used): don't set a broken path.
        if let terminfoDirectory {
            env["TERMINFO"] = terminfoDirectory.path
        }
        env["LANG"] = baseEnvironment["LANG"] ?? "en_US.UTF-8"

        let zdotdir = tkzmuxDir.appending(path: "zsh", directoryHint: .isDirectory).path
        env["ZDOTDIR"] = zdotdir
        env["TKZMUX_ZDOTDIR"] = zdotdir
        env["TKZMUX_USER_ZDOTDIR"] = userHome
        env["TKZMUX_BIN"] = tkzmuxDir.appending(path: "bin", directoryHint: .isDirectory).path
        env["TKZMUX_SOCKET"] = tkzmuxDir.appending(path: "tkzmux.sock", directoryHint: .notDirectory).path
        env["TKZMUX_SESSION_ID"] = sessionID

        // Only non-primary accounts get an explicit config dir; the primary account uses ~/.claude.
        if let accountConfigDir {
            env["CLAUDE_CONFIG_DIR"] = accountConfigDir
        }

        return env
    }

    /// A ready-to-use login-zsh spawn for a session.
    public static func loginShellSpawn(
        sessionID: String,
        cwd: String,
        size: TerminalSize,
        accountConfigDir: String? = nil,
        tkzmuxDir: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = nil,
        terminfoDirectory: URL? = TerminalEnvironment.bundledTerminfoDirectory
    ) -> PtySpawn {
        PtySpawn(
            executablePath: shellPath,
            argv: shellArgv,
            environment: make(
                sessionID: sessionID,
                accountConfigDir: accountConfigDir,
                tkzmuxDir: tkzmuxDir,
                baseEnvironment: baseEnvironment,
                home: home,
                terminfoDirectory: terminfoDirectory
            ),
            cwd: cwd,
            size: size
        )
    }
}
