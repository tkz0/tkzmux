// HookSocketTests — the per-instance socket name both the pty environment and the hook server
// derive from a pid.
#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif
import Foundation
import Testing

@testable import TkzCore

@Suite struct HookSocketTests {
    @Test func nameIsPrefixPidSuffix() {
        #expect(HookSocket.fileName(pid: 4242) == "tkzmux-4242.sock")
        #expect(HookSocket.fileName(pid: 1) == "tkzmux-1.sock")
        let dir = URL(filePath: "/tmp/support", directoryHint: .isDirectory)
        #expect(HookSocket.url(in: dir, pid: 4242).path == "/tmp/support/tkzmux-4242.sock")
        #expect(!HookSocket.url(in: dir, pid: 4242).hasDirectoryPath)
    }

    /// Only `tkzmux-<digits>.sock` is an instance socket. The legacy per-install `tkzmux.sock`
    /// is not, so a file left by a pre-upgrade build is never swept, nor is anything else in the
    /// support directory.
    @Test func recognisesOnlyInstanceSockets() {
        for name in ["tkzmux-1.sock", "tkzmux-4242.sock", "tkzmux-99999.sock"] {
            #expect(HookSocket.isInstanceSocket(name), "\(name)")
        }
        for name in [
            "tkzmux.sock", "tkzmux-.sock", "tkzmux-1.sock.tmp", "tkzmux-1.sock.bak", "tkzmux-x1.sock",
            "tkzmux-1x.sock", "tkzmux-１.sock", "state.json", "sessions", "", "tkzmux-1",
        ] {
            #expect(!HookSocket.isInstanceSocket(name), "\(name)")
        }
    }

    /// `sun_path` holds 104 bytes including the NUL. The support directory is under the user's
    /// home, so the budget is the user name's; a 43-character one still fits with a 5-digit pid.
    @Test func pathFitsSunPathForALongUserName() {
        let user = String(repeating: "u", count: 43)
        let dir = URL(filePath: "/Users/\(user)/Library/Application Support/tkzmux", directoryHint: .isDirectory)
        #expect(HookSocket.url(in: dir, pid: 99999).path.utf8.count < 104)
    }

    // MARK: Directory

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "HookSocketTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func mode(_ path: String) -> Int {
        var info = stat()
        guard lstat(path, &info) == 0 else { return -1 }
        return Int(info.st_mode) & 0o7777
    }

    #if os(Linux)
    /// The socket goes to `$XDG_RUNTIME_DIR/tkzmux`, made 0700, and the path fits `sun_path`
    /// (108 bytes on Linux) for any realistic runtime directory.
    @Test func linuxDirectoryIsThePrivateRuntimeDirectory() throws {
        try withTemporaryDirectory { root in
            let support = root.appending(path: "support", directoryHint: .isDirectory)
            let dir = HookSocket.directory(support: support, environment: ["XDG_RUNTIME_DIR": root.path])
            #expect(dir.path == root.appending(path: "tkzmux").path)
            #expect(mode(dir.path) == 0o700)
            #expect(HookSocket.url(in: dir, pid: 4242).path == root.path + "/tkzmux/tkzmux-4242.sock")
            // Again, now that it exists.
            #expect(HookSocket.directory(support: support, environment: ["XDG_RUNTIME_DIR": root.path]) == dir)
        }
        let typical = URL(filePath: "/run/user/4294967294/tkzmux", directoryHint: .isDirectory)
        #expect(HookSocket.url(in: typical, pid: 4_194_304).path.utf8.count < 108)
    }

    /// No usable runtime directory means the support directory, as on the Mac: the variable unset,
    /// empty or relative (the XDG spec says to ignore it), or a runtime directory that cannot be
    /// made private to this user — a file or a symlink where `tkzmux` should be, or a root that
    /// is not a directory.
    @Test func linuxDirectoryFallsBackToSupport() throws {
        try withTemporaryDirectory { root in
            let support = root.appending(path: "support", directoryHint: .isDirectory)
            for environment in [[:], ["XDG_RUNTIME_DIR": ""], ["XDG_RUNTIME_DIR": "run/user/1000"]] {
                #expect(HookSocket.directory(support: support, environment: environment) == support)
            }

            let file = root.appending(path: "file")
            #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
            #expect(HookSocket.directory(support: support, environment: ["XDG_RUNTIME_DIR": file.path]) == support)

            let linked = root.appending(path: "linked", directoryHint: .isDirectory)
            let elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
            #expect(symlink(elsewhere.path, linked.appending(path: "tkzmux").path) == 0)
            #expect(HookSocket.directory(support: support, environment: ["XDG_RUNTIME_DIR": linked.path]) == support)

            #expect(HookSocket.directory(
                support: support, environment: ["XDG_RUNTIME_DIR": root.appending(path: "missing").path]) == support)
        }
    }

    /// A runtime root this user cannot write to (root bypasses the mode bits, so not as root).
    @Test(.enabled(if: geteuid() != 0, "root can write a 0500 directory"))
    func linuxDirectoryFallsBackWhenTheRuntimeRootIsNotWritable() throws {
        try withTemporaryDirectory { root in
            let support = root.appending(path: "support", directoryHint: .isDirectory)
            let locked = root.appending(path: "locked", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
            #expect(chmod(locked.path, 0o500) == 0)
            defer { chmod(locked.path, 0o700) }
            #expect(HookSocket.directory(support: support, environment: ["XDG_RUNTIME_DIR": locked.path]) == support)
        }
    }
    #else
    /// The Mac's socket stays in the support directory, whatever the environment says.
    @Test func macDirectoryIsSupportUnchanged() {
        let support = URL(filePath: "/tmp/support", directoryHint: .isDirectory)
        #expect(HookSocket.directory(support: support) == support)
        #expect(HookSocket.directory(support: support, environment: ["XDG_RUNTIME_DIR": "/tmp"]) == support)
    }
    #endif
}
