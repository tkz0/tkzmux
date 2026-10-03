// TranscriptWatch — "this transcript grew", debounced, for whoever shows a transcript live.
//
// Moved out of TkzApp's PromptCardController (WOR-306 S2) so the Linux views can share it; the
// prompt card is its first user. A transcript is append-only — Claude never rename-replaces it —
// so there is no inode to chase: a delete or rename simply ends the watch, and the owner opens a
// fresh one next time.
//
//   macOS  one `DispatchSource` on the file (write, extend, delete, rename), as before the move.
//   Linux  TkzPlatform's `FileWatcher` on the file's directory, filtered to its name. The entry
//          events stand in for a file watch's: IN_MODIFY/IN_CLOSE_WRITE for IN_MODIFY, and
//          IN_DELETE/IN_MOVED_FROM (or IN_MOVED_TO over it) for IN_DELETE_SELF/IN_MOVE_SELF; the
//          directory going away ends the watch too.

import Dispatch
import Foundation
import Synchronization
#if !os(macOS)
import TkzPlatform
#endif

/// One watch on a transcript file, debounced, calling back on the main actor.
public final class TranscriptWatch: Sendable {
    /// Detection and debouncing run here, not on the main queue.
    ///
    /// Noticing that a file grew, and waiting 150 ms to see whether it grew again, are not user
    /// interface work and gain nothing from the main queue — they only compete with it. Only the
    /// callback needs the main actor, and it hops there once, at the end. The concrete symptom of
    /// the old arrangement: under `swift test`, dozens of `@MainActor` suites run in parallel and
    /// keep the main thread busy, so a timer scheduled on the main queue could sit unserviced for
    /// the length of the run and the watch appeared never to fire at all.
    private static let queue = DispatchQueue(label: "se.tkz.tkzmux.transcript-watch", qos: .utility)

    private struct Storage {
        #if os(macOS)
        var source: DispatchSourceFileSystemObject?
        #else
        var watcher: (any FileWatcher)?
        #endif
        var debounce: DispatchSourceTimer?
    }

    private let storage = Mutex(Storage())
    private let onChange: @MainActor @Sendable () -> Void

    #if os(macOS)
    /// nil when the file cannot be opened.
    public init?(path: String, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: Self.queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.cancel()
                return
            }
            self.scheduleFire()
        }
        source.setCancelHandler { close(fd) }
        storage.withLock { $0.source = source }
        source.resume()
    }
    #else
    /// nil when the file does not exist or its directory cannot be watched.
    public init?(path: String, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        guard access(path, F_OK) == 0 else { return nil }
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        do throws(FileWatcherError) {
            let watcher = try SystemFileWatcher(queue: Self.queue) { [weak self] event in
                self?.handle(event)
            }
            do throws(FileWatcherError) {
                try watcher.add(directory: directory.isEmpty ? "." : directory, filter: { $0 == name })
            } catch {
                watcher.cancel()
                throw error
            }
            storage.withLock { $0.watcher = watcher }
        } catch {
            return nil
        }
    }

    private func handle(_ event: FileWatchEvent) {
        switch event {
        case .changed(let change) where change.name == nil:
            return  // the directory's own attributes
        case .changed(let change):
            switch change.kind {
            case .modified: scheduleFire()
            case .attributes: return
            // Deleted, renamed away, or replaced by a rename over it: the file this watch was
            // opened for is gone, as when the macOS source sees a delete or a rename.
            case .removed, .created: cancel()
            }
        case .overflow:
            // A write may have been dropped; one extra re-read is harmless.
            scheduleFire()
        case .watchRemoved:
            cancel()
        }
    }
    #endif

    /// The timer is made, swapped in and resumed under the lock, because corelibs Dispatch
    /// sources are not Sendable and so cannot leave it.
    private func scheduleFire() {
        storage.withLock { storage in
            let timer = DispatchSource.makeTimerSource(queue: Self.queue)
            timer.schedule(deadline: .now() + .milliseconds(150))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.storage.withLock { $0.debounce = nil }
                let onChange = self.onChange
                Task { @MainActor in onChange() }
            }
            // Replace any timer still pending: a burst of writes collapses into one fire.
            storage.debounce?.cancel()
            storage.debounce = timer
            timer.resume()
        }
    }

    /// Ends the watch; no callback starts after it. Idempotent.
    public func cancel() {
        storage.withLock { storage in
            storage.debounce?.cancel()
            storage.debounce = nil
            #if os(macOS)
            storage.source?.cancel()
            storage.source = nil
            #else
            storage.watcher?.cancel()
            storage.watcher = nil
            #endif
        }
    }
}
