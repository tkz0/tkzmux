// Shared by the FileWatcher and ProcessExitWatcher tests (WOR-304 S5).
//
// Every suite that opens inotify fds or pidfds, or spawns children, is nested in `WatcherTests`,
// which is serialized: the descriptor-count and zombie checks below read process-wide state
// (/proc/self/fd, /proc/self/task/*/children) and must not see another watcher test's fds or
// children. No other suite in this target opens those fds or spawns processes.

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
func spawnChild(_ path: String, _ arguments: [String] = []) throws -> pid_t {
    let argv = ([path] + arguments).map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    let result = posix_spawn(&pid, path, nil, nil, argv, &environment)
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
/// How many of this process's fds are inotify instances and pidfds, from /proc/self/fd. Counted
/// by kind rather than in total, so files that Swift Testing or a parallel suite opens do not move it.
func watcherDescriptorCounts() -> (inotify: Int, pidfd: Int) {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
    var inotify = 0
    var pidfd = 0
    for entry in entries {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(entry)")
        else { continue }
        if target == "anon_inode:inotify" { inotify += 1 }
        if target == "anon_inode:[pidfd]" { pidfd += 1 }
    }
    return (inotify, pidfd)
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
