// ProcessOwnershipTests — the "is this pid under this tkzmux?" walk, driven by a fake process
// tree, plus one real-process check of the libproc-backed ancestry.
import Foundation
import Testing

@testable import AgentBridge

/// A process tree as two tables. Anything not in `parents` has no parent (the lookup fails).
struct FakeAncestry: ProcessAncestry {
    var parents: [pid_t: pid_t] = [:]
    var names: [pid_t: String] = [:]
    func parent(of pid: pid_t) -> pid_t? { parents[pid] }
    func name(of pid: pid_t) -> String? { names[pid] }
}

@Suite struct ProcessOwnershipTests {
    private let selfPid: pid_t = 777

    private func owns(_ pid: pid_t, _ tree: FakeAncestry, selfName: String = "tkzmux", maxDepth: Int = 16) -> Bool {
        ProcessOwnership.owns(pid, selfPid: selfPid, selfName: selfName, ancestry: tree, maxDepth: maxDepth)
    }

    @Test("a pid whose ancestry reaches this process is ours")
    func reachesSelf() {
        // claude → pane zsh → tkzmux (us) → launchd
        let tree = FakeAncestry(parents: [5000: 4000, 4000: 777, 777: 1], names: [777: "tkzmux"])
        #expect(owns(5000, tree))
        #expect(owns(4000, tree))
        #expect(owns(777, tree), "the process itself is its own")
    }

    @Test("crossing another process with our name is not ours — the dev build in a pane")
    func foreignInstanceBetween() {
        // claude → dev zsh → dev tkzmux → our pane zsh → us
        let tree = FakeAncestry(
            parents: [5000: 4000, 4000: 900, 900: 300, 300: 777, 777: 1],
            names: [900: "tkzmux", 777: "tkzmux"])
        #expect(!owns(5000, tree))
        #expect(!owns(900, tree), "the foreign instance itself is not ours either")
        #expect(owns(300, tree), "our own pane's shell still is")
    }

    @Test("the self-pid test comes before the name test")
    func selfIsNeverForeign() {
        let tree = FakeAncestry(parents: [5000: 777], names: [777: "tkzmux", 5000: "claude"])
        #expect(owns(5000, tree))
    }

    @Test("reaching launchd, a failed lookup, a self-parented pid or the depth limit is not ours")
    func negativeTerminations() {
        #expect(!owns(5000, FakeAncestry(parents: [5000: 4000, 4000: 1])), "launchd")
        #expect(!owns(5000, FakeAncestry(parents: [5000: 4000])), "no parent for 4000")
        #expect(!owns(5000, FakeAncestry(parents: [5000: 4000, 4000: 4000])), "self-parented")
        #expect(!owns(0, FakeAncestry()), "pid 0")
        #expect(!owns(1, FakeAncestry()), "pid 1")
        var deep: [pid_t: pid_t] = [:]
        for i in 0..<20 { deep[pid_t(5000 + i)] = pid_t(5001 + i) }
        deep[5020] = 777
        #expect(!owns(5000, FakeAncestry(parents: deep), maxDepth: 16), "21 steps away, limit 16")
        #expect(owns(5000, FakeAncestry(parents: deep), maxDepth: 32), "and reachable with room")
    }

    @Test("an empty self name disables only the name test")
    func emptyNameSkipsTheForeignCheck() {
        let tree = FakeAncestry(
            parents: [5000: 4000, 4000: 900, 900: 300, 300: 777],
            names: [900: "tkzmux", 777: "tkzmux"])
        #expect(owns(5000, tree, selfName: ""))
        #expect(!owns(6000, FakeAncestry(parents: [6000: 1]), selfName: ""))
    }
}

@Suite(.serialized)
struct SystemProcessAncestryTests {
    @Test("names come from proc_name, and a spawned child is owned by this process")
    func realProcessIsOwned() throws {
        let ancestry = SystemProcessAncestry()
        let own = try #require(ProcessTree.name(of: getpid()))
        #expect(!own.isEmpty)
        #expect(ProcessTree.name(of: 999_999) == nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The trailing no-op keeps sh from exec-ing sleep in place (see ProcessTreeTests).
        process.arguments = ["-c", "sleep 30; true"]
        try process.run()
        let shPid = process.processIdentifier
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        var sleepPid: pid_t?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let found = ProcessTree.descendants(of: shPid).first(where: { $0 != shPid }) {
                sleepPid = found
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let sleep = try #require(sleepPid)

        #expect(ancestry.parent(of: sleep) == shPid)
        #expect(ancestry.parent(of: shPid) == getpid())
        // `/bin/sh` is bash on macOS and reports as such; only the shape matters here.
        let shName = try #require(ancestry.name(of: shPid))
        #expect(!shName.isEmpty && shName != own)
        #expect(ProcessOwnership.owns(sleep, selfPid: getpid(), selfName: own, ancestry: ancestry))
        // A stranger's pid, one with our name in its ancestry only if we are it: launchd's own
        // children are not under us.
        #expect(!ProcessOwnership.owns(1, selfPid: getpid(), selfName: own, ancestry: ancestry))

        kill(sleep, SIGKILL)
        kill(shPid, SIGKILL)
        process.waitUntilExit()
    }
}
