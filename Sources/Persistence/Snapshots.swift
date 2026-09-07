// Snapshots.swift — `.ghsnap` files on disk. See docs/design.md → *Terminal engine → Snapshot*
// and *Session flows & persistence*, and docs/perf.md for the measured sizes and timings.
//
// `TerminalSession` owns the *encoding* (`snapshot() -> Data`, `restore(from:)`); this file owns
// the *file system*: where a snapshot lives, how it is written without ever leaving a truncated
// file behind, how much disk the set of them costs, and when a stale one is deleted.
//
// The directory is injectable for exactly one reason: tests must never write to the real
// `~/Library/Application Support/tkzmux` (shared agent brief, hard rule 8). `SnapshotStore.standard`
// is the only place the real location is spelled out.

import Darwin
import Foundation

/// One `.ghsnap` file on disk.
public struct SnapshotEntry: Sendable, Hashable {
    /// The session id — the file's basename without the `.ghsnap` extension.
    public let id: String
    public let url: URL
    public let byteCount: Int
    public let modifiedAt: Date

    public init(id: String, url: URL, byteCount: Int, modifiedAt: Date) {
        self.id = id
        self.url = url
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

/// How much scrollback a snapshot is allowed to carry.
///
/// design.md says to "lower `SCROLLBACK_MAX_BYTES` first to bound size" before encoding. That is a
/// *terminal* option, so `SnapshotStore` cannot apply it itself — it can only pass the bound to the
/// closure that does the encoding. `maxBytes == nil` means "encode whatever the session holds".
///
/// Whether the bound is worth applying is a measurement, not an assumption: see docs/perf.md →
/// *Snapshot size vs scrollback*.
public struct SnapshotBounding: Sendable, Hashable {
    /// The `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` value to encode under, or `nil` for none.
    public var maxBytes: Int?

    public init(maxBytes: Int? = nil) {
        self.maxBytes = maxBytes
    }

    /// Encode the full scrollback the session is holding.
    public static let unbounded = SnapshotBounding(maxBytes: nil)

    /// A 4 MiB bound — roughly the size the M1.3 spike measured for 20 000 filled rows.
    public static let bounded4MiB = SnapshotBounding(maxBytes: 4 * 1024 * 1024)
}

/// What one `save` did.
public struct SnapshotWriteReport: Sendable, Hashable {
    public let id: String
    public let url: URL
    public let byteCount: Int
    /// Wall time for encode + write, in seconds.
    public let elapsed: Double

    public init(id: String, url: URL, byteCount: Int, elapsed: Double) {
        self.id = id
        self.url = url
        self.byteCount = byteCount
        self.elapsed = elapsed
    }
}

public enum SnapshotStoreError: Error, Equatable, Sendable {
    /// A session id that would escape the directory (`/`, `..`, empty, …).
    case invalidSessionID(String)
    case missing(String)
    case writeFailed(String, errno: Int32)
}

/// The `<dir>/<id>.ghsnap` store.
///
/// Every method is a plain file-system operation, so the type is a `Sendable` value: two callers
/// pointing at the same directory are as safe (and as unsafe) as two processes would be.
public struct SnapshotStore: Sendable, Hashable {
    public static let fileExtension = "ghsnap"
    /// How long a `.tmp` file must sit untouched before housekeeping assumes its writer died.
    public static let temporaryFileGrace: TimeInterval = 60

    /// The directory the `.ghsnap` files live in.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/tkzmux/sessions`. Only production code may use this.
    public static func standard(
        applicationSupport: URL? = nil,
        fileManager: FileManager = .default
    ) -> SnapshotStore {
        let base = applicationSupport
            ?? (try? fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false
            ))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return SnapshotStore(
            directory: base
                .appending(path: "tkzmux", directoryHint: .isDirectory)
                .appending(path: "sessions", directoryHint: .isDirectory)
        )
    }

    // MARK: Paths

    /// A session id is a single path component: no separators, no `.`/`..`, not empty.
    public static func isValidSessionID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\0")
    }

    public func url(for id: String) throws -> URL {
        guard SnapshotStore.isValidSessionID(id) else { throw SnapshotStoreError.invalidSessionID(id) }
        return directory.appending(path: "\(id).\(SnapshotStore.fileExtension)", directoryHint: .notDirectory)
    }

