// Shared by the FileWatcher and ProcessExitWatcher tests (WOR-304 S5), and the ProcessTable and
// ListeningPorts tests (S6).
//
// Every suite that opens inotify fds or pidfds, or spawns children, is nested in `WatcherTests`,
// which is serialized: the descriptor-count and zombie checks below read process-wide state
// (/proc/self/fd, /proc/self/task/*/children) and must not see another watcher test's fds or
// children. That includes the ProcessTable and ListeningPorts suites (S6), which spawn children.
// Outside this module, TkzTerminalCoreTests' PtyTests (WOR-305) spawn children and hold pidfds in
// the same test process during a parallel run, so the pidfd and zombie checks only count fds and
// children that belong to the test's own pids. Likewise AgentBridgeTests' watchers (WOR-306) hold
// inotify fds, so the inotify check only counts fds watching the test's own directories.

import Dispatch
import Foundation
import Synchronization
import Testing
@testable import TkzPlatform

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif

@Suite(.serialized) struct WatcherTests {}

/// Collects values delivered on a watcher's queue, for tests that wait on them.
final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    func append(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    var all: [Value] { values.withLock { $0 } }

    /// Polls until `predicate` holds for the values so far, or `timeout` passes. Suspends, never
    /// spins (the main actor is not pinned to a thread on Linux).
    @discardableResult
    func wait(timeout: Duration = .seconds(5), until predicate: ([Value]) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate(all) { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return predicate(all)
    }
}

/// A fresh directory under the temporary directory, removed by `remove()`.
struct ScratchDirectory {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appending(path: "tkzmux-watch-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

    /// Creates or truncates `name` and writes `text` through one fd, so the events are exactly a
    /// create (if new) and writes, never a temporary file and a rename.
    func write(_ name: String, _ text: String) throws {
        let fd = open(file(name), O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        guard bytes.withUnsafeBytes({ systemWrite(fd, $0.baseAddress, $0.count) }) == bytes.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Opens an existing file and writes to it in place (same inode).
    func append(_ name: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file(name)))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// write(2), named so `ScratchDirectory.write` does not shadow it.
private func systemWrite(_ fd: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
    write(fd, bytes, count)
}

/// Spawns `path` with `arguments` and an empty environment; returns the pid. The caller reaps it.
/// `fd3`, when given, becomes the child's fd 3 (dup2 clears its close-on-exec flag in the child).
func spawnChild(_ path: String, _ arguments: [String] = [], fd3: Int32? = nil) throws -> pid_t {
    let argv = ([path] + arguments).map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    #if canImport(Darwin)
    var actions: posix_spawn_file_actions_t? = nil
    #else
    var actions = posix_spawn_file_actions_t()
    #endif
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    // A dup2 of fd 3 onto itself does not clear close-on-exec on every OS (glibc does, macOS is
    // not documented to), so a source that already is fd 3 is handed over from a copy.
    let copy: Int32? = fd3 == 3 ? fcntl(3, F_DUPFD_CLOEXEC, 4) : nil
    defer { if let copy, copy >= 0 { close(copy) } }
    if let fd3 { posix_spawn_file_actions_adddup2(&actions, copy ?? fd3, 3) }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, path, &actions, nil, argv, &environment)
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    return pid
}

/// Reaps `pid`, blocking until it has exited. Returns waitpid's result.
@discardableResult
func reapBlocking(_ pid: pid_t) -> pid_t {
    var status: Int32 = 0
    var result: pid_t
    repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
    return result
}

#if os(Linux)
/// How many of this process's inotify fds hold a watch on the directory at `path`, from the
/// `inotify wd:` lines of /proc/self/fdinfo. The inotify total is not enough for a leak check:
/// AgentBridge's watchers (WOR-306) hold inotify fds of their own while a parallel run goes on.
func inotifyDescriptorCount(watching path: String) -> Int {
    var st = stat()
    guard stat(path, &st) == 0 else { return 0 }
    let inode = "ino:" + String(UInt64(st.st_ino), radix: 16) + " "
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
    var count = 0
    for entry in entries {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(entry)"))
                == "anon_inode:inotify",
            let info = try? String(contentsOfFile: "/proc/self/fdinfo/\(entry)", encoding: .utf8)
        else { continue }
        if info.split(separator: "\n").contains(where: { $0.hasPrefix("inotify wd:") && $0.contains(inode) }) {
            count += 1
        }
    }
    return count
}

/// How many of this process's pidfds refer to `pid`, from the `Pid:` line of /proc/self/fdinfo.
/// The pidfd total is not enough for a leak check: Pty spawns in TkzTerminalCoreTests hold pidfds
/// of their own while a parallel run goes on.
func pidfdCount(for pid: pid_t) -> Int {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
    var count = 0
    for entry in entries {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(entry)"))
                == "anon_inode:[pidfd]",
            let info = try? String(contentsOfFile: "/proc/self/fdinfo/\(entry)", encoding: .utf8)
        else { continue }
        if info.split(separator: "\n").contains("Pid:\t\(pid)") { count += 1 }
    }
    return count
}

/// The pids in /proc/self/task/*/children: every child of every thread of this process.
func currentChildren() -> Set<pid_t> {
    let tasks = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/task")) ?? []
    var children = Set<pid_t>()
    for task in tasks {
        guard let text = try? String(contentsOfFile: "/proc/self/task/\(task)/children", encoding: .utf8)
        else { continue }
        for field in text.split(separator: " ") {
            if let pid = pid_t(field.trimmingCharacters(in: .whitespacesAndNewlines)) { children.insert(pid) }
        }
    }
    return children
}

/// The state letter of `/proc/<pid>/stat` (the field after the last `)`), or nil if it is gone.
func processState(_ pid: pid_t) -> Character? {
    guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
        let close = stat.lastIndex(of: ")")
    else { return nil }
    return stat[stat.index(after: close)...].first { $0 != " " }
}
#endif
