// The Linux `FileWatcher` (WOR-304 S5): inotify.
//
// One inotify fd per watcher (IN_NONBLOCK|IN_CLOEXEC) holds every directory watch, and one
// dispatch read source on the owner's queue drains it. Watches are directory-only (IN_ONLYDIR) and
// never doubled (IN_MASK_CREATE, Linux 4.18). The mask covers what tkzmux's watchers need to see:
//
//   IN_CREATE, IN_MOVED_TO          .created     (a rename-replace is an IN_MOVED_TO of the name)
//   IN_MODIFY, IN_CLOSE_WRITE       .modified    (in-place rewrites; no per-file watch needed)
//   IN_ATTRIB                       .attributes
//   IN_DELETE, IN_MOVED_FROM        .removed
//   IN_DELETE_SELF                  nothing; the IN_IGNORED that follows reports it
//   IN_MOVE_SELF                    the watch is removed, then .watchRemoved: the path no longer
//                                   names the directory, and a watch follows the inode
//   IN_IGNORED                      .watchRemoved (deleted, unmounted), unless `remove` asked
//   IN_Q_OVERFLOW (wd == -1)        .overflow
//
// Records are variable length (a 16-byte header, then `len` bytes of NUL-padded name), so they
// are parsed with unaligned loads by `InotifyRecord.parse`, a pure function the tests feed
// synthetic buffers. Name filters run outside the lock, so a filter may call back into the
// watcher. Watch descriptors are allocated cyclically by the kernel, so the IN_IGNORED of a
// removed watch cannot be mistaken for a later watch's.

#if os(Linux)
import Dispatch
import Glibc
import Synchronization

/// One raw inotify record.
struct InotifyRecord: Hashable {
    var wd: Int32
    var mask: UInt32
    var cookie: UInt32
    /// The entry name, or nil for an event on the watched directory itself (and for overflow).
    var name: String?

    /// `struct inotify_event` without its name: wd, mask, cookie, len.
    static let headerSize = 16

    /// Every complete record in `bytes`, in order. A truncated trailing record is dropped (the
    /// kernel never returns one: a read either fits whole records or fails with EINVAL).
    static func parse(_ bytes: UnsafeRawBufferPointer) -> [InotifyRecord] {
        var records: [InotifyRecord] = []
        var offset = 0
        while offset + headerSize <= bytes.count {
            let wd = bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self)
            let mask = bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
            let cookie = bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)
            let length = Int(bytes.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))
            let nameStart = offset + headerSize
            guard length <= bytes.count - nameStart else { break }
            let padded = UnsafeRawBufferPointer(rebasing: bytes[nameStart..<(nameStart + length)])
            let nameBytes = padded.prefix { $0 != 0 }
            let name = nameBytes.isEmpty ? nil : String(decoding: nameBytes, as: UTF8.self)
            records.append(InotifyRecord(wd: wd, mask: mask, cookie: cookie, name: name))
            offset = nameStart + length
        }
        return records
    }
}

public final class InotifyFileWatcher: FileWatcher {
    /// What every watch asks for (see the table above).
    static let eventMask: UInt32 =
        UInt32(IN_CREATE) | UInt32(IN_CLOSE_WRITE) | UInt32(IN_MODIFY) | UInt32(IN_MOVED_FROM)
        | UInt32(IN_MOVED_TO) | UInt32(IN_DELETE) | UInt32(IN_DELETE_SELF) | UInt32(IN_MOVE_SELF)
        | UInt32(IN_ATTRIB)

    /// One read's buffer: room for many records, and always for the largest one
    /// (header + NAME_MAX + NUL).
    private static let bufferSize = 16 * 1024
    /// Reads per wakeup before yielding the queue; the read source fires again if more is queued.
    private static let maxReadsPerWakeup = 16

    private let onEvent: @Sendable (FileWatchEvent) -> Void
    private let storage: Mutex<Storage>

    private struct Storage {
        /// The inotify fd, or -1 once cancelled. Closed by the source's cancel handler only.
        var fd: Int32
        var source: (any DispatchSourceRead)?
        var nextID: UInt64 = 1
        var watches: [Int32: Watch] = [:]
        var descriptors: [FileWatchID: Int32] = [:]
    }

    private struct Watch {
        var id: FileWatchID
        var filter: @Sendable (String) -> Bool
    }

    /// A translated record whose name filter has not run yet.
    private enum Pending {
        case event(FileWatchEvent)
        case change(FileWatchChange, filter: @Sendable (String) -> Bool)
    }

    /// Creates the inotify instance. Events are delivered on `queue`, in order.
    public init(
        queue: DispatchQueue, onEvent: @escaping @Sendable (FileWatchEvent) -> Void
    ) throws(FileWatcherError) {
        let fd = inotify_init1(Int32(IN_NONBLOCK) | Int32(IN_CLOEXEC))
        guard fd >= 0 else { throw .instanceError(errno: errno) }
        self.onEvent = onEvent
        self.storage = Mutex(Storage(fd: fd, source: nil))
        // Made inside the lock, so the source never exists outside it.
        storage.withLock { s in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            source.setCancelHandler { close(fd) }
            s.source = source
            source.resume()
        }
    }

    deinit {
        cancel()
    }

