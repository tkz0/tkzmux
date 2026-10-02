// ProcessExitWatcher — "tell me when this process exits", per OS (WOR-304 S5).
//
//   Linux  `PidfdProcessExitWatcher` (Linux/): pidfd_open(2) through TkzPlatformShim, wrapped in a
//          dispatch read source. A pidfd becomes readable when the process exits and stays
//          readable, so the source is cancelled after the first event. Linux 5.3 or later.
//   macOS  `KqueueProcessExitWatcher` (Darwin/): a kqueue NOTE_EXIT process source.
//
// `SystemProcessExitWatcher` names the back-end for the OS being built.
//
// The watcher NEVER reaps. Reaping is the owner's job: for a child it spawned, the owner calls
// `waitpid(pid, &status, WNOHANG)` in the exit handler, or the child stays a zombie. That keeps
// the exit status with the owner, and keeps the watcher usable for processes that are not its
// children (where only the parent can reap). For a pid that is not the owner's child, the pid may
// be reused once the parent reaps it: check the start time (ProcessTable, S6) before trusting it.
//
// The pty's own child exit is not watched through here: Pty keeps its own pidfd from clone3
// (WOR-305). Consumers: the sound player (WOR-320).

import Dispatch

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Identifies one exit watch of one watcher. Never reused by that watcher.
public struct ProcessExitWatchID: Hashable, Sendable, CustomStringConvertible {
    let raw: UInt64

    public var description: String { "exit-watch#\(raw)" }
}

public enum ProcessExitWatcherError: Error, Hashable, Sendable {
    /// The kernel has no pidfd_open (Linux before 5.3).
    case unsupported
    /// No more file descriptors (EMFILE/ENFILE).
    case descriptorLimitReached
    /// The watcher has been cancelled.
    case cancelled
    /// Any other failure, with its errno (EINVAL for a pid that cannot name a process).
    case system(Int32)
}

/// Reports process exits, once each, on the watcher's queue. All methods may be called from any
/// thread, including from inside an exit handler.
///
/// The watcher never reaps a child: after the exit handler runs, the owner calls
/// `waitpid(pid, &status, WNOHANG)` itself, or the child stays a zombie.
public protocol ProcessExitWatcher: AnyObject, Sendable {
    /// Calls `onExit` once, on the watcher's queue, when `pid` exits. A process that has already
    /// exited (a zombie, or gone altogether) is reported straight away, asynchronously.
    @discardableResult
    func watch(pid: pid_t, onExit: @escaping @Sendable () -> Void) throws(ProcessExitWatcherError)
        -> ProcessExitWatchID

    /// Stops a watch; its handler will not run. Unknown or finished ids are ignored.
    func cancel(_ watch: ProcessExitWatchID)

    /// Stops every watch and releases their file descriptors. Idempotent.
    func cancel()

    /// How many watches are waiting for an exit.
    var watchCount: Int { get }
}

#if os(Linux)
/// The process exit watcher for the OS being built.
public typealias SystemProcessExitWatcher = PidfdProcessExitWatcher
#elseif canImport(Darwin)
/// The process exit watcher for the OS being built.
public typealias SystemProcessExitWatcher = KqueueProcessExitWatcher
#endif
