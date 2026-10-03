// HookSupportPathTests — WOR-305 S5. On Linux the hook finds the support directory by hand,
// without Foundation (`statuslineSupportDirectory` in Sources/tkzmux-hook/StatuslineCommand.swift),
// copying TkzPlatform's `AppPaths.support` rule. Nothing else keeps the two in step, so this runs
// the built hook with `TKZMUX_SUPPORT_DIR` unset and a temporary HOME, and checks that its
// statusline sidecar lands under the directory `AppPaths` resolves for the same environment.
//
// The seam is StatuslineTests': run the real binary, read the sidecar it wrote. The hook is
// started with posix_spawn instead of Process so that argv[0] can differ from the executable;
// argv[0] is all the hook's `<support>/bin` rule looks at, so the `/usr/bin` cases need nothing
// installed there. Linux only: the Mac's support directory does not follow HOME or XDG.
#if os(Linux)
import Foundation
import Glibc
import Testing

@testable import TkzPlatform

@Suite struct HookSupportPathTests {
    enum Failure: Error { case binaryNotFound(String), spawn(Int32), wait(Int32) }

    /// A payload without quota, so the hook writes exactly `statusline/context-s1.json`.
    static let payload = #"{"session_id":"s1","model":{"display_name":"Opus 5"}}"#
    static let sidecar = "statusline/context-s1.json"

    /// `$TKZMUX_HOOK_BIN`, else the `tkzmux-hook` that `swift test` builds next to the test runner.
    static func hookBinary() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["TKZMUX_HOOK_BIN"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let runner = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        let candidate = URL(fileURLWithPath: runner).deletingLastPathComponent().appending(path: "tkzmux-hook")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw Failure.binaryNotFound(candidate.path)
        }
        return candidate
    }

    /// Runs `tkzmux-hook statusline` with `argv0` as argv[0], exactly `environment` as its
    /// environment, `payload` on stdin and stdout/stderr discarded. Returns the exit status.
    static func runStatusline(argv0: String, environment: [String: String], in directory: URL) throws -> Int32 {
        let binary = try hookBinary()
        let input = directory.appending(path: "payload.json")
        try Data(payload.utf8).write(to: input)

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, input.path, O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(argv0), strdup("statusline"), nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, binary.path, &actions, nil, argv, envp)
        guard spawned == 0 else { throw Failure.spawn(spawned) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { throw Failure.wait(errno) }
        }
        return status
    }

    /// `AppPaths.support` for `environment`, through the same pure resolution the app uses.
    static func appPathsSupport(_ environment: [String: String]) -> URL {
        let home = AppPaths.resolvedHome(
            environment: environment, passwordDatabaseHome: AppPaths.passwordDatabaseHome())
        return AppPaths.xdgLayout(environment: environment, home: home).support
    }

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tkzmux-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    enum DataHome: String, CaseIterable, Sendable {
        case unset, empty, relative, absolute
    }

    /// The four XDG_DATA_HOME cases: only an absolute value is used; unset, empty and relative
    /// all mean `$HOME/.local/share` (XDG Base Directory spec).
    @Test(arguments: DataHome.allCases)
    func theSidecarLandsUnderAppPathsSupport(_ dataHome: DataHome) throws {
        let root = try Self.temporaryDirectory("hook-support-\(dataHome.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appending(path: "home")
        let xdgData = root.appending(path: "xdg-data")

        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let wanted: URL
        switch dataHome {
        case .unset:
            wanted = home.appending(path: ".local/share/tkzmux")
        case .empty:
            environment["XDG_DATA_HOME"] = ""
            wanted = home.appending(path: ".local/share/tkzmux")
        case .relative:
            environment["XDG_DATA_HOME"] = "relative/share"
            wanted = home.appending(path: ".local/share/tkzmux")
        case .absolute:
            environment["XDG_DATA_HOME"] = xdgData.path
            wanted = xdgData.appending(path: "tkzmux")
        }
        let support = Self.appPathsSupport(environment)
        #expect(support.standardizedFileURL.path == wanted.standardizedFileURL.path)

        // The hook creates `<support>` and `<support>/statusline`, never the data home above them.
        try FileManager.default.createDirectory(
            at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A relative argv[0] skips the `<support>/bin` rule, so only the environment decides.
        let status = try Self.runStatusline(argv0: "tkzmux-hook", environment: environment, in: root)
        #expect(status == 0)
        #expect(FileManager.default.fileExists(atPath: support.appending(path: Self.sidecar).path),
                "no sidecar under AppPaths.support (\(support.path)) for XDG_DATA_HOME \(dataHome)")
    }

    /// A hook in a system prefix's `bin` (a distribution package) is not in `<support>/bin`, so the
    /// environment decides; a hook in any other `…/bin` still uses the directory above it.
    @Test(arguments: [
        "/usr/bin/tkzmux-hook", "/usr/local/bin/tkzmux-hook", "/bin/tkzmux-hook",
        "<root>/prefix/bin/tkzmux-hook",
    ])
    func argv0InASystemBinIsNotTheSupportDirectory(_ argv0Template: String) throws {
        let root = try Self.temporaryDirectory("hook-argv0")
        defer { try? FileManager.default.removeItem(at: root) }
        let argv0 = argv0Template.replacingOccurrences(of: "<root>", with: root.path)
        let environment = ["HOME": root.appending(path: "home").path, "PATH": "/usr/bin:/bin"]
        let support = argv0Template.hasPrefix("<root>")
            ? root.appending(path: "prefix")
            : Self.appPathsSupport(environment)
        try FileManager.default.createDirectory(
            at: support.deletingLastPathComponent(), withIntermediateDirectories: true)

        let status = try Self.runStatusline(argv0: argv0, environment: environment, in: root)
        #expect(status == 0)
        #expect(FileManager.default.fileExists(atPath: support.appending(path: Self.sidecar).path),
                "argv[0] \(argv0): no sidecar under \(support.path)")
    }
}
#endif
