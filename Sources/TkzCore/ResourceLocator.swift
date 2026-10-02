// ResourceLocator — where tkzmux's read-only resources live outside the test bundle, on both OSes.
// WOR-303 S3.
//
// Every module with resources (`TkzTerminalCore`, `TkzTerminalRender`, `AgentBridge`) finds its
// SwiftPM resource bundle through `bundleURL(forModule:)` before falling back to `Bundle.module`
// (see `Sources/TkzTerminalCore/ModuleResources.swift` for why `Bundle.module` alone cannot work in
// the `.app`), and the terminfo probe goes through `terminfoDirectory(in:)`.
//
// **macOS** is exactly what each `ModuleResources.swift` did before: `Bundle.main.resourceURL`
// (`Contents/Resources` in the `.app`, the executable's directory under `swift run`), probed for
// `tkzmux_<Module>.bundle`.
//
// **Linux** has no `.app`, so four directories are tried, in order (docs/linux/build.md):
//   1. `$TKZMUX_RESOURCE_DIR`, when set and non-empty;
//   2. `<prefix>/lib/tkzmux` for an executable at `<prefix>/bin/tkzmux`, the read-only install
//      directory (ADR-0002 D7). It is derived from `/proc/self/exe` with symlinks resolved, never
//      from `argv[0]`, so a `~/.local/bin/tkzmux` symlink to an install elsewhere still finds that
//      install's resources. It is disjoint from the `$XDG_DATA_HOME/tkzmux` user data;
//   3. the executable's own directory (`.build/<triple>/debug` under `swift run` and `swift test`);
//   4. `Bundle.main.resourceURL`, which corelibs Foundation sets to the executable's directory too,
//      so it only matters if that ever changes.
// Each is probed for `tkzmux_<Module>.resources` (the native build system's name on Linux), then
// `tkzmux_<Module>.bundle` (Swift Build's).
//
// The Linux `version.plist` (WOR-303 S4) is read from the same install directory, see
// `versionPlistURL`, and `AppIdentity.isInstalled` is "the install directory exists".
//
// Everything is a function of the injected platform, executable path, environment and main
// resource URL, so the Linux order is tested on the Mac and the Mac order on Linux.

import Foundation

public struct ResourceLocator: Sendable {
    public enum Platform: Sendable {
        case macOS
        case linux

        public static var current: Platform {
            #if os(Linux)
            return .linux
            #else
            return .macOS
            #endif
        }
    }

    /// Overrides every other Linux candidate (tests, a relocated tree, a packager's own layout).
    public static let resourceDirectoryVariable = "TKZMUX_RESOURCE_DIR"

    /// The install directory relative to the prefix: `<prefix>/lib/tkzmux`.
    public static let installDirectoryPath = "lib/tkzmux"

    /// SwiftPM names a module's resource bundle `<package>_<module>`.
    public static let bundlePrefix = "tkzmux_"

    /// Every module with a SwiftPM resource bundle, i.e. every non-test target in Package.swift with
    /// `resources:` (`ResourceLocatorTests` checks the manifest). An install ships one bundle each.
    public static let resourceModules = ["TkzTerminalCore", "TkzTerminalRender", "AgentBridge"]

    /// The Linux stand-in for the `.app`'s stamped Info.plist, written by
    /// `scripts/linux-version-plist.sh` and read by `AppVersion.current`.
    public static let versionPlistName = "version.plist"

    /// Either layout of the compiled `xterm-ghostty` entry: hex (`78/`), which macOS ncurses reads,
    /// and letter (`x/`), which Linux ncurses reads. `make vendor` commits both (WOR-302 S1).
    public static let terminfoEntries = ["78/xterm-ghostty", "x/xterm-ghostty"]

    public var platform: Platform
    /// The running executable. On Linux, `readlink(/proc/self/exe)`. Symlinks in it are resolved
    /// here, so a test can pass a launcher symlink.
    public var executablePath: String?
    public var environment: [String: String]
    /// `Bundle.main.resourceURL`.
    public var mainResourceURL: URL?

    public init(platform: Platform, executablePath: String?, environment: [String: String], mainResourceURL: URL?) {
        self.platform = platform
        self.executablePath = executablePath
        self.environment = environment
        self.mainResourceURL = mainResourceURL
    }

