// The macOS `FileWatcher` (WOR-304 S5): kqueue vnode sources, the way ClaudeSessionWatcher and
// StatuslineReader have always watched (they keep their own sources on macOS; WOR-306 S2 moved
// only their Linux side onto `FileWatcher`).
//
// A directory vnode fires when an entry is added, removed or renamed, but says neither which entry
// nor anything about a file rewritten in place. So each watch holds:
//   - one `O_EVTONLY` source on the directory (write, delete, rename, attrib, link). Its events
//     are reported with a nil name: rescan the directory. The watcher rescans it too, and reports
//     accepted names that appeared (`.created`) or vanished (`.removed`) since the last listing.
//     A delete or rename of the directory itself ends the watch (`.watchRemoved`), as on Linux;
//   - one `O_EVTONLY` source on every entry the filter accepts (write, extend, delete, rename,
//     attrib), reported with the entry's name. After an event the path is checked again: gone is
//     `.removed`, a different inode (an atomic rename-replace) is `.created` and the source is
//     re-opened on the new inode, anything else is `.modified` (or `.attributes`).
// Entry sources are reconciled with the directory listing whenever the directory fires. Every
// accepted entry costs one fd and one kqueue registration, so filters should be narrow.
//
// Filters run outside the lock, so a filter may call back into the watcher. Every source's cancel
// handler closes its own fd, once the registration is gone, so an fd number is never reused while
// kqueue still watches it.

#if canImport(Darwin)
import Darwin
import Dispatch
import Foundation
import Synchronization

public final class KqueueFileWatcher: FileWatcher {
    private static var directoryMask: DispatchSource.FileSystemEvent { [.write, .delete, .rename, .attrib, .link] }
    private static var entryMask: DispatchSource.FileSystemEvent { [.write, .extend, .delete, .rename, .attrib] }

    private let queue: DispatchQueue
    private let onEvent: @Sendable (FileWatchEvent) -> Void
    private let storage = Mutex(Storage())

    private struct Storage {
        var cancelled = false
        var nextID: UInt64 = 1
        var watches: [FileWatchID: DirectoryWatch] = [:]
    }

    private struct DirectoryWatch {
        var path: String
        var device: dev_t
        var inode: ino_t
        var filter: @Sendable (String) -> Bool
        var source: any DispatchSourceFileSystemObject
        var entries: [String: EntryWatch] = [:]
    }

    private struct EntryWatch {
        var inode: ino_t
        var source: any DispatchSourceFileSystemObject
    }

    /// Events are delivered on `queue`, in order. Never throws on macOS; the signature matches the
    /// Linux back-end so `SystemFileWatcher` builds on both.
    public init(
        queue: DispatchQueue, onEvent: @escaping @Sendable (FileWatchEvent) -> Void
    ) throws(FileWatcherError) {
        self.queue = queue
        self.onEvent = onEvent
    }

    deinit {
        cancel()
    }

    @discardableResult
    public func add(
        directory path: String, filter: @escaping @Sendable (String) -> Bool
    ) throws(FileWatcherError) -> FileWatchID {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { throw .openError(errno: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw .system(code)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            close(fd)
            throw .notADirectory
        }
        let names = Self.entries(of: path).filter(filter)
        return try storage.withLock { s throws(FileWatcherError) -> FileWatchID in
            guard !s.cancelled else {
                close(fd)
                throw .cancelled
            }
            guard !s.watches.values.contains(where: { $0.device == info.st_dev && $0.inode == info.st_ino })
            else {
                close(fd)
                throw .alreadyWatched
            }
            let id = FileWatchID(raw: s.nextID)
            s.nextID += 1
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: Self.directoryMask, queue: queue)
            source.setEventHandler { [weak self] in self?.directoryEvent(id) }
            source.setCancelHandler { close(fd) }
            var watch = DirectoryWatch(
                path: path, device: info.st_dev, inode: info.st_ino, filter: filter, source: source)
            for name in names {
                if let entry = openEntry(id, name: name, in: path) { watch.entries[name] = entry }
            }
            s.watches[id] = watch
            source.resume()
            return id
        }
    }

    public func remove(_ watch: FileWatchID) {
        storage.withLock { s in
            guard let removed = s.watches.removeValue(forKey: watch) else { return }
            Self.cancelSources(of: removed)
        }
    }

