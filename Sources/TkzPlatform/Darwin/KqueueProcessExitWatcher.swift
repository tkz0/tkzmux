// The macOS `ProcessExitWatcher` (WOR-304 S5): a kqueue NOTE_EXIT process source per process.
//
// kqueue never reports NOTE_EXIT for a process that exited before the source was registered, so
// after each registration the queue checks once whether the process is already gone, as Pty does
// for its child: `waitid(WNOWAIT)` sees our own exited child without reaping it, and `kill(pid, 0)`
// failing with ESRCH sees any other process that no longer exists. Whichever fires first retires
// the watch, so the handler runs once.
//
// Nothing here reaps (see ProcessExitWatcher.swift).

#if canImport(Darwin)
import Darwin
import Dispatch
import Synchronization

public final class KqueueProcessExitWatcher: ProcessExitWatcher {
    private let queue: DispatchQueue
    private let storage = Mutex(Storage())

    private struct Storage {
        var cancelled = false
        var nextID: UInt64 = 1
        var watches: [ProcessExitWatchID: Watch] = [:]
    }

    private struct Watch {
        var source: any DispatchSourceProcess
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
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in self?.fire(id) }
            s.watches[id] = Watch(source: source, onExit: onExit)
            source.resume()
            queue.async { [weak self] in
                if KqueueProcessExitWatcher.hasExited(pid) { self?.fire(id) }
            }
            return id
        }
    }

    public func cancel(_ watch: ProcessExitWatchID) {
        storage.withLock { s in s.watches.removeValue(forKey: watch)?.source.cancel() }
    }

    public func cancel() {
        storage.withLock { s in
            s.cancelled = true
            for watch in s.watches.values { watch.source.cancel() }
            s.watches.removeAll()
        }
    }

    public var watchCount: Int {
        storage.withLock { $0.watches.count }
    }

    /// The first report for a watch: retire it, then run its handler outside the lock.
    private func fire(_ id: ProcessExitWatchID) {
        let onExit = storage.withLock { s -> (@Sendable () -> Void)? in
            guard let watch = s.watches.removeValue(forKey: id) else { return nil }
            watch.source.cancel()
            return watch.onExit
        }
        onExit?()
    }

    /// Whether `pid` has already exited, without reaping it.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
            return true
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}
#endif
