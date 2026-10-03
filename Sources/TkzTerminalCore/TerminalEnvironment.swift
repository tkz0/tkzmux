// TerminalEnvironment — the environment contract every tkzmux session runs under. M1.2;
// the user's own login shell instead of a fixed `/bin/zsh` since the login-shell work (see `LoginShell`).
import Foundation
import TkzCore
#if os(Linux)
import Glibc
#endif

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
    ] + platformStrippedKeys

    /// Any variable with one of these prefixes is stripped too, so a marker introduced by a future
    /// Claude Code version is covered without a code change here.
    ///
    /// Deliberately hard-coded to Claude rather than driven by `AgentAdapter` (TKZ-82): this is
    /// hygiene against whatever spawned *us*, not something the row's own chosen agent decides, and
    /// `make` runs before any agent is chosen at all — a plain ⌘T shell has no agent to ask. It
    /// would look like an oversight if it stayed unexplained once `agentEnvironment` (below) made
    /// everything else here generic.
    ///
    /// Why this matters beyond tidiness (found 2026-09-09, running the notarized build for M6.6):
    /// an inherited `CLAUDE_CODE_CHILD_SESSION` makes Claude Code announce *"Transcript saving is
    /// off — inherited CLAUDE_CODE_CHILD_SESSION marker"* and, believing it is a child of another
    /// session, it never publishes the `~/.claude/sessions/<pid>.json` descriptor. That descriptor's
    /// `status: busy` is the **only** source of the `working` status, so rows never turn green.
    /// Hooks are a separate path and keep working, which is why NEEDS YOU and the done tint looked
    /// fine and only the green pulse was missing — a confusing symptom for an environment leak.
    ///
    /// `CLAUDE_CONFIG_DIR` deliberately does **not** match: an inherited config dir is left alone
    /// so the environment can choose the account.
    public static let strippedKeyPrefixes = ["CLAUDE_CODE_"] + platformStrippedKeyPrefixes

    #if os(Linux)
    /// What a Linux launch hands *us* that describes our own process or whatever started it, and
    /// would be wrong in every pane:
    /// - systemd's per-unit markers: they name tkzmux's unit (or the launcher's), not the pane's.
    /// - the launch's activation token and startup id: single-use, and meant for our window.
    /// - the identity of a host terminal (VTE, an X11 `WINDOWID`); the prefixes cover the rest.
    /// - `VK_LOADER_DRIVERS_SELECT`, which the release launcher may set to pin our renderer's
    ///   Vulkan driver (WOR-323): a GPU program run in a pane picks its own.
    static let platformStrippedKeys = [
        "JOURNAL_STREAM", "INVOCATION_ID", "MANAGERPID", "MANAGERPIDFDID", "SYSTEMD_EXEC_PID",
        "XDG_ACTIVATION_TOKEN", "DESKTOP_STARTUP_ID",
        "GIO_LAUNCHED_DESKTOP_FILE", "GIO_LAUNCHED_DESKTOP_FILE_PID",
        "VTE_VERSION", "WINDOWID",
        "VK_LOADER_DRIVERS_SELECT",
    ]

    /// A host terminal's own variables (window ids, control sockets, resource dirs). Inherited, they
    /// point a pane's tools at a terminal that is not the one they run in; `GHOSTTY_*` most of
    /// all, since a pane identifies as Ghostty and Ghostty's shell integration keys on them.
    static let platformStrippedKeyPrefixes = ["KITTY_", "ALACRITTY_", "WEZTERM_", "GHOSTTY_"]
    #else
    static let platformStrippedKeys: [String] = []
    static let platformStrippedKeyPrefixes: [String] = []
    #endif

    /// `LANG` when the inherited environment has none. macOS always has `en_US.UTF-8`; a minimal
    /// Linux image may not have generated it, and naming a missing locale leaves every child on
    /// the ASCII `C` locale with a warning, so Linux falls back to glibc's built-in `C.UTF-8`.
    #if os(Linux)
    static let fallbackLanguage = pickFallbackLanguage(isAvailable: localeIsAvailable)
    #else
    static let fallbackLanguage = "en_US.UTF-8"
    #endif

    #if os(Linux)
    static func pickFallbackLanguage(isAvailable: (String) -> Bool) -> String {
        isAvailable("en_US.UTF-8") ? "en_US.UTF-8" : "C.UTF-8"
    }

    /// Whether glibc can load `name`. Only the `LC_CTYPE` category is asked for: `LC_ALL_MASK` is
    /// a macro Swift cannot import, and the character set is what a UTF-8 `LANG` is for.
    static func localeIsAvailable(_ name: String) -> Bool {
        guard let locale = newlocale(LC_CTYPE_MASK, name, nil) else { return false }
        freelocale(locale)
        return true
    }
    #endif

    /// The terminfo database shipped with tkzmux, or nil if it is missing.
    ///
    /// The same compiled entries are committed in two directory layouts: hex (`78/xterm-ghostty`,
    /// `67/ghostty`), which macOS ncurses reads, and letter (`x/xterm-ghostty`, `g/ghostty`), which
    /// Linux ncurses reads. A directory with either layout is accepted
    /// (`ResourceLocator.terminfoDirectory(in:)`). `make vendor` writes both.
    ///
    /// The `terminfo` directory is looked for in the `TkzTerminalCore` resource bundle first (what
    /// `swift run`/`swift test` see), then in each `ResourceLocator` candidate: on macOS that is
    /// `Contents/Resources/terminfo` of the app bundle (what `make app` copies), on Linux also the
    /// install's `<prefix>/lib/tkzmux/terminfo`.
    public static var bundledTerminfoDirectory: URL? {
        let directories = [ModuleResources.bundle.resourceURL].compactMap { $0 }
            + ResourceLocator.current.candidateDirectories
        return directories.lazy.compactMap(ResourceLocator.terminfoDirectory(in:)).first
    }

    /// Build the environment for one session.
    ///
    /// - Parameters:
    ///   - sessionID: tkzmux's own session id (`TKZMUX_SESSION_ID`).
    ///   - agentEnvironment: whatever variables the row's chosen agent needs to find its account —
    ///     `CLAUDE_CONFIG_DIR` from `ClaudeAdapter.environment(configDir:)` for a non-primary Claude
    ///     account, empty for the primary account (where Claude Code's own default wins) or for a
    ///     plain shell with no agent at all. Merged in last, so it wins over anything inherited.
    ///   - tkzmuxDir: tkzmux's application-support directory; `zsh/`, `bin/` and this instance's
    ///     hook socket inside it are handed to the shell.
    ///   - instancePID: the running app's pid, which names the hook socket (`HookSocket`): every
    ///     instance listens on its own, so a pane's frames come back to the instance that spawned
    ///     it and never to another tkzmux sharing the directory.
    ///   - baseEnvironment: what to inherit. Injectable so tests never depend on the real process env.
    ///   - overrides: set on top of `baseEnvironment` after the strip lists are applied, so they
    ///     reach the child even when the process environment no longer has them (Linux unsets
    ///     `GDK_SCALE`/`GDK_DPI_SCALE` before GTK starts and hands the user's values back here).
    ///     tkzmux's own variables and `agentEnvironment` still win over them.
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
        agentEnvironment: [String: String] = [:],
        tkzmuxDir: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:],
        home: String? = nil,
        terminfoDirectory: URL? = TerminalEnvironment.bundledTerminfoDirectory,
        shell: LoginShell? = nil,
        instancePID: pid_t = getpid()
    ) -> [String: String] {
        let shell = shell ?? LoginShell.detect(environment: baseEnvironment)
        var env = baseEnvironment
        for key in strippedKeys { env.removeValue(forKey: key) }
        // `filter` first: removing while iterating `env.keys` would mutate the collection underneath.
        for key in env.keys.filter({ name in strippedKeyPrefixes.contains(where: name.hasPrefix) }) {
            env.removeValue(forKey: key)
        }
        for (key, value) in overrides { env[key] = value }

        let userHome = home ?? baseEnvironment["HOME"] ?? NSHomeDirectory()

        env["TERM"] = "xterm-ghostty"
        env["TERM_PROGRAM"] = "ghostty"
        env["TERM_PROGRAM_VERSION"] = version
        env["COLORTERM"] = "truecolor"
        // Missing terminfo is survivable (the system copy, if any, is used): don't set a broken path.
        if let terminfoDirectory {
            env["TERMINFO"] = terminfoDirectory.path
        }
        env["LANG"] = env["LANG"] ?? fallbackLanguage

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
        env["TKZMUX_SOCKET"] = HookSocket.url(in: tkzmuxDir, pid: instancePID).path
        env["TKZMUX_SESSION_ID"] = sessionID

        // Whatever the row's chosen agent needs to find its account, merged in last so it wins over
        // anything inherited. Empty for the primary account of whichever agent this is (its own
        // default already wins) and for a plain shell with no agent at all.
        for (key, value) in agentEnvironment { env[key] = value }

        return env
    }

    /// A ready-to-use login-shell spawn for a session.
    ///
    /// - Parameters:
    ///   - shell: defaults to the login shell `baseEnvironment` names (`LoginShell.detect`).
    ///   - overrides: see `make`; they do not take part in choosing the shell.
    ///   - wrapperPresent: whether the shell's entry wrapper exists under `tkzmuxDir`; decides
    ///     between the integrated and the plain login argv for bash and fish (see
    ///     `LoginShell.argv`). Defaults to looking at the disk.
    public static func loginShellSpawn(
        sessionID: String,
        cwd: String,
        size: TerminalSize,
        agentEnvironment: [String: String] = [:],
        tkzmuxDir: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:],
        home: String? = nil,
        terminfoDirectory: URL? = TerminalEnvironment.bundledTerminfoDirectory,
        shell: LoginShell? = nil,
        wrapperPresent: Bool? = nil,
        instancePID: pid_t = getpid()
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
                agentEnvironment: agentEnvironment,
                tkzmuxDir: tkzmuxDir,
                baseEnvironment: baseEnvironment,
                overrides: overrides,
                home: home,
                terminfoDirectory: terminfoDirectory,
                shell: shell,
                instancePID: instancePID
            ),
            cwd: cwd,
            size: size
        )
    }
}