    @discardableResult
    public func add(
        directory path: String, filter: @escaping @Sendable (String) -> Bool
    ) throws(FileWatcherError) -> FileWatchID {
        try storage.withLock { s throws(FileWatcherError) -> FileWatchID in
            guard s.fd >= 0 else { throw .cancelled }
            // Under the lock, so an event for the new wd cannot be translated before it is known.
            let wd = inotify_add_watch(
                s.fd, path, Self.eventMask | UInt32(IN_ONLYDIR) | UInt32(IN_MASK_CREATE))
            guard wd >= 0 else { throw .watchError(errno: errno) }
            let id = FileWatchID(raw: s.nextID)
            s.nextID += 1
            s.watches[wd] = Watch(id: id, filter: filter)
            s.descriptors[id] = wd
            return id
        }
    }

    public func remove(_ watch: FileWatchID) {
        storage.withLock { s in
            guard let wd = s.descriptors.removeValue(forKey: watch) else { return }
            s.watches[wd] = nil
            if s.fd >= 0 { inotify_rm_watch(s.fd, wd) }
        }
    }

    public func cancel() {
        storage.withLock { s in
            guard s.fd >= 0 else { return }
            // The cancel handler closes the fd once no handler can still be reading it.
            s.source?.cancel()
            s.source = nil
            s.fd = -1
            s.watches.removeAll()
            s.descriptors.removeAll()
        }
    }

    public var watchCount: Int {
        storage.withLock { $0.watches.count }
    }

    // MARK: - Reading (on the queue)

    private func drain() {
        let fd = storage.withLock { $0.fd }
        guard fd >= 0 else { return }
        withUnsafeTemporaryAllocation(byteCount: Self.bufferSize, alignment: 8) { buffer in
            for _ in 0..<Self.maxReadsPerWakeup {
                let count = read(fd, buffer.baseAddress, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }  // EAGAIN: drained
                deliver(InotifyRecord.parse(UnsafeRawBufferPointer(rebasing: buffer[0..<count])))
            }
        }
    }

    /// Translates `records` one at a time and hands the events that pass their filters to the
    /// handler. Each record is translated after the previous event was handled, so a `remove` or
    /// `cancel` from inside the handler holds for the rest of the batch. Internal so the tests can
    /// feed records the kernel is hard to provoke into (overflow, stale wds).
    func deliver(_ records: [InotifyRecord]) {
        for record in records {
            switch storage.withLock({ s in Self.translate(record, &s) }) {
            case nil:
                continue
            case .event(let event):
                onEvent(event)
            case .change(let change, let filter):
                if let name = change.name, !filter(name) { continue }
                onEvent(.changed(change))
            }
        }
    }

    /// Maps one record to an event and retires an ended watch. Runs under the lock.
    private static func translate(_ record: InotifyRecord, _ s: inout Storage) -> Pending? {
        // After cancel nothing is reported, not even an overflow already read.
        guard s.fd >= 0 else { return nil }
        let mask = record.mask
        if mask & UInt32(IN_Q_OVERFLOW) != 0 { return .event(.overflow) }
        // Records for a watch `remove` already dropped are stale.
        guard let watch = s.watches[record.wd] else { return nil }
        if mask & UInt32(IN_IGNORED) != 0 {
            s.watches[record.wd] = nil
            s.descriptors[watch.id] = nil
            return .event(.watchRemoved(watch.id))
        }
        if mask & UInt32(IN_MOVE_SELF) != 0 {
            // The kernel would keep watching the directory at its new path; tkzmux watches
            // paths, so end it here. The IN_IGNORED this causes finds no watch.
            s.watches[record.wd] = nil
            s.descriptors[watch.id] = nil
            inotify_rm_watch(s.fd, record.wd)
            return .event(.watchRemoved(watch.id))
        }
        guard let kind = changeKind(mask) else { return nil }  // IN_DELETE_SELF, IN_UNMOUNT
        let change = FileWatchChange(
            watch: watch.id, name: record.name, kind: kind, isDirectory: mask & UInt32(IN_ISDIR) != 0)
        return .change(change, filter: watch.filter)
    }

    /// The change an event bit stands for, or nil for the bits that are not entry changes.
    static func changeKind(_ mask: UInt32) -> FileWatchChange.Kind? {
        if mask & (UInt32(IN_CREATE) | UInt32(IN_MOVED_TO)) != 0 { return .created }
        if mask & (UInt32(IN_MODIFY) | UInt32(IN_CLOSE_WRITE)) != 0 { return .modified }
        if mask & UInt32(IN_ATTRIB) != 0 { return .attributes }
        if mask & (UInt32(IN_DELETE) | UInt32(IN_MOVED_FROM)) != 0 { return .removed }
        return nil
    }
}

extension FileWatcherError {
    /// The error for a failed `inotify_init1`.
    static func instanceError(errno code: Int32) -> FileWatcherError {
        switch code {
        case EMFILE, ENFILE: .instanceLimitReached
        default: .system(code)
        }
    }

    /// The error for a failed `inotify_add_watch`.
    static func watchError(errno code: Int32) -> FileWatcherError {
        switch code {
        case ENOSPC: .watchLimitReached
        case ENOENT: .noSuchDirectory
        case ENOTDIR: .notADirectory
        case EACCES: .permissionDenied
        case EEXIST: .alreadyWatched
        default: .system(code)
        }
    }
}
#endif
