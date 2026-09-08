// `~/Library/Application Support/tkzmux/state.json` — everything the user arranged.
//
// design.md → *Session flows & persistence*: "500 ms debounced atomic write + `.bak`; corrupt →
// `.bak` + notice". The debounce is `StateAutosaver`; the atomicity is here, and it is the whole
// point of the type, so the write sequence deserves to be spelled out.
//
// ## Why the rotation looks like this
//
//     write  .state.<rand>.tmp        (same directory, so the rename cannot cross a mount)
//     fsync  the temp file            (the rename is atomic; the *contents* can lag it otherwise)
//     link   state.json -> .bak.new   (ENOENT is fine: there is no primary on the first write)
//     rename .bak.new -> .bak         (atomic replace)
//     rename tmp -> state.json        (atomic replace)
//
// Two simpler sequences are wrong, and both fail exactly the acceptance criterion this file exists
// for ("50 SIGKILLs never produce an unparsable state.json"):
//
//   * `rename(state.json -> .bak); rename(tmp -> state.json)` leaves a window in which `state.json`
//     does not exist at all — neither the old complete version nor the new one.
//   * `unlink(.bak); link(state.json -> .bak)` leaves a window in which the *backup* does not
//     exist, and it opens precisely when the backup is the only good copy: after a
//     recovered-from-backup launch the primary has been quarantined, so `link` fails with ENOENT
//     and a kill before the last rename loses both files.
//
// Staging the backup under `.bak.new` and replacing it with a rename keeps both names pointing at a
// complete file at every instant. A hard link is used rather than a copy because it is atomic and
// costs no bytes: the backup is the *same* inode until the next write replaces the primary.

import Foundation
import TkzCore

public enum StateFileError: Error, Equatable, Sendable {
    case writeFailed(errno: Int32)
    /// A `save` was attempted on a file this build refuses to write (see `LoadOutcome.blocked`).
    case writingBlocked
}

/// What `load` found, and where it found it.
public enum StateSource: Hashable, Sendable {
    /// `state.json` parsed.
    case primary
    /// `state.json` was missing or corrupt and `state.json.bak` parsed.
    case backup
    /// Neither parsed. The app starts empty; any corrupt file has been kept.
    case empty
    /// `state.json` was written by a newer tkzmux. Nothing was loaded and nothing may be written.
    case futureVersion(found: Int, supported: Int)
}

public struct LoadResult: Sendable {
    /// `nil` for `.empty` and `.futureVersion`.
    public var document: StateDocument?
    public var source: StateSource
    /// Paths of files quarantined as `state.json.corrupt-<timestamp>`.
    public var quarantined: [URL]

    /// May the autosaver write? False only for a file from the future, which we would clobber.
    public var isWritable: Bool {
        if case .futureVersion = source { return false }
        return true
    }

    /// The message the status bar shows, or `nil` when everything was normal.
    public var notice: String? {
        switch source {
        case .primary: nil
        case .backup: "Restored sidebar from backup"
        case .empty: quarantined.isEmpty ? nil : "state.json was unreadable — started empty"
        case .futureVersion:
            "state.json is from a newer tkzmux — changes won't be saved"
        }
    }
}