    public func createDirectory(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Write

    /// Atomically write bytes for `id`: a uniquely named temp file in the *same* directory (so the
    /// rename cannot cross a file-system boundary) is `fsync`'d and then `rename(2)`d over the
    /// destination. A reader therefore sees either the old file or the new one, never a partial.
    @discardableResult
    public func save(_ data: Data, for id: String, fileManager: FileManager = .default) throws -> SnapshotWriteReport {
        let start = DispatchTime.now().uptimeNanoseconds
        let destination = try url(for: id)
        try createDirectory(fileManager: fileManager)

        let temporary = directory.appending(
            path: ".\(id).\(UInt64.random(in: 0..<UInt64.max)).tmp", directoryHint: .notDirectory
        )
        do {
            try data.write(to: temporary)
            // Durability: the rename is atomic, but without the fsync the *contents* can lag it.
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        let renamed = temporary.withUnsafeFileSystemRepresentation { source -> Int32 in
            destination.withUnsafeFileSystemRepresentation { target -> Int32 in
                guard let source, let target else { return -1 }
                return rename(source, target)
            }
        }
        guard renamed == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw SnapshotStoreError.writeFailed(id, errno: code)
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        return SnapshotWriteReport(id: id, url: destination, byteCount: data.count, elapsed: elapsed)
    }

    /// `save` for a session that encodes itself. `encode` receives the bound from `bounding` so the
    /// caller — which is the only code that can reach `TerminalSessionOptions` — can apply it.
    @discardableResult
    public func save(
        for id: String,
        bounding: SnapshotBounding = .unbounded,
        fileManager: FileManager = .default,
        encode: (Int?) throws -> Data
    ) throws -> SnapshotWriteReport {
        let start = DispatchTime.now().uptimeNanoseconds
        let data = try encode(bounding.maxBytes)
        let report = try save(data, for: id, fileManager: fileManager)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        return SnapshotWriteReport(id: report.id, url: report.url, byteCount: report.byteCount, elapsed: elapsed)
    }

    // MARK: Read

    public func exists(_ id: String, fileManager: FileManager = .default) -> Bool {
        guard let url = try? url(for: id) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    public func load(_ id: String) throws -> Data {
        let url = try url(for: id)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SnapshotStoreError.missing(id)
        }
    }

    @discardableResult
    public func delete(_ id: String, fileManager: FileManager = .default) throws -> Bool {
        let url = try url(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        try fileManager.removeItem(at: url)
        return true
    }

    /// Every `.ghsnap` in the directory, sorted by id. A missing directory is an empty store, not
    /// an error — nothing has been saved yet.
    public func list(fileManager: FileManager = .default) throws -> [SnapshotEntry] {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return contents
            .filter { $0.pathExtension == SnapshotStore.fileExtension }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return SnapshotEntry(
                    id: url.deletingPathExtension().lastPathComponent,
                    url: url,
                    byteCount: values?.fileSize ?? 0,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.id < $1.id }
    }

    /// Total bytes of every `.ghsnap` in the store (what the sidebar's "snapshots" accounting shows).
    public func totalByteCount(fileManager: FileManager = .default) throws -> Int {
        try list(fileManager: fileManager).reduce(0) { $0 + $1.byteCount }
    }

    // MARK: Housekeeping

    /// What one housekeeping pass removed.
    public struct HousekeepingReport: Sendable, Hashable {
        /// Snapshots whose session no longer exists in `state.json`.
        public var orphaned: [String] = []
        /// Snapshots older than the age limit.
        public var stale: [String] = []
        /// Leftover `.tmp` files from an interrupted write.
        public var temporaries: Int = 0
        public var reclaimedBytes: Int = 0

        public var removed: [String] { (orphaned + stale).sorted() }
    }

    /// Delete snapshots that no live session claims, snapshots older than `maximumAge`, and any
    /// temp file a crashed write left behind.
    ///
    /// - Parameters:
    ///   - liveSessionIDs: ids still present in `state.json`. Everything else is orphaned.
    ///   - maximumAge: age limit for a *live* session's snapshot (`nil` = never stale).
    ///   - now: injected so the age rule is testable without sleeping.
    @discardableResult
    public func housekeep(
        liveSessionIDs: Set<String>,
        maximumAge: TimeInterval? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> HousekeepingReport {
        var report = HousekeepingReport()
        for entry in try list(fileManager: fileManager) {
            if !liveSessionIDs.contains(entry.id) {
                try fileManager.removeItem(at: entry.url)
                report.orphaned.append(entry.id)
                report.reclaimedBytes += entry.byteCount
            } else if let maximumAge, now.timeIntervalSince(entry.modifiedAt) > maximumAge {
                try fileManager.removeItem(at: entry.url)
                report.stale.append(entry.id)
                report.reclaimedBytes += entry.byteCount
            }
        }
        // Interrupted writes leave `.<id>.<n>.tmp` behind; they are hidden, so `list` skips them.
        // Age-gated: a temp file younger than `temporaryFileGrace` may belong to a `save` that is
        // mid-`fsync` right now, and deleting it would make that save fail at the rename.
        let all = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        for url in all where url.pathExtension == "tmp" && url.lastPathComponent.hasPrefix(".") {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > SnapshotStore.temporaryFileGrace else { continue }
            report.reclaimedBytes += values?.fileSize ?? 0
            try fileManager.removeItem(at: url)
            report.temporaries += 1
        }
        report.orphaned.sort()
        report.stale.sort()
        return report
    }
}
