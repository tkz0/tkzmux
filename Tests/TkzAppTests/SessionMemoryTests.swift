// SessionMemoryTests — the per-session subtree footprint reading.
//
// These spawn a real, deliberately nested process tree (`sh` → `sh` → `python3` holding a known
// number of MB) because that is the only way to check the two things that actually matter: that
// the walk goes deep enough to find a grandchild, and that the bytes it reports are the bytes the
// process really holds. A mock would assert the arithmetic and miss both.
//
// The shape mirrors the incident this code exists for: the runaway was five levels below the pty.

import ClaudeBridge
import Darwin
import Foundation
import Testing

@testable import TkzApp

@Suite("SessionMemory", .serialized)
struct SessionMemoryTests {

    /// A scratch directory for the shell scripts these tests spawn. Scripts rather than `-c`
    /// one-liners for a specific reason: `sh -c '<single command>'` **execs** it instead of
    /// forking, so a chain built that way collapses into one process and there is no tree left to
    /// walk. A multi-statement script cannot be exec-optimised away.
    private static func makeScript(_ name: String, _ body: String) throws -> URL {
        let dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tkzmux-sessionmem-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static var python: String? {
        ["/usr/bin/python3", "/opt/homebrew/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `sh` → `sh` → `python3` holding `mb` megabytes. Returns the outer `sh`.
    private static func spawnNestedHog(mb: Int) throws -> Process? {
        guard let python else { return nil }
        let hog = try makeScript(
            "hog.py", "a = bytearray(\(mb) * 1024 * 1024)\nimport time\ntime.sleep(30)\n")
        let inner = try makeScript("inner.sh", "\(python) \(hog.path)\nexit 0\n")
        let outer = try makeScript("outer.sh", "/bin/sh \(inner.path)\nexit 0\n")
        return try spawn(["/bin/sh", outer.path])
    }

    private static func spawn(_ argv: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(filePath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Polls until `predicate` holds or the deadline passes — the tree takes a moment to fork and
    /// the allocation a moment to touch its pages.
    private static func waitFor(
        seconds: Double = 15, _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            usleep(200_000)
        }
        return false
    }

    @Test("a sample finds a grandchild and reports the memory it really holds")
    func findsNestedHog() throws {
        let mb = 300
        guard let process = try Self.spawnNestedHog(mb: mb) else { return }  // no python3 here
        defer {
            SessionMemory.terminateTree(rootPid: process.processIdentifier, includingRoot: true)
            process.waitUntilExit()
        }
        let root = process.processIdentifier

        // The allocation lives two levels down, so this only passes if the walk descends.
        let grew = Self.waitFor {
            SessionMemory.sample(rootPid: root).footprintBytes > UInt64(mb - 60) * 1024 * 1024
        }
        #expect(grew, "expected the subtree to report at least ~\(mb) MB")

        let sample = SessionMemory.sample(rootPid: root)
        #expect(sample.processCount >= 3, "root sh + inner sh + python3")
        #expect(sample.largestPid != root, "the hog is a descendant, not the root shell")
        // `p_comm` casing varies by build (Homebrew's reports "Python").
        #expect(sample.largestName.lowercased().contains("python"))
        // The biggest single process should account for essentially all of it; the two shells are
        // ~1 MB each.
        #expect(sample.largestBytes > UInt64(mb - 60) * 1024 * 1024)
        #expect(!sample.truncated)

        // Cross-check the reading against the same accounting the OS exposes for that one pid.
        let direct = try #require(SessionMemory.footprint(of: sample.largestPid))
        #expect(direct == sample.largestBytes)
    }

    /// The user-facing point of the kill action: the memory actually comes back, and the session's
    /// own shell survives so the row is still usable.
    @Test("terminateTree releases the subtree's memory and spares the root")
    func terminateReleasesMemoryAndSparesRoot() throws {
        guard let python = Self.python else { return }
        let mb = 300
        // The root must outlive its children for "spared" to be observable, so it backgrounds the
        // hog and then `exec`s `sleep` — becoming a process with no children of its own, which a
        // plain `sleep 30` statement would not be (the shell forks for that too).
        let hog = try Self.makeScript(
            "hog.py", "a = bytearray(\(mb) * 1024 * 1024)\nimport time\ntime.sleep(30)\n")
        let outer = try Self.makeScript(
            "outer.sh", "\(python) \(hog.path) &\nexec sleep 30\n")
        let process = try Self.spawn(["/bin/sh", outer.path])
        let root = process.processIdentifier
        defer {
            SessionMemory.terminateTree(rootPid: root, includingRoot: true)
            process.waitUntilExit()
        }

        let threshold = UInt64(mb - 60) * 1024 * 1024
        #expect(Self.waitFor { SessionMemory.sample(rootPid: root).footprintBytes > threshold })

        SessionMemory.terminateTree(rootPid: root)

        // The hog's memory is gone. Note the dead child stays *listed* by
        // `proc_listchildpids` as a zombie until the root reaps it — an `exec`'d `sleep` never
        // does — so this asserts on bytes, not on the process count.
        #expect(
            Self.waitFor {
                SessionMemory.sample(rootPid: root).footprintBytes < 50 * 1024 * 1024
            })
        // Root spared: that is what lets a session's shell survive while a runaway build under it
        // is killed.
        #expect(kill(root, 0) == 0)
    }

    /// The kill action spares the root, so "what would be killed" must exclude it. For an idle
    /// session the root shell is the *biggest* process in the tree, and naming it as the thing
    /// about to be killed would be wrong on both counts.
    @Test("largest names a descendant, never the root, and descendantBytes excludes the root")
    func rootIsSeparatedFromDescendants() throws {
        guard let python = Self.python else { return }
        let mb = 250
        let hog = try Self.makeScript(
            "hog.py", "a = bytearray(\(mb) * 1024 * 1024)\nimport time\ntime.sleep(30)\n")
        let outer = try Self.makeScript("outer.sh", "\(python) \(hog.path)\nexit 0\n")
        let process = try Self.spawn(["/bin/sh", outer.path])
        let root = process.processIdentifier
        defer {
            SessionMemory.terminateTree(rootPid: root, includingRoot: true)
            process.waitUntilExit()
        }

        let threshold = UInt64(mb - 60) * 1024 * 1024
        #expect(Self.waitFor { SessionMemory.sample(rootPid: root).footprintBytes > threshold })
        let sample = SessionMemory.sample(rootPid: root)

        #expect(sample.largestPid != root)
        #expect(sample.rootBytes > 0, "the root shell has a footprint of its own")
        #expect(sample.footprintBytes == sample.rootBytes + sample.descendantBytes)
        #expect(sample.descendantBytes > threshold, "the hog is a descendant")
        #expect(sample.descendantCount == sample.processCount - 1)
    }

    /// A session that is only a shell has nothing killable, so no runaway to name.
    @Test("a lone shell reports no descendants")
    func loneShellHasNoDescendants() throws {
        let process = try Self.spawn(["/bin/sleep", "30"])
        let root = process.processIdentifier
        defer {
            kill(root, SIGKILL)
            process.waitUntilExit()
        }
        let sample = SessionMemory.sample(rootPid: root)
        #expect(sample.processCount == 1)
        #expect(sample.descendantCount == 0)
        #expect(sample.descendantBytes == 0)
        #expect(sample.largestName.isEmpty)
        #expect(sample.footprintBytes == sample.rootBytes)
    }

    @Test("an exited or bogus pid samples as empty rather than failing")
    func bogusPidIsEmpty() {
        #expect(SessionMemory.sample(rootPid: 0) == .empty)
        #expect(SessionMemory.sample(rootPid: -1) == .empty)
        // Very high pid that is almost certainly not allocated.
        #expect(SessionMemory.sample(rootPid: 999_999).footprintBytes == 0)
    }

    @Test("our own pid reads back a plausible footprint")
    func selfFootprint() throws {
        let mine = try #require(SessionMemory.footprint(of: getpid()))
        #expect(mine > 1024 * 1024, "a running test process holds more than 1 MB")
        #expect(!SessionMemory.name(of: getpid()).isEmpty)
    }

    /// The old walk stopped at six levels, which is shallower than the real chain
    /// (zsh → claude → bash → swift-package → helper) and would have hidden the runaway.
    @Test("the descendant walk is bounded by process count, not by a shallow depth")
    func walkIsCountBounded() throws {
        // Ten nested shells: deeper than the old maxDepth of 6. The script recurses on itself so
        // each level is a real fork (see `makeScript` on why `sh -c` would not be).
        let deep = try Self.makeScript(
            "deep.sh",
            """
            n=$1
            if [ "$n" -le 0 ]; then
              sleep 30
              exit 0
            fi
            /bin/sh "$0" $((n - 1))
            exit 0
            """)
        let process = try Self.spawn(["/bin/sh", deep.path, "10"])
        let root = process.processIdentifier
        defer {
            SessionMemory.terminateTree(rootPid: root, includingRoot: true)
            process.waitUntilExit()
        }

        let deepEnough = Self.waitFor { ProcessTree.descendants(of: root).count >= 8 }
        #expect(deepEnough, "a 10-deep chain must be walked past the old 6-level cap")
        // And the cap is honoured.
        #expect(ProcessTree.descendants(of: root, maxProcesses: 3).count == 3)
    }
}
