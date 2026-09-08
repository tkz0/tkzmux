// PRLookupTests — the GitHub-origin gate, `gh` JSON parsing, and the caching/throttle rules
// (M4.2 / TKZ-27). Hermetic: never calls the real `gh` or the network — a stub `gh` script and a
// witness file stand in for the real thing.

import Foundation
import Synchronization
import Testing
import TkzCore

@testable import GitStatus

// `.serialized` like its process-spawning siblings in this target: several `gh`/`git` stubs
// running at once is exactly the load that used to starve libdispatch and time the lookups out.
@Suite(.serialized) struct PRLookupTests {

    // MARK: - isGitHubOrigin

    @Test(
        "isGitHubOrigin",
        arguments: [
            ("https://github.com/o/r.git", true),
            ("git@github.com:o/r.git", true),
            ("ssh://git@github.com/o/r", true),
            ("github.com:o/r", true),
            ("https://dev.azure.com/org/proj/_git/repo", false),
            ("git@ssh.dev.azure.com:v3/org/proj/repo", false),
            ("https://gitlab.com/o/r.git", false),
            // GitHub Enterprise on another host — deliberately false; the ticket scopes this to
            // github.com only, and `gh` needs separate `--hostname` config to talk to Enterprise.
            ("https://github.company.com/o/r.git", false),
            ("/local/path", false),
            ("", false),
        ]
    )
    func isGitHubOriginTable(remote: String, expected: Bool) {
        #expect(PRLookup.isGitHubOrigin(remote) == expected)
    }

    // MARK: - parsePR

    @Test func parsesFullPayload() {
        let json = """
            {"number":42,"state":"OPEN","url":"https://github.com/o/r/pull/42","isDraft":true,"reviewDecision":"APPROVED"}
            """
        let pr = PRLookup.parsePR(json)
        #expect(pr?.number == 42)
        #expect(pr?.state == "OPEN")
        #expect(pr?.url == "https://github.com/o/r/pull/42")
        #expect(pr?.isDraft == true)
        #expect(pr?.reviewDecision == "APPROVED")
    }

    @Test func parsesPayloadMissingOptionalFields() {
        let json = #"{"number":7}"#
        let pr = PRLookup.parsePR(json)
        #expect(pr?.number == 7)
        #expect(pr?.state == nil)
        #expect(pr?.url == nil)
        #expect(pr?.isDraft == false)
        #expect(pr?.reviewDecision == nil)
    }

    @Test func parsesNonPayloadsAsNil() {
        #expect(PRLookup.parsePR("") == nil)
        #expect(PRLookup.parsePR("no pull requests found for branch \"x\"") == nil)
        #expect(PRLookup.parsePR("{not json") == nil)
    }

    // MARK: - The Azure DevOps gate, end to end, without `gh`

    @Test func neverInvokesGhForAnAzureDevOpsOrigin() throws {
        let fixture = try Fixture(origin: "https://dev.azure.com/org/proj/_git/repo")
        defer { fixture.cleanup() }

        let lookup = PRLookup(ghPath: fixture.stubGhPath)
        let result = try fixture.awaitLookup(lookup, force: true)

        #expect(result == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.witnessPath) == false)
    }

    @Test func invokesGhForAGitHubOrigin() throws {
        let fixture = try Fixture(origin: "https://github.com/o/r.git")
        defer { fixture.cleanup() }

        let lookup = PRLookup(ghPath: fixture.stubGhPath)
        let result = try fixture.awaitLookup(lookup, force: true)

        #expect(FileManager.default.fileExists(atPath: fixture.witnessPath))
        #expect(result?.number == 99)
        #expect(result?.state == "OPEN")
    }

    // MARK: - Throttling

