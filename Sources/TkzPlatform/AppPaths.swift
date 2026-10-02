// AppPaths — where tkzmux keeps its own files, per OS (WOR-304 S3; table in docs/linux/platform.md).
//
//   support  user data: `state.json`, `sessions/`, `usage/`, `statusline/`, `bin/`, `zsh/`,
//            `terminfo/`. Never the installed read-only tree (`<prefix>/lib/tkzmux/`, found by
//            ResourceLocator), so `make install` and ShimInstaller never write the same files.
//   cache    regenerable files.
//   runtime  per-login files such as the hook socket; `support` when there is no runtime directory.
//
// macOS keeps exactly the paths it had before this type existed: `.applicationSupportDirectory`
// (falling back to `~/Library/Application Support`) plus `tkzmux`, and `runtime` is `support`.
//
// Linux follows the XDG Base Directory spec and resolves it here rather than through
// `FileManager.url(for:in:)`: an XDG variable that is unset, empty or relative is ignored, as the
// spec requires, and `$HOME` is honoured. Corelibs Foundation does neither consistently (verified
// with Swift 6.3.3, see docs/linux/platform.md): `NSHomeDirectory()` ignores `$HOME`, and a
// relative `$XDG_DATA_HOME` falls back to `$HOME/.local/share` even when `$HOME` is relative too.
//
// The resolution itself is a pure function of the environment (`xdgLayout`), so the path table is
// tested on both OSes; only `home`, `runtime`'s mkdir and the public accessors touch the system.

import Foundation
#if os(Linux)
import Glibc
#endif

public enum AppPaths {
    /// The directory every root gets for tkzmux.
    public static let directoryName = "tkzmux"

    // MARK: Home

    /// The user's home directory. Linux: `$HOME` when it is absolute, otherwise the account
    /// database (`getpwuid`). macOS: `NSHomeDirectory()`, as before.
    public static var home: URL {
        #if os(Linux)
        URL(fileURLWithPath: resolvedHome(
            environment: ProcessInfo.processInfo.environment,
            passwordDatabaseHome: passwordDatabaseHome()), isDirectory: true)
        #else
        URL(fileURLWithPath: NSHomeDirectory())
        #endif
    }

    /// `$HOME` if absolute, else the account database's home if absolute, else `/`. The database
    /// is only consulted when `$HOME` does not answer (`getpwuid` returns static storage).
    static func resolvedHome(
        environment: [String: String], passwordDatabaseHome: @autoclosure () -> String?
    ) -> String {
        if let home = environment["HOME"], home.hasPrefix("/") { return home }
        if let home = passwordDatabaseHome(), home.hasPrefix("/") { return home }
        return "/"
    }

    /// `pw_dir` for the current user, or nil.
    static func passwordDatabaseHome() -> String? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        let path = String(cString: directory)
        return path.isEmpty ? nil : path
    }

    // MARK: Roots

    /// The user-data directory. Not created here.
    public static var support: URL { support(fileManager: .default) }

    /// `support`, with the Mac's application-support lookup going through `fileManager` (the seam
    /// `StateFile.standard` and `SnapshotStore.standard` already had). Linux ignores `fileManager`.
    public static func support(fileManager: FileManager) -> URL {
        #if os(Linux)
        return currentLayout().support
        #else
        let base = (try? fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false
            ))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: directoryName, directoryHint: .isDirectory)
        #endif
    }

    /// The cache directory: `$XDG_CACHE_HOME/tkzmux` on Linux, `~/Library/Caches/tkzmux` on
    /// macOS. Not created here.
    public static var cache: URL {
        #if os(Linux)
        return currentLayout().cache
        #else
        let base = (try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            ))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Caches")
        return base.appending(path: directoryName, directoryHint: .isDirectory)
        #endif
    }

    /// The runtime directory. Linux: `$XDG_RUNTIME_DIR/tkzmux`, created 0700 on first use; when
    /// `$XDG_RUNTIME_DIR` is unset or relative, or the directory cannot be made private to this
    /// user, `support`. macOS: `support`, as before.
    public static var runtime: URL {
        #if os(Linux)
        let layout = currentLayout()
        if let runtime = layout.runtime, makePrivateDirectory(atPath: runtime.path) { return runtime }
        return layout.support
        #else
        return support
        #endif
    }

    // MARK: Tilde

    /// `path` with a leading home directory written `~`, for display. Replaces
    /// `NSString.abbreviatingWithTildeInPath`, which corelibs Foundation does not have; macOS still
    /// calls it, so the Mac's output is unchanged.
    public static func abbreviatingHome(_ path: String) -> String {
        #if os(Linux)
        abbreviatingHome(path, home: home.path)
        #else
        (path as NSString).abbreviatingWithTildeInPath
        #endif
    }

    /// `~` for `home` itself, `~/rest` for a path under it, anything else unchanged. A home of `/`
    /// abbreviates nothing.
    static func abbreviatingHome(_ path: String, home: String) -> String {
        var home = home
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard home != "/", path.hasPrefix(home) else { return path }
        let rest = path.dropFirst(home.count)
        if rest.isEmpty || rest == "/" { return "~" }
        return rest.hasPrefix("/") ? "~" + rest : path
    }

    // MARK: XDG

    /// The Linux path table for one environment. Pure, so it is tested on both OSes.
    struct XDGLayout: Equatable {
        var home: URL
        var support: URL
        var cache: URL
        /// `$XDG_RUNTIME_DIR/tkzmux`, or nil when the variable is unset or relative.
        var runtime: URL?
    }

    /// Resolves the XDG roots. `home` is used for the defaults; an unset, empty or relative
    /// variable counts as unset (XDG Base Directory spec).
    static func xdgLayout(environment: [String: String], home: String) -> XDGLayout {
        func absolute(_ name: String) -> URL? {
            guard let value = environment[name], value.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        let data = absolute("XDG_DATA_HOME") ?? homeURL.appending(path: ".local/share", directoryHint: .isDirectory)
        let cache = absolute("XDG_CACHE_HOME") ?? homeURL.appending(path: ".cache", directoryHint: .isDirectory)
        return XDGLayout(
            home: homeURL,
            support: data.appending(path: directoryName, directoryHint: .isDirectory),
            cache: cache.appending(path: directoryName, directoryHint: .isDirectory),
            runtime: absolute("XDG_RUNTIME_DIR")?.appending(path: directoryName, directoryHint: .isDirectory))
    }

    #if os(Linux)
    static func currentLayout() -> XDGLayout {
        let environment = ProcessInfo.processInfo.environment
        let home = resolvedHome(environment: environment, passwordDatabaseHome: passwordDatabaseHome())
        return xdgLayout(environment: environment, home: home)
    }
    #endif

    /// Makes `path` a directory only this user can use: created 0700 if missing; if it exists it
    /// must be a directory (not a symlink) owned by this user, and is narrowed to 0700. The parent
    /// is never created: a missing `$XDG_RUNTIME_DIR` means "no runtime directory".
    static func makePrivateDirectory(atPath path: String) -> Bool {
        if mkdir(path, 0o700) == 0 { return true }
        guard errno == EEXIST else { return false }
        var info = stat()
        guard lstat(path, &info) == 0,
            info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == geteuid()
        else { return false }
        if info.st_mode & 0o077 != 0 { return chmod(path, 0o700) == 0 }
        return true
    }
}
