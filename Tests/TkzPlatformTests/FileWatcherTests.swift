// FileWatcher (WOR-304 S5): create, in-place write, atomic rename-replace, delete and directory
// removal on the system back-end, plus the name filter and the errors. On Linux also the inotify
// record parser, overflow (a synthetic wd == -1 record and a real flood past
// fs.inotify.max_queued_events) and descriptor counts over 1,000 watch/cancel cycles.
//
// Expectations hold on both back-ends unless marked: macOS reports a directory-level change with
// a nil name ("rescan") where Linux names the entry.

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

/// Whether `events` hold a change of `kind` to `name` in `watch`.
private func sawChange(
    _ events: [FileWatchEvent], _ watch: FileWatchID, _ name: String?, _ kind: FileWatchChange.Kind
) -> Bool {
    events.contains { event in
        guard case .changed(let change) = event else { return false }
        return change.watch == watch && change.name == name && change.kind == kind
    }
}

private func names(_ events: [FileWatchEvent]) -> Set<String> {
    Set(events.compactMap { event in
        guard case .changed(let change) = event else { return nil }
        return change.name
    })
}

extension WatcherTests {
    @Suite struct FileWatcherTests {
        let queue = DispatchQueue(label: "se.tkz.tkzmux.tests.FileWatcher")

        @Test func reportsACreatedFile() async throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            let events = Recorder<FileWatchEvent>()
            let watcher = try SystemFileWatcher(queue: queue) { events.append($0) }
            let id = try watcher.add(directory: directory.path)

            try directory.write("1234.json", "{}")

            #expect(await events.wait { sawChange($0, id, "1234.json", .created) })
            #if os(Linux)
            #expect(await events.wait { sawChange($0, id, "1234.json", .modified) })
            #else
            #expect(await events.wait { sawChange($0, id, nil, .modified) })  // "rescan"
            #endif
        }

        @Test func reportsAnInPlaceWrite() async throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            try directory.write("1234.json", "{}")
            let events = Recorder<FileWatchEvent>()
            let watcher = try SystemFileWatcher(queue: queue) { events.append($0) }
            let id = try watcher.add(directory: directory.path)

            try directory.append("1234.json", " ")