    /// This process's locator. Cheap; read afresh on every call.
    public static var current: ResourceLocator {
        ResourceLocator(
            platform: .current,
            executablePath: Platform.current == .linux ? procSelfExe() : Bundle.main.executablePath,
            environment: ProcessInfo.processInfo.environment,
            mainResourceURL: Bundle.main.resourceURL
        )
    }

    /// `readlink(/proc/self/exe)`. The kernel appends ` (deleted)` once the file has been replaced
    /// or removed (an upgrade in place); the path it names is still the install's.
    static func procSelfExe() -> String? {
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") else {
            return nil
        }
        let deleted = " (deleted)"
        return path.hasSuffix(deleted) ? String(path.dropLast(deleted.count)) : path
    }

    /// The executable with symlinks resolved, or nil without one.
    var resolvedExecutable: URL? {
        guard let executablePath, !executablePath.isEmpty else { return nil }
        return URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
    }

    /// `<prefix>/lib/tkzmux` for the executable `<prefix>/bin/tkzmux`, whether or not it exists.
    /// Nil on macOS (the `.app` has `Contents/Resources`) and without an executable path.
    public var installDirectory: URL? {
        guard platform == .linux, let executable = resolvedExecutable else { return nil }
        return executable
            .deletingLastPathComponent()      // <prefix>/bin
            .deletingLastPathComponent()      // <prefix>
            .appending(path: Self.installDirectoryPath, directoryHint: .isDirectory)
    }

    /// The directories probed for resources, in order, without duplicates. Not filtered for
    /// existence: the probes do that.
    public var candidateDirectories: [URL] {
        var candidates: [URL] = []
        switch platform {
        case .macOS:
            candidates = [mainResourceURL].compactMap { $0 }
        case .linux:
            if let override = environment[Self.resourceDirectoryVariable], !override.isEmpty {
                candidates.append(URL(fileURLWithPath: override, isDirectory: true))
            }
            if let installDirectory { candidates.append(installDirectory) }
            if let executable = resolvedExecutable { candidates.append(executable.deletingLastPathComponent()) }
            if let mainResourceURL { candidates.append(mainResourceURL) }
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The resource bundle extensions to try, in order. SwiftPM's native build system names them
    /// `.bundle` on Darwin and `.resources` elsewhere; Swift Build names them `.bundle` on Linux too.
    public var bundleExtensions: [String] {
        switch platform {
        case .macOS: ["bundle"]
        case .linux: ["resources", "bundle"]
        }
    }

    /// The first `tkzmux_<module>.<extension>` directory in `candidateDirectories`, trying every
    /// extension in one directory before the next directory. Nil when none exists: the caller then
    /// falls back to `Bundle.module`.
    public func bundleURL(forModule module: String) -> URL? {
        for directory in candidateDirectories {
            for pathExtension in bundleExtensions {
                let url = directory.appending(
                    path: "\(Self.bundlePrefix)\(module).\(pathExtension)", directoryHint: .isDirectory)
                if Self.isDirectory(url) { return url }
            }
        }
        return nil
    }

    /// The Linux `version.plist`: in `$TKZMUX_RESOURCE_DIR` (standing in for the install, as for the
    /// bundles), then in `installDirectory`. Never the executable's own directory: a version
    /// describes an install, and a stray file beside a `.build` product would be stale. Nil on
    /// macOS, where the version is in the bundle's Info.plist, and when no file exists.
    public var versionPlistURL: URL? {
        guard platform == .linux else { return nil }
        var directories: [URL] = []
        if let override = environment[Self.resourceDirectoryVariable], !override.isEmpty {
            directories.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let installDirectory { directories.append(installDirectory) }
        return directories
            .map { $0.appending(path: Self.versionPlistName, directoryHint: .notDirectory) }
            .first { Self.isRegularFile($0) }
    }

    /// Whether `installDirectory` exists: the executable runs from an installed `<prefix>/bin`.
    /// False on macOS (no install directory) and from `.build`.
    public var installDirectoryExists: Bool {
        installDirectory.map(Self.isDirectory) ?? false
    }

    /// `<directory>/terminfo` if it holds `xterm-ghostty` in either layout, else nil.
    public static func terminfoDirectory(in directory: URL) -> URL? {
        let terminfo = directory.appending(path: "terminfo", directoryHint: .isDirectory)
        guard isDirectory(terminfo),
              terminfoEntries.contains(where: {
                  FileManager.default.fileExists(atPath: terminfo.appending(path: $0).path)
              })
        else { return nil }
        return terminfo
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }
}
