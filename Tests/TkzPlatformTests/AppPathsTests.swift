// AppPaths (WOR-304 S3): the XDG path table, the home rule and tilde abbreviation as pure
// functions, so they run on both OSes, plus the 0700 runtime-directory check on a temp directory.
// The Mac's own paths are compared with the pre-AppPaths code in PersistenceTests.

import Foundation
import Testing
@testable import TkzPlatform

@Suite struct AppPathsTests {
    // MARK: XDG table

    /// One environment and the three roots it must produce for home `/home/u`.
    struct Row: Sendable, CustomTestStringConvertible {
        var label: String
        var environment: [String: String]
        var support: String
        var cache: String
        var runtime: String?
        var testDescription: String { label }
    }

    static let rows: [Row] = [
        Row(label: "unset", environment: [:],
            support: "/home/u/.local/share/tkzmux", cache: "/home/u/.cache/tkzmux", runtime: nil),
        Row(label: "empty",
            environment: ["XDG_DATA_HOME": "", "XDG_CACHE_HOME": "", "XDG_RUNTIME_DIR": ""],
            support: "/home/u/.local/share/tkzmux", cache: "/home/u/.cache/tkzmux", runtime: nil),
        Row(label: "relative",
            environment: ["XDG_DATA_HOME": "data", "XDG_CACHE_HOME": "./cache", "XDG_RUNTIME_DIR": "run/user/1000"],
            support: "/home/u/.local/share/tkzmux", cache: "/home/u/.cache/tkzmux", runtime: nil),
        Row(label: "absolute",
            environment: ["XDG_DATA_HOME": "/d", "XDG_CACHE_HOME": "/c", "XDG_RUNTIME_DIR": "/run/user/1000"],
            support: "/d/tkzmux", cache: "/c/tkzmux", runtime: "/run/user/1000/tkzmux"),
        Row(label: "absolute, trailing slash",
            environment: ["XDG_DATA_HOME": "/d/", "XDG_CACHE_HOME": "/c/", "XDG_RUNTIME_DIR": "/run/user/1000/"],
            support: "/d/tkzmux", cache: "/c/tkzmux", runtime: "/run/user/1000/tkzmux"),
        Row(label: "mixed: each variable on its own",
            environment: ["XDG_DATA_HOME": "/d", "XDG_CACHE_HOME": "rel", "XDG_RUNTIME_DIR": ""],
            support: "/d/tkzmux", cache: "/home/u/.cache/tkzmux", runtime: nil),
        Row(label: "XDG_STATE_HOME is not a root",
            environment: ["XDG_STATE_HOME": "/s"],
            support: "/home/u/.local/share/tkzmux", cache: "/home/u/.cache/tkzmux", runtime: nil),
    ]

    @Test(arguments: rows)
    func xdgTable(row: Row) {
        let layout = AppPaths.xdgLayout(environment: row.environment, home: "/home/u")
        #expect(layout.home.path == "/home/u")
        #expect(layout.support.path == row.support)
        #expect(layout.cache.path == row.cache)
        #expect(layout.runtime?.path == row.runtime)
    }

    /// The installed read-only tree is `<prefix>/lib/tkzmux` (ADR-0002 D7); user data must never
    /// land under it, even with `PREFIX=$HOME/.local`.
    @Test func supportIsDisjointFromAHomeLocalInstallTree() {
        let layout = AppPaths.xdgLayout(environment: [:], home: "/home/u")
        let installed = "/home/u/.local/lib/tkzmux"
        #expect(!layout.support.path.hasPrefix(installed))
        #expect(!installed.hasPrefix(layout.support.path))
    }

    // MARK: Home

    @Test(arguments: [
        // $HOME, account database → home
        ([String: String](), "/home/pw", "/home/pw"),
        (["HOME": ""], "/home/pw", "/home/pw"),
        (["HOME": "relative/home"], "/home/pw", "/home/pw"),
        (["HOME": "/home/env"], "/home/pw", "/home/env"),
        (["HOME": "/home/env"], nil, "/home/env"),
        (["HOME": "rel"], nil, "/"),
        ([:], "not/absolute", "/"),
    ] as [([String: String], String?, String)])
    func homeRule(environment: [String: String], passwordDatabaseHome: String?, expected: String) {
        #expect(AppPaths.resolvedHome(environment: environment, passwordDatabaseHome: passwordDatabaseHome) == expected)
    }