    @Test func secondNonForcedLookupDoesNotInvokeGhAgain() throws {
        let fixture = try Fixture(origin: "https://github.com/o/r.git")
        defer { fixture.cleanup() }

        let lookup = PRLookup(ghPath: fixture.stubGhPath, refreshInterval: 300)

        _ = try fixture.awaitLookup(lookup, force: true)
        #expect(fixture.witnessLineCount() == 1)

        // Same branch, not forced, within refreshInterval: nothing changed, so per the contract
        // `completion` is never called. There is nothing to await here, so instead enqueue a
        // second, *forced* lookup right after it: the private queue is serial and FIFO, so by the
        // time this one's completion fires, the non-forced lookup ahead of it has already run (or,
        // per the throttle, deliberately not run `gh`) — proving the witness is still just one line.
        let box = Mutex<PRInfo??>(nil)
        let sem = DispatchSemaphore(value: 0)
        lookup.lookup(for: fixture.sessionID, directory: fixture.repoPath, branch: "main") { _ in
            Issue.record("non-forced, unchanged lookup must not call completion")
        }
        lookup.lookup(for: fixture.sessionID, directory: fixture.repoPath, branch: "main", force: true) { pr in
            box.withLock { $0 = .some(pr) }
            sem.signal()
        }
        #expect(sem.wait(timeout: .now() + 5) == .success)
        #expect(box.withLock { $0 } != nil)

        #expect(fixture.witnessLineCount() == 2)  // only the two forced `gh` calls ran.
    }

    @Test func forcedLookupAlwaysInvokesGh() throws {
        let fixture = try Fixture(origin: "https://github.com/o/r.git")
        defer { fixture.cleanup() }

        let lookup = PRLookup(ghPath: fixture.stubGhPath)

        _ = try fixture.awaitLookup(lookup, force: true)
        _ = try fixture.awaitLookup(lookup, force: true)

        #expect(fixture.witnessLineCount() == 2)
    }

    // MARK: - Fixture

    /// A real temp git repo with a stub `gh` on disk, wired together for one test.
    private struct Fixture {
        let base: URL
        let repoPath: String
        let stubGhPath: String
        let witnessPath: String
        let sessionID = SessionID(uuid: UUID())

        init(origin: String) throws {
            let base = FileManager.default.temporaryDirectory
                .appending(path: "tkzmux-prlookup-\(UUID().uuidString)", directoryHint: .isDirectory)
            let repo = base.appending(path: "repo", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let repoPath = repo.path

            func git(_ args: String...) throws {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-C", repoPath] + args
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
            }
            try git("init", "-q", "-b", "main")
            try git("-c", "user.email=t@example.com", "-c", "user.name=t",
                     "commit", "-q", "--allow-empty", "-m", "init")
            try git("remote", "add", "origin", origin)

            let witness = base.appending(path: "witness.txt")
            let witnessPath = witness.path

            let stub = base.appending(path: "gh")
            let script = """
                #!/bin/sh
                echo "$@" >> "\(witnessPath)"
                echo '{"number":99,"state":"OPEN","url":"https://github.com/o/r/pull/99","isDraft":false,"reviewDecision":"APPROVED"}'
                exit 0
                """
            try script.write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

            self.base = base
            self.repoPath = repoPath
            self.witnessPath = witnessPath
            self.stubGhPath = stub.path
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: base)
        }

        func witnessLineCount() -> Int {
            guard let contents = try? String(contentsOfFile: witnessPath, encoding: .utf8) else {
                return 0
            }
            return contents.split(separator: "\n", omittingEmptySubsequences: true).count
        }

        /// Runs one `lookup` and blocks (with a short timeout) for its completion.
        func awaitLookup(_ lookup: PRLookup, force: Bool) throws -> PRInfo? {
            let sem = DispatchSemaphore(value: 0)
            let box = Mutex<PRInfo??>(nil)
            lookup.lookup(for: sessionID, directory: repoPath, branch: "main", force: force) { pr in
                box.withLock { $0 = .some(pr) }
                sem.signal()
            }
            guard sem.wait(timeout: .now() + 5) == .success else {
                Issue.record("lookup did not complete within timeout")
                return nil
            }
            return box.withLock { $0 } ?? nil
        }
    }
}
