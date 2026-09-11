// TerminalEnvironment — the environment contract every tkzmux session runs under. M1.2 (TKZ-8);
// the user's own login shell instead of a fixed `/bin/zsh` since TKZ-33 (see `LoginShell`).
import Foundation
import TkzCore

/// Builds the environment (and the shell command line) for a session's pty.
///
/// We identify as Ghostty on purpose: we literally run Ghostty's VT, and Claude Code gates
/// Shift+Enter (kitty keyboard) and synchronized output on a `TERM_PROGRAM` allow-list.
///
/// The shell is the user's login shell (`LoginShell.detect`), spawned with login semantics from a
/// dash-prefixed argv[0] rather than `/usr/bin/login`, so the environment we hand over survives.
public enum TerminalEnvironment {
    /// Reported as `TERM_PROGRAM_VERSION`. Keep in sync with `CFBundleShortVersionString`.
    public static let version = "0.1.0"

    /// Variables the host terminal may have set that must not leak into the session: the session id
    /// belongs to whoever spawned *us*, and `TERMINFO_DIRS` could point ncurses at a different
    /// (older) xterm-ghostty than the one we ship.
    public static let strippedKeys = [
        "TERM_SESSION_ID", "TERMINFO_DIRS",
        // Claude Code stamps its own child processes with these. tkzmux manages Claude Code
        // sessions, so it is routinely launched *from* one — and `open tkzmux.app` propagates the
        // caller's environment, as does running the binary from such a shell. Inheriting them
        // hands every managed session the identity of the session that started tkzmux.
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT",
    ]

    /// Any variable with one of these prefixes is stripped too, so a marker introduced by a future
    /// Claude Code version is covered without a code change here.
    ///
    /// Why this matters beyond tidiness (found 2026-09-09, running the notarized build for M6.6):
    /// an inherited `CLAUDE_CODE_CHILD_SESSION` makes Claude Code announce *"Transcript saving is
    /// off — inherited CLAUDE_CODE_CHILD_SESSION marker"* and, believing it is a child of another
    /// session, it never publishes the `~/.claude/sessions/<pid>.json` descriptor. That descriptor's
    /// `status: busy` is the **only** source of the `working` status, so rows never turn green.
    /// Hooks are a separate path and keep working, which is why NEEDS YOU and the done tint looked
    /// fine and only the green pulse was missing — a confusing symptom for an environment leak.
    ///
    /// `CLAUDE_CONFIG_DIR` deliberately does **not** match: design.md → *Accounts are generic* says
    /// an inherited config dir is left alone so the environment can choose the account.
    public static let strippedKeyPrefixes = ["CLAUDE_CODE_"]

    /// The terminfo database shipped with tkzmux (`terminfo/78/xterm-ghostty`, `terminfo/67/ghostty`),
    /// or nil if it is missing.
    ///
    /// Two places are tried: the `TkzTerminalCore` resource bundle (what `swift run`/`swift test`
    /// see) and `Contents/Resources/terminfo` of the app bundle (what `make app` copies).
    public static var bundledTerminfoDirectory: URL? {
        let candidates = [
            ModuleResources.bundle.url(forResource: "terminfo", withExtension: nil),
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
    ///   - shell: the shell the environment is for. Defaults to the login shell `baseEnvironment`
    ///     names (`LoginShell.detect`). Only zsh gets the `ZDOTDIR` trio: set for a bash or fish
    ///     session, a nested `zsh` started from it would pick up tkzmux's wrappers.
    ///
    /// **No PATH prepend on purpose** for the shells with a wrapper: this machine's `.zshrc` ends
    /// by sourcing `~/.local/bin/env`, which prepends to PATH, so anything we set here loses. The
    /// wrapper puts `TKZMUX_BIN` on PATH *after* the user's rc files have run. A shell tkzmux has
    /// no wrapper for (tcsh, dash…) gets the prepend here, as the best that can be done.
    public static func make(
        sessionID: String,
        accountConfigDir: String? = nil,
        tkzmuxDir: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = nil,
        terminfoDirectory: URL? = TerminalEnvironment.bundledTerminfoDirectory,
        shell: LoginShell? = nil
    ) -> [String: String] {
        let shell = shell ?? LoginShell.detect(environment: baseEnvironment)
        var env = baseEnvironment
        for key in strippedKeys { env.removeValue(forKey: key) }
        // `filter` first: removing while iterating `env.keys` would mutate the collection underneath.
        for key in env.keys.filter({ name in strippedKeyPrefixes.contains(where: name.hasPrefix) }) {
            env.removeValue(forKey: key)
        }

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

        let bin = tkzmuxDir.appending(path: "bin", directoryHint: .isDirectory).path
        switch shell.family {
        case .zsh:
            let zdotdir = tkzmuxDir.appending(path: "zsh", directoryHint: .isDirectory).path
            env["ZDOTDIR"] = zdotdir
            env["TKZMUX_ZDOTDIR"] = zdotdir
            env["TKZMUX_USER_ZDOTDIR"] = userHome
        case .bash, .fish:
            break
        case .other:
            let rest = (env["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init).filter { $0 != bin }
            env["PATH"] = ([bin] + rest).joined(separator: ":")
        }
        env["TKZMUX_BIN"] = bin
        env["TKZMUX_SOCKET"] = tkzmuxDir.appending(path: "tkzmux.sock", directoryHint: .notDirectory).path
        env["TKZMUX_SESSION_ID"] = sessionID

        // Only non-primary accounts get an explicit config dir; the primary account uses ~/.claude.
        if let accountConfigDir {
            env["CLAUDE_CONFIG_DIR"] = accountConfigDir
        }

        return env
    }

    /// A ready-to-use login-shell spawn for a session.
    ///
    /// - Parameters:
    ///   - shell: defaults to the login shell `baseEnvironment` names (`LoginShell.detect`).
    ///   - wrapperPresent: whether the shell's entry wrapper exists under `tkzmuxDir`; decides
    ///     between the integrated and the plain login argv for bash and fish (see
    ///     `LoginShell.argv`). Defaults to looking at the disk.
    public static func loginShellSpawn(
        sessionID: String,
        cwd: String,
        size: TerminalSize,
        accountConfigDir: String? = nil,
        tkzmuxDir: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = nil,
        terminfoDirectory: URL? = TerminalEnvironment.bundledTerminfoDirectory,
        shell: LoginShell? = nil,
        wrapperPresent: Bool? = nil
    ) -> PtySpawn {
        let shell = shell ?? LoginShell.detect(environment: baseEnvironment)
        let wrapperPresent = wrapperPresent ?? shell.entryWrapper(in: tkzmuxDir).map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        return PtySpawn(
            executablePath: shell.path,
            argv: shell.argv(tkzmuxDir: tkzmuxDir, wrapperPresent: wrapperPresent),
            environment: make(
                sessionID: sessionID,
                accountConfigDir: accountConfigDir,
                tkzmuxDir: tkzmuxDir,
                baseEnvironment: baseEnvironment,
                home: home,
                terminfoDirectory: terminfoDirectory,
                shell: shell
            ),
            cwd: cwd,
            size: size
        )
    }
}
