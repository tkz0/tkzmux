// The Linux `ProcessExitWatcher` (WOR-304 S5): one pidfd per watched process.
//
// pidfd_open(2) (through TkzPlatformShim: Glibc has no <sys/pidfd.h> and Swift cannot call the
// variadic syscall()) returns an fd that polls readable once the process has exited, whether or
// not it has been reaped. It goes into a dispatch read source on the watcher's queue. A pidfd stays
// readable forever after, so the first event removes the watch and cancels the source, whose cancel
// handler closes the fd. ESRCH from pidfd_open means the process is already gone (for our own child:
// already reaped), which is reported like an exit.
//
// Nothing here calls waitpid: the owner reaps (see ProcessExitWatcher.swift).

#if os(Linux)
import Dispatch
import Glibc
import Synchronization
import TkzPlatformShim

public final class PidfdProcessExitWatcher: ProcessExitWatcher {
    private let queue: DispatchQueue
    private let storage = Mutex(Storage())

    private struct Storage {
        var cancelled = false
        var nextID: UInt64 = 1
        var watches: [ProcessExitWatchID: Watch] = [:]
    }

    private struct Watch {
        /// nil for a process that was gone before it could be watched.
        var source: (any DispatchSourceRead)?
        var onExit: @Sendable () -> Void
    }

    /// Exit handlers run on `queue`.
    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        cancel()
    }

    @discardableResult
    public func watch(
        pid: pid_t, onExit: @escaping @Sendable () -> Void
    ) throws(ProcessExitWatcherError) -> ProcessExitWatchID {
        try storage.withLock { s throws(ProcessExitWatcherError) -> ProcessExitWatchID in
            guard !s.cancelled else { throw .cancelled }
            guard pid > 0 else { throw .system(EINVAL) }
            let id = ProcessExitWatchID(raw: s.nextID)
            s.nextID += 1
            let fd = tkz_pidfd_open(pid, 0)
            guard fd >= 0 else {
                let code = errno
                guard code == ESRCH else { throw .pidfdError(errno: code) }
                s.watches[id] = Watch(source: nil, onExit: onExit)
                queue.async { [weak self] in self?.fire(id) }
                return id
            }
            // Kept in `storage`: an unretained source is deallocated and never fires on Linux.
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.fire(id) }
            source.setCancelHandler { close(fd) }
            s.watches[id] = Watch(source: source, onExit: onExit)
            source.resume()
            return id
        }
    }

    public func cancel(_ watch: ProcessExitWatchID) {
        storage.withLock { s in s.watches.removeValue(forKey: watch)?.source?.cancel() }
    }

    public func cancel() {
        storage.withLock { s in
            s.cancelled = true
            for watch in s.watches.values { watch.source?.cancel() }
            s.watches.removeAll()
        }
    }

    public var watchCount: Int {
        storage.withLock { $0.watches.count }
    }

    /// The first event for a watch: retire it, then run its handler (outside the lock, so the
    /// handler may watch, cancel or reap freely).
    private func fire(_ id: ProcessExitWatchID) {
        let onExit = storage.withLock { s -> (@Sendable () -> Void)? in
            guard let watch = s.watches.removeValue(forKey: id) else { return nil }
            watch.source?.cancel()
            return watch.onExit
        }
        onExit?()
    }
}

extension ProcessExitWatcherError {
    /// The error for a failed `pidfd_open` other than ESRCH.
    static func pidfdError(errno code: Int32) -> ProcessExitWatcherError {
        switch code {
        case ENOSYS: .unsupported
        case EMFILE, ENFILE: .descriptorLimitReached
        default: .system(code)
        }
    }
}
#endif
