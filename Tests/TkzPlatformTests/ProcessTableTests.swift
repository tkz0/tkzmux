// ProcessTable (WOR-304 S6): a 3-level process tree comes back exactly, with the right parents,
// names, start times, executables and working directories; gone processes read as nothing. On
// Linux also: /proc/<pid>/stat is parsed from its last `)`, so a comm of `a) b (c` survives (both a
// synthetic line and a live process with that name), `startTicks` is field 22, the
// /proc/*/stat fallback finds the same children as the children files, and a deleted executable
// keeps its path without ` (deleted)`.

import Foundation
import Testing
@testable import TkzPlatform

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif

extension WatcherTests {
    @Suite struct ProcessTableTests {
        /// test runner → A (sh) → B (sh) → D (sleep), and A → C (sleep). Each process writes its
        /// own pid (or its background child's) to a file, so the expected tree is known without
        /// asking ProcessTable.
        struct Tree {
            let a: pid_t, b: pid_t, c: pid_t, d: pid_t
            let directory: ScratchDirectory

            init() async throws {
                directory = try ScratchDirectory()
                let script = """
                    /bin/sh -c 'echo $$ > "$0/b.tmp"; mv "$0/b.tmp" "$0/b"; \
                    /bin/sleep 30 & echo $! > "$0/d.tmp"; mv "$0/d.tmp" "$0/d"; wait' "$1" &
                    /bin/sleep 30 &
                    echo $! > "$1/c.tmp"; mv "$1/c.tmp" "$1/c"
                    wait
                    """
                a = try spawnChild("/bin/sh", ["-c", script, "sh", directory.path])
                let deadline = ContinuousClock.now + .seconds(5)
                var pids: [pid_t?] = [nil, nil, nil]
                while ContinuousClock.now < deadline {
                    pids = ["b", "c", "d"].map { [directory] in
                        (try? String(contentsOfFile: directory.file($0), encoding: .utf8))
                            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    }
                    if pids.allSatisfy({ $0 != nil }) { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let b = pids[0], let c = pids[1], let d = pids[2] else {
                    Self.killAll([a])
                    reapBlocking(a)
                    directory.remove()
                    throw POSIXError(.ETIMEDOUT)
                }
                (self.b, self.c, self.d) = (b, c, d)
            }

            func tearDown() {
                Self.killAll([d, c, b, a])
                reapBlocking(a)
                directory.remove()
            }

            static func killAll(_ pids: [pid_t]) {
                for pid in pids { kill(pid, SIGKILL) }
            }
        }

        @Test func threeLevelTreeComesBackExactly() async throws {
            let tree = try await Tree()
            defer { tree.tearDown() }

            #expect(Set(ProcessTable.children(of: getpid())).contains(tree.a))
            #expect(Set(ProcessTable.children(of: tree.a)) == [tree.b, tree.c])
            #expect(ProcessTable.children(of: tree.b) == [tree.d])
            #expect(ProcessTable.children(of: tree.d).isEmpty)

            let descendants = ProcessTable.descendants(of: tree.a)
            #expect(descendants.count == 3)
            #expect(Set(descendants) == [tree.b, tree.c, tree.d])
            // Breadth first: both children of A before the grandchild.
            #expect(descendants.last == tree.d)
            #expect(Set(ProcessTable.descendants(of: tree.a, maxDepth: 1)) == [tree.b, tree.c])
            #expect(ProcessTable.descendants(of: tree.a, maxProcesses: 2).count == 2)
            #expect(ProcessTable.descendants(of: tree.d).isEmpty)

            #expect(ProcessTable.parent(of: tree.a) == getpid())
            #expect(ProcessTable.parent(of: tree.b) == tree.a)
            #expect(ProcessTable.parent(of: tree.c) == tree.a)
            #expect(ProcessTable.parent(of: tree.d) == tree.b)

            #if os(Linux)
            #expect(ProcessTable.name(of: tree.a) == "sh")
            #expect(ProcessTable.name(of: tree.b) == "sh")
            #else
            // macOS's /bin/sh execs the shell /private/var/select/sh names (bash by default), so
            // the name is that shell's.
            let shell = ProcessTable.name(of: tree.a)
            #expect(shell != nil)
            #expect(ProcessTable.name(of: tree.b) == shell)
            #endif
            #expect(ProcessTable.name(of: tree.c) == "sleep")
            #expect(ProcessTable.name(of: tree.d) == "sleep")

            #expect(ProcessTable.exe(of: tree.d).map(realPath) == realPath("/bin/sleep"))
            #expect(ProcessTable.cwd(of: tree.d).map(realPath) == realPath(FileManager.default.currentDirectoryPath))

            #if os(Linux)
            // The fallback for kernels without children files sees the same tree.
            print("ProcessTable: kernel lists children: \(ProcfsProcessTable.kernelListsChildren)")
            #expect(Set(ProcfsProcessTable.childrenFromStat(of: tree.a)) == [tree.b, tree.c])
            #expect(ProcfsProcessTable.childrenFromStat(of: tree.b) == [tree.d])
            #endif
        }

        @Test func startTimesAreNowAndOrdered() async throws {
            let before = Date()
            let first = try spawnChild("/bin/sleep", ["30"])
            try await Task.sleep(for: .milliseconds(30))  // more than one 10 ms tick
            let second = try spawnChild("/bin/sleep", ["30"])
            defer {
                for pid in [first, second] {
                    kill(pid, SIGKILL)
                    reapBlocking(pid)
                }
            }
            // Linux's boot time is whole seconds, so a start time is good to about a second.
            let started = try #require(ProcessTable.startTime(of: first))
            #expect(abs(started.timeIntervalSince(before)) < 2, "started \(started), spawned \(before)")
            let firstTicks = try #require(ProcessTable.startTicks(of: first))
            let secondTicks = try #require(ProcessTable.startTicks(of: second))
            #expect(secondTicks > firstTicks)
            // Our own start is before either child's.
            #expect(try #require(ProcessTable.startTicks(of: getpid())) <= firstTicks)

            #if os(Linux)
            // Field 22, counted independently of the parser.
            let stat = try String(contentsOfFile: "/proc/\(first)/stat", encoding: .utf8)
            let fields = stat[stat.index(after: try #require(stat.lastIndex(of: ")")))...]
                .split(separator: " ")
            #expect(UInt64(fields[19]) == firstTicks)
            #endif
        }

        @Test func goneProcessReadsAsNothing() throws {
            let pid = try spawnChild("/bin/sh", ["-c", "exit 0"])
            #expect(reapBlocking(pid) == pid)
            #expect(ProcessTable.children(of: pid).isEmpty)
            #expect(ProcessTable.descendants(of: pid).isEmpty)
            #expect(ProcessTable.parent(of: pid) == nil)
            #expect(ProcessTable.name(of: pid) == nil)
            #expect(ProcessTable.startTime(of: pid) == nil)
            #expect(ProcessTable.startTicks(of: pid) == nil)
            #expect(ProcessTable.exe(of: pid) == nil)
            #expect(ProcessTable.cwd(of: pid) == nil)
            // pid 1 is not ours: whatever it answers, nothing crashes.
            _ = (ProcessTable.exe(of: 1), ProcessTable.cwd(of: 1), ProcessTable.name(of: 1))
        }

        @Test func selfIsDescribed() throws {
            let me = getpid()
            #expect(ProcessTable.parent(of: me) == getppid())
            #expect(ProcessTable.cwd(of: me).map(realPath) == realPath(FileManager.default.currentDirectoryPath))
            let exe = try #require(ProcessTable.exe(of: me))
            #expect(exe.hasPrefix("/"))
            #expect(FileManager.default.isExecutableFile(atPath: exe))
        }

        #if os(Linux)
        @Test func statIsParsedFromTheLastParenthesis() throws {
            // `comm` with spaces and both parentheses; 52 fields, as a 7.x kernel writes them.
            let line = "4242 (a) b (c) S 1 4242 4242 0 -1 4194560 1065 0 0 0 1 2 0 0 20 0 1 0 1630842 "
                + "5767168 224 18446744073709551615 1 1 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0 0 0 0 0 0 0 0 0\n"
            let stat = try #require(ProcfsProcessTable.parseStat(Array(line.utf8)))
            #expect(stat.comm == "a) b (c")
            #expect(stat.state == UInt8(ascii: "S"))
            #expect(stat.ppid == 1)
            #expect(stat.startTicks == 1_630_842)

            #expect(ProcfsProcessTable.parseStat(Array("1 (x) S 0 1 1".utf8)) == nil, "too few fields")
            #expect(ProcfsProcessTable.parseStat(Array("garbage".utf8)) == nil)
            #expect(ProcfsProcessTable.parseStat(Array(") (".utf8)) == nil)
            let empty = "7 () Z 1 7 7 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 99 0 0"
            #expect(ProcfsProcessTable.parseStat(Array(empty.utf8))?.comm == "")
        }

        /// A live process whose comm is `a) b (c`: an executable of that name, which is then
        /// deleted while it runs.
        @Test func liveProcessWithParenthesesInItsName() async throws {
            let directory = try ScratchDirectory()
            defer { directory.remove() }
            let path = directory.file("a) b (c")
            try FileManager.default.copyItem(atPath: realPath("/bin/sleep"), toPath: path)
            let pid = try spawnChild(path, ["30"])
            defer {
                kill(pid, SIGKILL)
                reapBlocking(pid)
            }
            // Wait for the exec: until then the child is still a copy of the test runner.
            let deadline = ContinuousClock.now + .seconds(5)
            while ProcessTable.name(of: pid) != "a) b (c", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(ProcessTable.name(of: pid) == "a) b (c")
            let bytes = try #require(Procfs.read("/proc/\(pid)/stat"))
            let stat = try #require(ProcfsProcessTable.parseStat(bytes))
            #expect(stat.comm == "a) b (c")
            #expect(stat.ppid == getpid())
            #expect(ProcessTable.parent(of: pid) == getpid())
            #expect(ProcessTable.exe(of: pid) == realPath(path))

            // An auto-update deletes the running executable: the kernel appends ` (deleted)`.
            let realExecutable = realPath(path)
            try FileManager.default.removeItem(atPath: path)
            #expect(Procfs.readLink("/proc/\(pid)/exe") == realExecutable + " (deleted)")
            #expect(ProcessTable.exe(of: pid) == realExecutable)
        }

        @Test func childrenFilesListEveryThreadsChildren() {
            var pids: [pid_t] = []
            Procfs.appendPids(in: Array("12 345 6789 \n".utf8), to: &pids)
            Procfs.appendPids(in: [], to: &pids)
            Procfs.appendPids(in: Array("2147483647 2147483648 0 x1".utf8), to: &pids)
            #expect(pids == [12, 345, 6789, 2_147_483_647, 1])
        }

        @Test func deletedSuffixIsStripped() {
            #expect(ProcfsProcessTable.strippingDeleted("/usr/bin/claude (deleted)") == "/usr/bin/claude")
            #expect(ProcfsProcessTable.strippingDeleted("/usr/bin/claude") == "/usr/bin/claude")
            #expect(ProcfsProcessTable.strippingDeleted("/") == "/")
        }

        @Test func bootTimeAndTicksAreKnown() throws {
            #expect(ProcfsProcessTable.clockTicksPerSecond > 0)
            let boot = try #require(ProcfsProcessTable.bootTime)
            #expect(boot > 1_600_000_000)
            #expect(boot < Date().timeIntervalSince1970)
        }
        #endif
    }
}

/// `realpath(3)`, or `path` unchanged when it does not resolve.
func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