    /// The account database answers for this process (CI runs as a user with a home).
    @Test func passwordDatabaseHomeIsAbsolute() throws {
        let home = try #require(AppPaths.passwordDatabaseHome())
        #expect(home.hasPrefix("/"))
    }

    #if os(Linux)
    /// On Linux `home` follows the rule above for this process's environment; corelibs'
    /// `NSHomeDirectory()` would ignore `$HOME`.
    @Test func linuxHomeFollowsTheRule() {
        let expected = AppPaths.resolvedHome(
            environment: ProcessInfo.processInfo.environment,
            passwordDatabaseHome: AppPaths.passwordDatabaseHome())
        #expect(AppPaths.home.path == expected)
        #expect(AppPaths.support == AppPaths.currentLayout().support)
        #expect(AppPaths.cache == AppPaths.currentLayout().cache)
    }
    #endif

    #if os(macOS)
    @Test func macRuntimeIsSupport() {
        #expect(AppPaths.runtime == AppPaths.support)
        #expect(AppPaths.home.path == NSHomeDirectory())
    }

    @Test func macAbbreviationIsFoundations() {
        for path in [NSHomeDirectory(), NSHomeDirectory() + "/src/x", "/tmp/x", "/"] {
            #expect(AppPaths.abbreviatingHome(path) == (path as NSString).abbreviatingWithTildeInPath)
        }
    }
    #endif

    // MARK: Tilde

    @Test(arguments: [
        ("/home/u", "/home/u", "~"),
        ("/home/u/", "/home/u", "~"),
        ("/home/u/src/tkzmux", "/home/u", "~/src/tkzmux"),
        ("/home/u/src/tkzmux", "/home/u/", "~/src/tkzmux"),
        ("/home/user2/src", "/home/u", "/home/user2/src"),
        ("/home/ux", "/home/u", "/home/ux"),
        ("/tmp/x", "/home/u", "/tmp/x"),
        ("relative/path", "/home/u", "relative/path"),
        ("/etc", "/", "/etc"),
        ("/", "/", "/"),
    ])
    func abbreviatingHome(path: String, home: String, expected: String) {
        #expect(AppPaths.abbreviatingHome(path, home: home) == expected)
    }

    // MARK: Runtime directory

    private func withTemporaryDirectory(_ body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AppPathsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.path)
    }

    private func mode(_ path: String) -> Int {
        var info = stat()
        guard lstat(path, &info) == 0 else { return -1 }
        return Int(info.st_mode) & 0o7777
    }

    @Test func runtimeDirectoryIsCreatedPrivate() throws {
        try withTemporaryDirectory { root in
            let path = root + "/tkzmux"
            #expect(AppPaths.makePrivateDirectory(atPath: path))
            #expect(mode(path) == 0o700)
            // A second call accepts the directory it made.
            #expect(AppPaths.makePrivateDirectory(atPath: path))
            #expect(mode(path) == 0o700)
        }
    }

    @Test func anExistingWideDirectoryIsNarrowed() throws {
        try withTemporaryDirectory { root in
            let path = root + "/tkzmux"
            #expect(mkdir(path, 0o700) == 0)
            #expect(chmod(path, 0o755) == 0)
            #expect(AppPaths.makePrivateDirectory(atPath: path))
            #expect(mode(path) == 0o700)
        }
    }

    /// A file or a symlink in the way, or no `$XDG_RUNTIME_DIR` to create it in, means no
    /// runtime directory: the caller falls back to `support`.
    @Test func refusesAnythingButAPrivateDirectory() throws {
        try withTemporaryDirectory { root in
            let file = root + "/file"
            #expect(FileManager.default.createFile(atPath: file, contents: Data()))
            #expect(!AppPaths.makePrivateDirectory(atPath: file))

            let target = root + "/target"
            #expect(mkdir(target, 0o700) == 0)
            let link = root + "/link"
            #expect(symlink(target, link) == 0)
            #expect(!AppPaths.makePrivateDirectory(atPath: link))

            #expect(!AppPaths.makePrivateDirectory(atPath: root + "/missing/tkzmux"))
        }
    }
}
