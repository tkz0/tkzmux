// FileWatcher — "something in this directory changed", per OS (WOR-304 S5).
//
// One watcher holds many directory watches and reports every change to one handler, on the queue
// the owner gives it. Directories are watched, never single files: a watch follows an inode, so a
// file watch would stay on the old file after an atomic rename-replace, while the directory sees
// the rename. Each watch has a name filter; only entries it accepts are reported.
//
//   Linux  `InotifyFileWatcher` (Linux/): one inotify fd per watcher, any number of watches,
//          read through a dispatch read source. Every event names its entry. Kernel limits are
//          `fs.inotify.max_user_watches` (ENOSPC → `.watchLimitReached`) and
//          `max_user_instances` (EMFILE → `.instanceLimitReached`), so share one watcher per
//          owner instead of making one per directory.
//   macOS  `KqueueFileWatcher` (Darwin/): a kqueue vnode source on the directory, plus one on
//          every entry the filter accepts, because a directory vnode does not see a file being
//          rewritten in place. A directory event carries no name: it means "rescan". The watcher
//          diffs the listing itself too, so created and removed entries are still named.
//
// `SystemFileWatcher` names the back-end for the OS being built.
//
// Consumers: ClaudeSessionWatcher, StatuslineReader and TranscriptWatch move onto it in WOR-306,
// the repo watcher later.

import Dispatch

/// Identifies one directory watch of one watcher. Never reused by that watcher.
public struct FileWatchID: Hashable, Sendable, CustomStringConvertible {
    let raw: UInt64

    public var description: String { "watch#\(raw)" }
}

/// One change to an entry of a watched directory.
public struct FileWatchChange: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Created, or renamed into the directory, including a rename that replaces an entry.
        case created
        /// Written: IN_MODIFY or IN_CLOSE_WRITE on Linux, a vnode write or extend on macOS.
        case modified
        /// Permissions, ownership, timestamps or link count changed.
        case attributes
        /// Deleted, or renamed out of the directory.
        case removed
    }

    public var watch: FileWatchID
    /// The entry's name inside the directory. nil when the back-end cannot say which entry
    /// changed, or the change is to the directory itself: rescan the directory.
    public var name: String?
    public var kind: Kind
    /// The entry is a directory (Linux reports this; macOS always says false).
    public var isDirectory: Bool

    public init(watch: FileWatchID, name: String?, kind: Kind, isDirectory: Bool = false) {
        self.watch = watch
        self.name = name
        self.kind = kind
        self.isDirectory = isDirectory
    }
}

public enum FileWatchEvent: Hashable, Sendable {
    /// An entry changed. Events for one watch arrive in the order the kernel reported them.
    case changed(FileWatchChange)
    /// The kernel dropped events (inotify's IN_Q_OVERFLOW): every watched directory may have
    /// changed in ways that were not reported. Rescan them all. The watches themselves are intact.
    case overflow
    /// The watch has ended without `remove`: the directory was deleted, renamed away or unmounted.
    /// It is no longer in the watcher; add it again once the directory is back.
    case watchRemoved(FileWatchID)
}

public enum FileWatcherError: Error, Hashable, Sendable {
    /// No more watches for this user (Linux: ENOSPC, `fs.inotify.max_user_watches`).
    case watchLimitReached
    /// No more watchers for this user, or no more file descriptors (Linux: EMFILE/ENFILE,
    /// `fs.inotify.max_user_instances`).
    case instanceLimitReached
    /// The path does not exist.
    case noSuchDirectory
    /// The path is not a directory. Watch the file's directory and filter by its name.
    case notADirectory
    /// The path cannot be read.
    case permissionDenied
    /// This watcher already watches that directory (the same inode, whatever the path).
    case alreadyWatched
    /// The watcher has been cancelled.
    case cancelled
    /// Any other failure, with its errno.
    case system(Int32)
}

/// Watches directories and reports changes to their entries. All methods may be called from any
/// thread, including from inside the event handler. After `cancel()` (or deinit) no new events
/// are delivered; one already running on the queue finishes.
public protocol FileWatcher: AnyObject, Sendable {
    /// Starts watching the directory at `path`, reporting entries whose names `filter` accepts.
    /// Changes to the directory itself are always reported (with a nil name).
    @discardableResult
    func add(directory path: String, filter: @escaping @Sendable (String) -> Bool) throws(FileWatcherError)
        -> FileWatchID

    /// Stops a watch. No `.watchRemoved` follows; unknown ids are ignored.
    func remove(_ watch: FileWatchID)

    /// Stops every watch and releases the watcher's file descriptors. Idempotent.
    func cancel()

    /// How many directory watches are active.
    var watchCount: Int { get }
}

extension FileWatcher {
    /// Starts watching every entry of the directory at `path`.
    @discardableResult
    public func add(directory path: String) throws(FileWatcherError) -> FileWatchID {
        try add(directory: path, filter: { _ in true })
    }
}

#if os(Linux)
/// The file watcher for the OS being built.
public typealias SystemFileWatcher = InotifyFileWatcher
#elseif canImport(Darwin)
/// The file watcher for the OS being built.
public typealias SystemFileWatcher = KqueueFileWatcher
#endif
