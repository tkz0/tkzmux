// ShimInstaller — writes one shim per agent and the shell wrappers into tkzmux's application
// support directory. See Sources/AgentBridge/Resources/{shim,zsh,bash,fish} and `LoginShell`
// (TkzCore) for the layout both this and the pty agree on. Never touches ~/.claude/settings.json.
//
// Layout written under `directory` (normally
// `~/Library/Application Support/tkzmux`):
//     bin/claude              0755  the shim, from Resources/shim/claude.sh
//     bin/codex               0755  the shim, from Resources/shim/codex.sh
//     bin/tkzmux-hook         0755  copied from `hookBinary`
//     zsh/.zshenv             0644  the ZDOTDIR wrappers (M3.3)
//     zsh/.zprofile           0644
//     zsh/.zshrc              0644
//     zsh/.zlogin             0644
//     bash/tkzmux.bashrc      0644  `bash --rcfile`
//     fish/tkzmux.fish        0644  `fish -C 'source …'`
//     VERSION                 0644  content hash; see `version(resources:hookBinary:)`
//
// `bin/` holds one shim per file under `Resources/shim/*.sh` — today `claude` and `codex` — so
// adding an agent's wrapper later means dropping a new `Resources/shim/<name>.sh` in place and
// nothing else here.
//
// `zsh/` may already exist and be empty: `TerminalViewHost` creates it at startup so a login zsh
// spawned before the installer runs still finds *a* ZDOTDIR (see TerminalHost.swift).
import Foundation
import CryptoKit
import TkzCore

public enum ShimInstallerError: Error, Equatable, Sendable {
    case resourceMissing(String)
    case writeFailed(path: String, errno: Int32)
}

/// The content the installer writes: every shim script keyed by the binary name it is installed
/// under in `bin/` (`"claude"`, `"codex"`), and every shell wrapper keyed by the path it is
/// installed at relative to the tkzmux directory (`"zsh/.zshrc"`, `"bash/tkzmux.bashrc"`).
public struct ShimResources: Sendable {
    public var shimScripts: [String: String]
    public var wrappers: [String: String]

    public init(shimScripts: [String: String], wrappers: [String: String]) {
        self.shimScripts = shimScripts
        self.wrappers = wrappers
    }

    /// Loads the shim and wrapper contents from this module's resource bundle. Works both under
    /// `swift test`/`swift run` and inside `build/tkzmux.app` (`ModuleResources`).
    ///
    /// Every `Resources/shim/*.sh` is picked up automatically (`bundle.urls(forResourcesWithExtension:)`
    /// lists the whole directory) rather than a hard-coded `["claude", "codex"]`: the binary name is
    /// just the file's basename with `.sh` dropped, which is already the naming convention
    /// `ShimResource` (AgentAdapter.swift) assumes, so a future agent's shim needs no change here —
    /// only the new `.sh` file and its adapter.
    public static func bundled() throws -> ShimResources {
        let bundle = ModuleResources.bundle

        let shimURLs = bundle.urls(forResourcesWithExtension: "sh", subdirectory: "shim") ?? []
        guard !shimURLs.isEmpty else {
            throw ShimInstallerError.resourceMissing("shim/*.sh")
        }
        var shimScripts: [String: String] = [:]
        for url in shimURLs {
            let binaryName = url.deletingPathExtension().lastPathComponent
            shimScripts[binaryName] = try String(contentsOf: url, encoding: .utf8)
        }

        var wrappers: [String: String] = [:]
        for file in LoginShell.allWrapperFiles {
            guard let url = bundle.url(
                forResource: file.resourceName, withExtension: nil,
                subdirectory: file.resourceDirectory)
            else {
                throw ShimInstallerError.resourceMissing(
                    "\(file.resourceDirectory)/\(file.resourceName)")
            }
            wrappers[file.installedPath] = try String(contentsOf: url, encoding: .utf8)
        }
        return ShimResources(shimScripts: shimScripts, wrappers: wrappers)
    }

    /// Un-dotted zsh resource names, in the order an interactive login zsh reads the wrappers.
    public static let zshFileNames: [String] =
        (LoginShell.wrapperFiles[.zsh] ?? []).map(\.resourceName)

    /// The zsh wrappers keyed by their un-dotted name (`"zshenv"` -> content of `.zshenv`).
    public var zshFiles: [String: String] {
        var files: [String: String] = [:]
        for file in LoginShell.wrapperFiles[.zsh] ?? [] {
            if let content = wrappers[file.installedPath] { files[file.resourceName] = content }
        }
        return files
    }

    /// The wrapper content for one shell family's entry file (`bash/tkzmux.bashrc`, …), if any.
    public func wrapper(for family: LoginShell.Family) -> String? {
        guard let file = LoginShell.wrapperFiles[family]?.first else { return nil }
        return wrappers[file.installedPath]
    }
}

public enum ShimInstallOutcome: Sendable, Equatable {
    case installed
    case upToDate
    case updated
}

public struct ShimInstaller: Sendable {
    public var directory: URL
    public var hookBinary: URL
    public var resources: ShimResources

    public init(directory: URL, hookBinary: URL, resources: ShimResources) {
        self.directory = directory
        self.hookBinary = hookBinary
        self.resources = resources
    }

    /// `Contents/MacOS/tkzmux-hook` next to the running executable — true both inside
    /// `build/tkzmux.app` and under `swift run` (the executable's own directory).
    public static func standardHookBinary() -> URL {
        Bundle.main.executableURL!
            .deletingLastPathComponent()
            .appendingPathComponent("tkzmux-hook")
    }

