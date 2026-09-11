// LoginShell — which shell a session runs, and how tkzmux's shell integration reaches it.
// TKZ-33: the pty used to spawn `/bin/zsh -l` for everyone; now it spawns the user's login shell.
//
// The single source of truth shared by `TerminalEnvironment` (TkzTerminalCore, builds the argv and
// the environment) and `ShimInstaller` (ClaudeBridge, writes the wrapper files): both need to
// agree on where the wrappers live under the application-support directory, and neither may depend
// on the other. Pure data — no AppKit, no process spawning.
//
// One mechanism per shell family, each chosen so the wrapper runs *last*, after the user's own
// startup files, which is what lets `$TKZMUX_BIN` win the PATH race against brew shellenv and
// friends:
//
//   zsh   `ZDOTDIR` wrappers (M3.3). `-zsh -l`; the wrappers source the user's files and restore
//         ZDOTDIR for nested shells.
//   bash  `bash --rcfile <wrapper>`. `--rcfile` is honoured only by an *interactive non-login*
//         bash (`man bash`, INVOCATION: a login shell reads the profile files and ignores it), so
//         bash is spawned non-login and the wrapper sources `/etc/profile` and the user's login
//         file itself. `BASH_ENV` is read by non-interactive shells only: no use here.
//   fish  `fish -l -C 'source <wrapper>'`. `--init-command` runs after the user's configuration
//         and before the interactive loop. Deliberately *not* an `XDG_CONFIG_HOME` hijack: fish
//         keeps universal variables (`fish_user_paths`, abbreviations, colours) under its config
//         directory, and a substituted one would lose them and leak to every child process.
//   other tcsh, dash, ksh… spawned as a login shell with no wrapper; the shim reaches PATH only
//         through a best-effort prepend in the pty environment.
import Foundation

public struct LoginShell: Sendable, Equatable, Hashable {
    public enum Family: String, Sendable, CaseIterable {
        case zsh, bash, fish, other
    }

    /// One wrapper file: where it is read from in the ClaudeBridge resource bundle, and where the
    /// installer writes it, relative to the application-support directory.
    public struct WrapperFile: Sendable, Equatable, Hashable {
        /// Resource subdirectory (`"zsh"`, `"bash"`, `"fish"`).
        public var resourceDirectory: String
        /// File name inside the resource bundle, never dotted (SwiftPM resource copying of
        /// dotfiles is not relied on).
        public var resourceName: String
        /// Installed path relative to the tkzmux directory, e.g. `"zsh/.zshrc"`.
        public var installedPath: String

        public init(resourceDirectory: String, resourceName: String, installedPath: String) {
            self.resourceDirectory = resourceDirectory
            self.resourceName = resourceName
            self.installedPath = installedPath
        }

        public func url(in tkzmuxDir: URL) -> URL {
            tkzmuxDir.appending(path: installedPath, directoryHint: .notDirectory)
        }
    }

    /// Absolute path of the executable.
    public var path: String
    public var family: Family

    /// The executable's basename: `argv[0]` (dash-prefixed for a login shell) and the default
    /// pane title.
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String) {
        self.path = path
        self.family = Family(rawValue: (path as NSString).lastPathComponent) ?? .other
    }

    /// The old behaviour and the fallback: `/bin/zsh`.
    public static let zsh = LoginShell(path: "/bin/zsh")

    /// The login shell to spawn: `SHELL` from `environment`, then the account database
    /// (`getpwuid`, what `dscl . -read /Users/$USER UserShell` reports), then `/bin/zsh`. A
    /// candidate that is not an executable file is skipped — a stale `SHELL` pointing at a
    /// removed Homebrew fish must not leave the user with no terminal at all.
    public static func detect(
        environment: [String: String],
        passwordDatabaseShell: String? = LoginShell.passwordDatabaseShell(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> LoginShell {
        let candidates = [environment["SHELL"], passwordDatabaseShell]
        for case let candidate? in candidates {
            guard candidate.hasPrefix("/"), isExecutable(candidate) else { continue }
            return LoginShell(path: candidate)
        }
        return .zsh
    }

    /// `pw_shell` for the current user, or nil.
    public static func passwordDatabaseShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }

    // MARK: Wrapper layout

    /// The wrapper files each family needs, in the order an interactive login shell reads them.
    public static let wrapperFiles: [Family: [WrapperFile]] = [
        .zsh: ["zshenv", "zprofile", "zshrc", "zlogin"].map {
            WrapperFile(resourceDirectory: "zsh", resourceName: $0, installedPath: "zsh/.\($0)")
        },
        .bash: [
            WrapperFile(
                resourceDirectory: "bash", resourceName: "tkzmux.bashrc",
                installedPath: "bash/tkzmux.bashrc")
        ],
        .fish: [
            WrapperFile(
                resourceDirectory: "fish", resourceName: "tkzmux.fish",
                installedPath: "fish/tkzmux.fish")
        ],
        .other: [],
    ]

    /// Every wrapper file the installer writes, in a stable order.
    public static let allWrapperFiles: [WrapperFile] =
        Family.allCases.flatMap { wrapperFiles[$0] ?? [] }

    /// Directories under the tkzmux directory that hold wrapper files.
    public static let wrapperDirectories: [String] = ["zsh", "bash", "fish"]

    /// This family's wrapper files.
    public var wrapperFiles: [WrapperFile] { Self.wrapperFiles[family] ?? [] }

    /// The file whose presence decides whether the shell is started *with* the integration: the
    /// one the argv names for bash and fish. zsh finds its wrappers through `ZDOTDIR` and copes
    /// with an empty directory, so it has none.
    public func entryWrapper(in tkzmuxDir: URL) -> URL? {
        switch family {
        case .bash, .fish: return wrapperFiles.first?.url(in: tkzmuxDir)
        case .zsh, .other: return nil
        }
    }

    // MARK: argv

    /// The argv for the pty. Login semantics come from a dash-prefixed `argv[0]`, not from
    /// `/usr/bin/login`, so the environment handed over survives.
    ///
    /// `wrapperPresent` says whether `entryWrapper(in:)` exists on disk. When it does not (the
    /// installer has not run yet, or *Remove Shell Integration* deleted it) bash and fish get the
    /// plain login form: `bash --rcfile <missing>` and `fish -C 'source <missing>'` would each
    /// print an error into the user's terminal. That is the bash/fish equivalent of zsh finding an
    /// empty `ZDOTDIR`.
    public func argv(tkzmuxDir: URL, wrapperPresent: Bool) -> [String] {
        switch family {
        case .zsh:
            return ["-zsh", "-l"]
        case .bash:
            guard wrapperPresent, let wrapper = entryWrapper(in: tkzmuxDir) else {
                return ["-bash", "-l"]
            }
            // No leading dash and no `-l`: a login bash ignores `--rcfile` (see the header).
            return ["bash", "--rcfile", wrapper.path]
        case .fish:
            guard wrapperPresent, let wrapper = entryWrapper(in: tkzmuxDir) else {
                return ["-fish", "-l"]
            }
            return ["-fish", "-l", "-C", "source \(Self.fishQuoted(wrapper.path))"]
        case .other:
            // Dash-argv0 alone: tcsh rejects `-l` alongside any other argument, and every
            // Bourne-family shell treats the dash as the login signal.
            return ["-" + name]
        }
    }

    /// Single-quoted for fish: inside `'…'` only `\'` and `\\` are special.
    static func fishQuoted(_ path: String) -> String {
        "'" + path.replacing("\\", with: "\\\\").replacing("'", with: "\\'") + "'"
    }
}