public struct StateFile: Sendable, Hashable {
    /// `state.json`.
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/tkzmux/state.json`, beside `SnapshotStore.standard()`'s
    /// `sessions/`. Only production code may use this; tests pass a temp directory.
    public static func standard(
        applicationSupport: URL? = nil,
        fileManager: FileManager = .default
    ) -> StateFile {
        let base = applicationSupport
            ?? (try? fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false
            ))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return StateFile(
            url: base
                .appending(path: "tkzmux", directoryHint: .isDirectory)
                .appending(path: "state.json", directoryHint: .notDirectory))
    }

    public var directory: URL { url.deletingLastPathComponent() }
    public var backupURL: URL { url.appendingPathExtension("bak") }
    var stagedBackupURL: URL { url.appendingPathExtension("bak.new") }

    // MARK: Encoding

    /// Pretty-printed with sorted keys: this file is meant to be readable, diffable and repairable
    /// by hand, and a stable key order makes "did anything change?" a byte comparison.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // NOT `.iso8601`: it truncates to whole seconds, so `createdAt` would not survive a round
        // trip and the property test would fail on equality. The default reference-date double is
        // exact.
        return encoder
    }

    /// Encodes a document: the typed state, plus any unknown top-level keys merged back in.
    public static func encode(_ document: StateDocument) throws -> Data {
        let encoder = makeEncoder()
        let typed = try encoder.encode(document.state)
        var object = try JSONDecoder().decode([String: JSONValue].self, from: typed)
        for (key, value) in document.extras where !PersistedState.knownKeys.contains(key) {
            object[key] = value
        }
        return try encoder.encode(object)
    }

    public static func decode(_ data: Data) throws -> StateDocument {
        let object = try JSONDecoder().decode([String: JSONValue].self, from: data)
        let migrated = try Migrations.migrate(object)
        let normalized = try makeEncoder().encode(migrated)
        let state = try JSONDecoder().decode(PersistedState.self, from: normalized)
        let extras = migrated.filter { !PersistedState.knownKeys.contains($0.key) }
        return StateDocument(state: state, extras: extras)
    }

    // MARK: Write

    public func save(_ document: StateDocument, fileManager: FileManager = .default) throws {
        try save(Self.encode(document), fileManager: fileManager)
    }

    /// The rotation described in the file header.
    func save(_ data: Data, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = directory.appending(
            path: ".state.\(UInt64.random(in: 0..<UInt64.max)).tmp", directoryHint: .notDirectory)
        do {
            try data.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        // Stage the backup as a *new* name, then replace `.bak` with a rename. Both `state.json`
        // and `state.json.bak` therefore name a complete file at every point a SIGKILL can land.
        if Self.link(url, to: stagedBackupURL) == 0 {
            if Self.rename(stagedBackupURL, to: backupURL) != 0 {
                try? fileManager.removeItem(at: stagedBackupURL)
            }
        } else if errno != ENOENT {
            // Anything but "there is no primary yet" is worth not silently ignoring, but it must
            // not stop the save: a missing backup is recoverable, a missing primary is not.
            try? fileManager.removeItem(at: stagedBackupURL)
        }

        guard Self.rename(temporary, to: url) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: temporary)
            throw StateFileError.writeFailed(errno: code)
        }
    }

    // MARK: Read

    /// Never throws: a persistence layer that refuses to start the app is worse than one that
    /// starts it empty. Everything it had to do about a bad file is in the result.
    public func load(fileManager: FileManager = .default, now: Date = Date()) -> LoadResult {
        var quarantined: [URL] = []
        sweepTemporaries(fileManager: fileManager)

        let primary = (try? Data(contentsOf: url)).map { data in Result { try Self.decode(data) } }

        if case .success(let document)? = primary {
            return LoadResult(document: document, source: .primary, quarantined: [])
        }
        // A file from the future must not be worked around by falling back to an older backup: the
        // newer build wrote the primary, and writing v1 over it would destroy what it stored.
        if case .failure(let error)? = primary,
           case MigrationError.futureVersion(let found, let supported) = error
        {
            return LoadResult(
                document: nil, source: .futureVersion(found: found, supported: supported),
                quarantined: [])
        }

        let backup = (try? Data(contentsOf: backupURL)).map { data in Result { try Self.decode(data) } }

        if case .success(let document)? = backup {
            // Quarantine the bad primary *now*. If it were left in place, the next save would
            // hard-link it over `.bak` and destroy the only readable copy of the user's sidebar.
            // The test is "a file is there", not "we managed to read it": an existing but
            // unreadable primary (bad permissions) is exactly as dangerous as a corrupt one, and
            // it is the case where `Data(contentsOf:)` returned nil.
            if fileManager.fileExists(atPath: url.path),
               let kept = quarantine(url, at: now, fileManager: fileManager)
            {
                quarantined.append(kept)
            }
            return LoadResult(document: document, source: .backup, quarantined: quarantined)
        }

        for candidate in [url, backupURL] {
            if fileManager.fileExists(atPath: candidate.path),
               let kept = quarantine(candidate, at: now, fileManager: fileManager)
            {
                quarantined.append(kept)
            }
        }
        return LoadResult(document: nil, source: .empty, quarantined: quarantined)
    }

    /// Removes what a SIGKILL mid-save leaves behind: the staged backup and any unfinished temp
    /// file. Measured, not theorised — `scripts/state-crash-test.sh` reported a surviving
    /// `state.json.bak.new` in roughly one round in seven. Neither file is dangerous (the staged
    /// backup is a hard link to a complete primary), but litter in Application Support that nobody
    /// ever cleans up is its own kind of bug. Launch is the right moment: no save can be in flight.
    private func sweepTemporaries(fileManager: FileManager) {
        try? fileManager.removeItem(at: stagedBackupURL)
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in contents where file.lastPathComponent.hasPrefix(".state.")
            && file.pathExtension == "tmp"
        {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Moves a file aside as `state.json.corrupt-<timestamp>` so the user (or a bug report) still
    /// has it. Renaming rather than deleting is the whole point.
    private func quarantine(_ file: URL, at now: Date, fileManager: FileManager) -> URL? {
        let stamp = Self.timestampFormatter.string(from: now)
        var destination = directory.appending(
            path: "\(file.lastPathComponent).corrupt-\(stamp)", directoryHint: .notDirectory)
        var attempt = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appending(
                path: "\(file.lastPathComponent).corrupt-\(stamp)-\(attempt)",
                directoryHint: .notDirectory)
            attempt += 1
        }
        do {
            try fileManager.moveItem(at: file, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: Syscalls

    private static func link(_ source: URL, to destination: URL) -> Int32 {
        source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { errno = EINVAL; return -1 }
                unlink(to)
                return Foundation.link(from, to)
            }
        }
    }

    private static func rename(_ source: URL, to destination: URL) -> Int32 {
        source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { errno = EINVAL; return -1 }
                return Foundation.rename(from, to)
            }
        }
    }
}