    public func cancel() {
        storage.withLock { s in
            s.cancelled = true
            for watch in s.watches.values { Self.cancelSources(of: watch) }
            s.watches.removeAll()
        }
    }

    public var watchCount: Int {
        storage.withLock { $0.watches.count }
    }

    // MARK: - Events (on the queue)

    private enum DirectoryOutcome {
        case ended
        case rescan(path: String, filter: @Sendable (String) -> Bool)
    }

    private func directoryEvent(_ id: FileWatchID) {
        let outcome = storage.withLock { s -> DirectoryOutcome? in
            guard let watch = s.watches[id] else { return nil }
            guard watch.source.data.isDisjoint(with: [.delete, .rename]) else {
                s.watches[id] = nil
                Self.cancelSources(of: watch)
                return .ended
            }
            return .rescan(path: watch.path, filter: watch.filter)
        }
        switch outcome {
        case nil:
            return
        case .ended:
            onEvent(.watchRemoved(id))
        case .rescan(let path, let filter):
            let names = Set(Self.entries(of: path).filter(filter))
            // nil: the watch was removed (or the watcher cancelled) while the listing was read.
            guard let changes = storage.withLock({ s in reconcile(id, names: names, &s) }) else { return }
            onEvent(.changed(FileWatchChange(watch: id, name: nil, kind: .modified)))
            for change in changes { onEvent(.changed(change)) }
        }
    }

    /// Opens entry sources for new accepted names (`.created`) and drops those whose names are
    /// gone (`.removed`). An entry's own source may report the same removal first; whichever runs
    /// first drops the entry, so it is reported once. nil if the watch is gone.
    private func reconcile(_ id: FileWatchID, names: Set<String>, _ s: inout Storage) -> [FileWatchChange]? {
        guard var watch = s.watches[id] else { return nil }
        var changes: [FileWatchChange] = []
        for (name, entry) in watch.entries where !names.contains(name) {
            entry.source.cancel()
            watch.entries[name] = nil
            changes.append(FileWatchChange(watch: id, name: name, kind: .removed))
        }
        for name in names.sorted() where watch.entries[name] == nil {
            guard let entry = openEntry(id, name: name, in: watch.path) else { continue }
            watch.entries[name] = entry
            changes.append(FileWatchChange(watch: id, name: name, kind: .created))
        }
        s.watches[id] = watch
        return changes
    }

    private func entryEvent(_ id: FileWatchID, name: String) {
        let change = storage.withLock { s -> FileWatchChange? in
            guard var watch = s.watches[id], let entry = watch.entries[name] else { return nil }
            let fired = entry.source.data
            let path = (watch.path as NSString).appendingPathComponent(name)
            var info = stat()
            let kind: FileWatchChange.Kind
            if stat(path, &info) != 0 {
                entry.source.cancel()
                watch.entries[name] = nil
                kind = .removed
            } else if info.st_ino != entry.inode {
                // Replaced by a rename: the old source watches a file nobody can reach any more.
                entry.source.cancel()
                watch.entries[name] = openEntry(id, name: name, in: watch.path)
                kind = .created
            } else {
                kind = fired == .attrib ? .attributes : .modified
            }
            s.watches[id] = watch
            return FileWatchChange(watch: id, name: name, kind: kind)
        }
        if let change { onEvent(.changed(change)) }
    }

    // MARK: - Helpers

    /// A resumed source on `directory/name`, or nil if it cannot be opened (already gone).
    private func openEntry(_ id: FileWatchID, name: String, in directory: String) -> EntryWatch? {
        let path = (directory as NSString).appendingPathComponent(name)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: Self.entryMask, queue: queue)
        source.setEventHandler { [weak self] in self?.entryEvent(id, name: name) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return EntryWatch(inode: info.st_ino, source: source)
    }

    private static func cancelSources(of watch: DirectoryWatch) {
        watch.source.cancel()
        for entry in watch.entries.values { entry.source.cancel() }
    }

    private static func entries(of directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    }
}

extension FileWatcherError {
    /// The error for a failed `open` of the directory.
    static func openError(errno code: Int32) -> FileWatcherError {
        switch code {
        case ENOENT: .noSuchDirectory
        case ENOTDIR: .notADirectory
        case EACCES: .permissionDenied
        case EMFILE, ENFILE: .instanceLimitReached
        default: .system(code)
        }
    }
}
#endif