            #expect(await events.wait { sawChange($0, id, "1234.json", .modified) })
            #expect(!events.all.contains { if case .watchRemoved = $0 { true } else { false } })
        }

        /// The way Claude Code and the statusline publish: write a temporary file, rename it over
        /// the real one. The replaced file is then still watched (macOS re-opens on the new inode).
        @Test func reportsAnAtomicRenameReplace() async throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            try directory.write("1234.json", "{\"v\":1}")
            let events = Recorder<FileWatchEvent>()
            let watcher = try SystemFileWatcher(queue: queue) { events.append($0) }
            let id = try watcher.add(directory: directory.path) { $0.hasSuffix(".json") }

            try directory.write("1234.json.tmp", "{\"v\":2}")
            #expect(rename(directory.file("1234.json.tmp"), directory.file("1234.json")) == 0)

            #expect(await events.wait { sawChange($0, id, "1234.json", .created) })
            #expect(!names(events.all).contains("1234.json.tmp"), "the filter rejects the temporary name")

            try directory.append("1234.json", " ")
            #expect(await events.wait { sawChange($0, id, "1234.json", .modified) })
        }

        @Test func reportsADelete() async throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            try directory.write("1234.json", "{}")
            let events = Recorder<FileWatchEvent>()
            let watcher = try SystemFileWatcher(queue: queue) { events.append($0) }
            let id = try watcher.add(directory: directory.path)

            #expect(unlink(directory.file("1234.json")) == 0)

            #expect(await events.wait { sawChange($0, id, "1234.json", .removed) })
        }

        @Test func directoryRemovalEndsTheWatch() async throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            let events = Recorder<FileWatchEvent>()
            let watcher = try SystemFileWatcher(queue: queue) { events.append($0) }
            let id = try watcher.add(directory: directory.path)
            #expect(watcher.watchCount == 1)

            #expect(rmdir(directory.path) == 0)

            #expect(await events.wait { $0.contains(.watchRemoved(id)) })
            #expect(watcher.watchCount == 0)
            // The directory is gone, so adding it again fails until it is back.
            #expect(throws: FileWatcherError.noSuchDirectory) { try watcher.add(directory: directory.path) }
        }

        @Test func movingTheDirectoryAwayEndsTheWatch() async throws {
            let parent = try ScratchDirectory()
            defer { parent.remove() }
            let watched = parent.file("watched")
            try FileManager.default.createDirectory(atPath: watched, withIntermediateDirectories: false)
            let events = Recorder<FileWatchEvent>()
            let watcher = try SystemFileWatcher(queue: queue) { events.append($0) }
            let id = try watcher.add(directory: watched)

            #expect(rename(watched, parent.file("moved")) == 0)

            #expect(await events.wait { $0.contains(.watchRemoved(id)) })
            #expect(watcher.watchCount == 0)
        }

        @Test func removeStopsReportingWithoutWatchRemoved() async throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            let events = Recorder<FileWatchEvent>()
            let watcher = try SystemFileWatcher(queue: queue) { events.append($0) }
            let id = try watcher.add(directory: directory.path)

            watcher.remove(id)
            #expect(watcher.watchCount == 0)
            try directory.write("1234.json", "{}")
            try directory.append("1234.json", " ")
            try await Task.sleep(for: .milliseconds(100))
            queue.sync {}

            #expect(events.all.isEmpty)
        }

        @Test func filterRejectsNames() async throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            try directory.write("1234.json", "{}")
            try directory.write("1234.abcd.key", "secret")
            let events = Recorder<FileWatchEvent>()
            let watcher = try SystemFileWatcher(queue: queue) { events.append($0) }
            let id = try watcher.add(directory: directory.path) { $0.hasSuffix(".json") }

            try directory.append("1234.abcd.key", "x")
            try directory.append("1234.json", " ")

            #expect(await events.wait { sawChange($0, id, "1234.json", .modified) })
            #expect(!names(events.all).contains("1234.abcd.key"))
        }

        /// Filters run outside the watcher's lock, so one may call back into the watcher.
        @Test func filterMayCallTheWatcher() async throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            let events = Recorder<FileWatchEvent>()
            let box = Mutex<(any FileWatcher)?>(nil)
            let watcher = try SystemFileWatcher(queue: queue) { events.append($0) }
            box.withLock { $0 = watcher }
            let id = try watcher.add(directory: directory.path) { _ in
                box.withLock { $0?.watchCount ?? 0 } == 1
            }
            try directory.write("1234.json", "{}")
            #expect(await events.wait { sawChange($0, id, "1234.json", .created) })
            try directory.append("1234.json", " ")
            #expect(await events.wait { sawChange($0, id, "1234.json", .modified) })
            box.withLock { $0 = nil }
        }

        @Test func addErrors() throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            try directory.write("file", "")
            let watcher = try SystemFileWatcher(queue: queue) { _ in }

            try watcher.add(directory: directory.path)
            #expect(throws: FileWatcherError.alreadyWatched) { try watcher.add(directory: directory.path) }
            #expect(throws: FileWatcherError.alreadyWatched) { try watcher.add(directory: directory.path + "/.") }
            #expect(throws: FileWatcherError.noSuchDirectory) { try watcher.add(directory: directory.file("missing")) }
            #expect(throws: FileWatcherError.notADirectory) { try watcher.add(directory: directory.file("file")) }
            #expect(watcher.watchCount == 1)

            watcher.cancel()
            #expect(watcher.watchCount == 0)
            #expect(throws: FileWatcherError.cancelled) { try watcher.add(directory: directory.path) }
            watcher.cancel()  // idempotent
        }

        @Test func oneWatcherHoldsManyDirectories() async throws {
            let directories = try (0..<3).map { _ in try ScratchDirectory() }
            defer { directories.forEach { $0.remove() } }
            let events = Recorder<FileWatchEvent>()
            let watcher = try SystemFileWatcher(queue: queue) { events.append($0) }
            let ids = try directories.map { try watcher.add(directory: $0.path) }
            #expect(Set(ids).count == 3)
            #expect(watcher.watchCount == 3)

            try directories[2].write("x", "1")

            let changed = await events.wait { $0.contains { event in
                if case .changed(let change) = event { change.watch == ids[2] } else { false }
            } }
            #expect(changed)
            #expect(!events.all.contains { event in
                if case .changed(let change) = event { change.watch != ids[2] } else { false }
            })
        }

        #if os(Linux)
        @Test func reportsSubdirectories() async throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            let events = Recorder<FileWatchEvent>()
            let watcher = try SystemFileWatcher(queue: queue) { events.append($0) }
            let id = try watcher.add(directory: directory.path)

            #expect(mkdir(directory.file("sub"), 0o755) == 0)

            #expect(await events.wait { $0.contains(.changed(FileWatchChange(watch: id, name: "sub", kind: .created, isDirectory: true))) })
        }

        /// Records are packed back to back with NUL-padded names; parse them from an odd offset so
        /// every load is unaligned.
        @Test func parsesPackedRecords() {
            func record(wd: Int32, mask: UInt32, cookie: UInt32, name: String, padTo length: Int) -> [UInt8] {
                var bytes: [UInt8] = []
                withUnsafeBytes(of: wd) { bytes += $0 }
                withUnsafeBytes(of: mask) { bytes += $0 }
                withUnsafeBytes(of: cookie) { bytes += $0 }
                withUnsafeBytes(of: UInt32(length)) { bytes += $0 }
                let nameBytes = Array(name.utf8)
                return bytes + nameBytes + [UInt8](repeating: 0, count: length - nameBytes.count)
            }
            let buffer: [UInt8] =
                [0xEE]  // misaligns everything after it
                + record(wd: 1, mask: UInt32(IN_CREATE), cookie: 0, name: "1234.json", padTo: 16)
                + record(wd: -1, mask: UInt32(IN_Q_OVERFLOW), cookie: 0, name: "", padTo: 0)
                + record(wd: 2, mask: UInt32(IN_MOVED_TO) | UInt32(IN_ISDIR), cookie: 7, name: "d", padTo: 4)
                + record(wd: 3, mask: UInt32(IN_DELETE_SELF), cookie: 0, name: "", padTo: 0)
                + [1, 2, 3]  // a truncated header is ignored

            let records = buffer.withUnsafeBytes { InotifyRecord.parse(UnsafeRawBufferPointer(rebasing: $0.dropFirst())) }

            #expect(records == [
                InotifyRecord(wd: 1, mask: UInt32(IN_CREATE), cookie: 0, name: "1234.json"),
                InotifyRecord(wd: -1, mask: UInt32(IN_Q_OVERFLOW), cookie: 0, name: nil),
                InotifyRecord(wd: 2, mask: UInt32(IN_MOVED_TO) | UInt32(IN_ISDIR), cookie: 7, name: "d"),
                InotifyRecord(wd: 3, mask: UInt32(IN_DELETE_SELF), cookie: 0, name: nil),
            ])
        }

        @Test func truncatedNameIsDropped() {
            var bytes: [UInt8] = []
            withUnsafeBytes(of: Int32(1)) { bytes += $0 }
            withUnsafeBytes(of: UInt32(IN_CREATE)) { bytes += $0 }
            withUnsafeBytes(of: UInt32(0)) { bytes += $0 }
            withUnsafeBytes(of: UInt32(16)) { bytes += $0 }
            bytes += Array("short".utf8)  // 5 of the promised 16 bytes
            #expect(bytes.withUnsafeBytes { InotifyRecord.parse($0) }.isEmpty)
        }

        @Test func eventKinds() {
            #expect(InotifyFileWatcher.changeKind(UInt32(IN_CREATE)) == .created)
            #expect(InotifyFileWatcher.changeKind(UInt32(IN_MOVED_TO)) == .created)
            #expect(InotifyFileWatcher.changeKind(UInt32(IN_MODIFY)) == .modified)
            #expect(InotifyFileWatcher.changeKind(UInt32(IN_CLOSE_WRITE)) == .modified)
            #expect(InotifyFileWatcher.changeKind(UInt32(IN_ATTRIB)) == .attributes)
            #expect(InotifyFileWatcher.changeKind(UInt32(IN_DELETE)) == .removed)
            #expect(InotifyFileWatcher.changeKind(UInt32(IN_MOVED_FROM)) == .removed)
            #expect(InotifyFileWatcher.changeKind(UInt32(IN_DELETE_SELF)) == nil)
            #expect(InotifyFileWatcher.changeKind(UInt32(IN_UNMOUNT)) == nil)
        }

        /// IN_Q_OVERFLOW carries wd == -1, so it is not tied to any watch.
        @Test func overflowRecordBecomesOverflowEvent() throws {
            let events = Recorder<FileWatchEvent>()
            let watcher = try InotifyFileWatcher(queue: queue) { events.append($0) }
            watcher.deliver([
                InotifyRecord(wd: -1, mask: UInt32(IN_Q_OVERFLOW), cookie: 0, name: nil),
                InotifyRecord(wd: 9_999, mask: UInt32(IN_CREATE), cookie: 0, name: "stale"),
            ])
            #expect(events.all == [.overflow])
        }

        /// A `remove` or `cancel` from inside the handler holds for the rest of a batch already read.
        @Test func removeAndCancelInsideTheHandlerHoldForTheBatch() throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            let events = Recorder<FileWatchEvent>()
            let box = Mutex<InotifyFileWatcher?>(nil)
            let watcher = try InotifyFileWatcher(queue: queue) { event in
                events.append(event)
                box.withLock { watcher in
                    if case .changed(let change) = event { watcher?.remove(change.watch) } else { watcher?.cancel() }
                }
            }
            box.withLock { $0 = watcher }
            defer { box.withLock { $0 = nil } }
            let id = try watcher.add(directory: directory.path)  // the first wd of a fresh instance
            watcher.deliver([
                InotifyRecord(wd: 1, mask: UInt32(IN_CREATE), cookie: 0, name: "a"),
                InotifyRecord(wd: 1, mask: UInt32(IN_CREATE), cookie: 0, name: "b"),
                InotifyRecord(wd: -1, mask: UInt32(IN_Q_OVERFLOW), cookie: 0, name: nil),
                InotifyRecord(wd: -1, mask: UInt32(IN_Q_OVERFLOW), cookie: 0, name: nil),
            ])
            #expect(events.all == [.changed(FileWatchChange(watch: id, name: "a", kind: .created)), .overflow])
        }

        @Test func errnoMapping() {
            #expect(FileWatcherError.watchError(errno: ENOSPC) == .watchLimitReached)
            #expect(FileWatcherError.watchError(errno: ENOENT) == .noSuchDirectory)
            #expect(FileWatcherError.watchError(errno: ENOTDIR) == .notADirectory)
            #expect(FileWatcherError.watchError(errno: EACCES) == .permissionDenied)
            #expect(FileWatcherError.watchError(errno: EEXIST) == .alreadyWatched)
            #expect(FileWatcherError.watchError(errno: ENOMEM) == .system(ENOMEM))
            #expect(FileWatcherError.instanceError(errno: EMFILE) == .instanceLimitReached)
            #expect(FileWatcherError.instanceError(errno: ENFILE) == .instanceLimitReached)
        }

        /// Hold the delivery queue while more events than fs.inotify.max_queued_events are
        /// generated (two per file: IN_CREATE and IN_CLOSE_WRITE), then release it: the watcher
        /// reports `.overflow`, and the watch keeps working afterwards.
        @Test(.timeLimit(.minutes(1))) func floodOverflows() async throws {
            let limit = (try? String(contentsOfFile: "/proc/sys/fs/inotify/max_queued_events", encoding: .utf8))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 16_384
            let files = max(limit, 16_384) / 2 + 1_000
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            let events = Recorder<FileWatchEvent>()
            let watcher = try InotifyFileWatcher(queue: queue) { events.append($0) }
            let id = try watcher.add(directory: directory.path)

            let gate = DispatchSemaphore(value: 0)
            queue.async { gate.wait() }
            for index in 0..<files {
                let fd = open(directory.file("f\(index)"), O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)
                #expect(fd >= 0)
                close(fd)
            }
            gate.signal()

            #expect(await events.wait(timeout: .seconds(20)) { $0.contains(.overflow) })
            #expect(watcher.watchCount == 1)
            try directory.write("after", "")
            #expect(await events.wait { sawChange($0, id, "after", .created) })
        }

        @Test(.timeLimit(.minutes(1))) func descriptorsDoNotLeakOverAThousandCycles() async throws {
            let directory = try ScratchDirectory()
            // Keeps one watch on the shared instance, so its fd can be told apart from the
            // inotify fds other suites hold during a parallel run.
            let anchor = try ScratchDirectory()
            defer {
                directory.remove()
                anchor.remove()
            }

            // Watches on one instance: kernel objects, no fds.
            let shared = try InotifyFileWatcher(queue: queue) { _ in }
            try shared.add(directory: anchor.path)
            for _ in 0..<1_000 {
                let id = try shared.add(directory: directory.path)
                shared.remove(id)
            }
            #expect(shared.watchCount == 1)
            #expect(inotifyDescriptorCount(watching: anchor.path) == 1)
            #expect(inotifyDescriptorCount(watching: directory.path) == 0)
            shared.cancel()

            // Whole watchers: each holds an inotify fd, and with it its watch on `directory`,
            // until its source's cancel handler runs. fs.inotify.max_user_instances (often 128 or
            // 1,024) counts every instance this user has open, so let the closes catch up every
            // 50 cycles.
            for cycle in 1...1_000 {
                let watcher = try InotifyFileWatcher(queue: queue) { _ in }
                try watcher.add(directory: directory.path)
                if cycle.isMultiple(of: 2) { watcher.cancel() }  // the rest cancel in deinit
                if cycle.isMultiple(of: 50) { try await Self.settle(watching: directory.path) }
            }
            try await Self.settle(watching: directory.path)
            #expect(inotifyDescriptorCount(watching: directory.path) == 0)
        }

        /// Waits up to 5 s for every inotify fd watching `path` to close.
        private static func settle(watching path: String) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while inotifyDescriptorCount(watching: path) != 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        #endif
    }
}