    /// Content-derived install version: a SHA-256 over every shim script, every shell wrapper, and
    /// the hook binary's size + modification time. Bump-free — any edit to a resource, a new shim,
    /// or a rebuilt hook binary changes this automatically, so `ensureInstalled()` stays idempotent
    /// without a hand-maintained version constant.
    ///
    /// Shim names are hashed in **sorted** order: `resources.shimScripts` is a `Dictionary`, whose
    /// iteration order is not guaranteed to be stable, and the version must not depend on it — an
    /// installer that hashed in dictionary order could see a different digest on every launch and
    /// rewrite `bin/` and every wrapper each time, defeating the whole point of `.upToDate`.
    public static func version(
        resources: ShimResources, hookBinary: URL, fileManager: FileManager = .default
    ) -> String {
        var hasher = SHA256()
        for name in resources.shimScripts.keys.sorted() {
            hasher.update(data: Data(name.utf8))
            hasher.update(data: Data((resources.shimScripts[name] ?? "").utf8))
        }
        for file in LoginShell.allWrapperFiles {
            hasher.update(data: Data(file.installedPath.utf8))
            hasher.update(data: Data((resources.wrappers[file.installedPath] ?? "").utf8))
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: hookBinary.path) {
            let size = (attributes[.size] as? UInt64) ?? 0
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            hasher.update(data: Data("\(size):\(mtime)".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private var binDirectory: URL { directory.appendingPathComponent("bin", isDirectory: true) }
    private var wrapperDirectories: [URL] {
        LoginShell.wrapperDirectories.map { directory.appendingPathComponent($0, isDirectory: true) }
    }
    private var versionURL: URL { directory.appendingPathComponent("VERSION", isDirectory: false) }
    private func shimURL(_ name: String) -> URL {
        binDirectory.appendingPathComponent(name, isDirectory: false)
    }
    private var hookDestinationURL: URL {
        binDirectory.appendingPathComponent("tkzmux-hook", isDirectory: false)
    }

    public var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hookDestinationURL.path), fm.fileExists(atPath: versionURL.path)
        else { return false }
        for name in resources.shimScripts.keys where !fm.fileExists(atPath: shimURL(name).path) {
            return false
        }
        for file in LoginShell.allWrapperFiles
        where !fm.fileExists(atPath: file.url(in: directory).path) {
            return false
        }
        return true
    }

    /// Writes everything, or confirms it is already current. Idempotent: a second call with the
    /// same resources and the same hook binary rewrites nothing.
    @discardableResult
    public func ensureInstalled(fileManager: FileManager = .default) throws -> ShimInstallOutcome {
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        for wrapperDirectory in wrapperDirectories {
            try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        }

        let newVersion = Self.version(
            resources: resources, hookBinary: hookBinary, fileManager: fileManager)
        let existingVersion = try? String(contentsOf: versionURL, encoding: .utf8)
        let wasInstalled = existingVersion != nil

        if existingVersion == newVersion && isInstalled {
            return .upToDate
        }

        for name in resources.shimScripts.keys.sorted() {
            try Self.writeAtomically(
                Data((resources.shimScripts[name] ?? "").utf8), to: shimURL(name), permissions: 0o755,
                fileManager: fileManager)
        }
        try Self.copyAtomically(
            from: hookBinary, to: hookDestinationURL, permissions: 0o755, fileManager: fileManager)
        for file in LoginShell.allWrapperFiles {
            try Self.writeAtomically(
                Data((resources.wrappers[file.installedPath] ?? "").utf8),
                to: file.url(in: directory), permissions: 0o644, fileManager: fileManager)
        }
        try Self.writeAtomically(
            Data(newVersion.utf8), to: versionURL, permissions: 0o644, fileManager: fileManager)

        return wasInstalled ? .updated : .installed
    }

    /// Deletes only what the installer itself wrote: `bin/`, the wrapper directories (`zsh/`,
    /// `bash/`, `fish/`), `VERSION`. Never touches `sessions/`, `state.json`/`state.json.bak`, or
    /// the instance sockets (`tkzmux-<pid>.sock`).
    public func remove(fileManager: FileManager = .default) throws {
        for url in [binDirectory] + wrapperDirectories + [versionURL] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: Atomic writes (write-to-temp + rename, same directory so it can't cross a mount)

    static func writeAtomically(
        _ data: Data, to url: URL, permissions: Int, fileManager: FileManager
    ) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UInt64.random(in: 0..<UInt64.max)).tmp")
        do {
            try data.write(to: temporary)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        guard rename(from: temporary, to: url) else {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw ShimInstallerError.writeFailed(path: url.path, errno: code)
        }
    }

    private static func copyAtomically(
        from source: URL, to destination: URL, permissions: Int, fileManager: FileManager
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UInt64.random(in: 0..<UInt64.max)).tmp")
        try? fileManager.removeItem(at: temporary)
        do {
            try fileManager.copyItem(at: source, to: temporary)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        guard rename(from: temporary, to: destination) else {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw ShimInstallerError.writeFailed(path: destination.path, errno: code)
        }
    }

    static func rename(from source: URL, to destination: URL) -> Bool {
        source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { errno = EINVAL; return false }
                return Foundation.rename(from, to) == 0
            }
        }
    }
}
