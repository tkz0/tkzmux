// PRLookup — `gh pr view`, gated so it never runs against a non-GitHub origin (M4.2 / TKZ-27).
//
// design.md → *Git integration*: git calls are background calls that must never contend with the
// user's own git or hang on a prompt (see GitProcess). PRLookup adds one more constraint on top:
// the user's main work repo has an Azure DevOps origin, and `gh` must never be invoked there — not
// once, not to fail. The origin's host is checked and cached *per directory* before `gh` is ever
// considered, and a non-GitHub verdict is permanent until `forget` — so N sessions open in the same
// non-GitHub repo cost exactly one `git remote get-url origin`, not one per session.
//
// State lives in a `Mutex<Storage>` (not `@unchecked Sendable`, per house rule — see
// `ClaudeSessionWatcher`), but all the blocking work (the `git` and `gh` subprocesses) runs hopped
// onto a single private serial queue, so lookups for the same session/repo cannot race each other
// and `gh` is never invoked concurrently with itself.

import Foundation
import Synchronization
import TkzCore

public final class PRLookup: Sendable {
    private let ghPathOverride: String?
    private let gitPath: String
    private let refreshInterval: TimeInterval
    private let failureCacheInterval: TimeInterval
    private let timeout: Double

    private let queue = DispatchQueue(label: "se.tkz.tkzmux.PRLookup")
    private let storage: Mutex<Storage>

    private struct SessionEntry {
        var pr: PRInfo?
        var directory: String
        var branch: String?
        var lastAttemptAt: Date?
        var lastFailureAt: Date?
    }

    private struct Storage {
        var resolvedGhPath: String?? = nil  // outer optional = "not resolved yet", inner = the result.
        var sessions: [SessionID: SessionEntry] = [:]
        var isGitHubByDirectory: [String: Bool] = [:]
    }

    public init(
        ghPath: String? = nil,
        gitPath: String = GitProcess.gitPath,
        refreshInterval: TimeInterval = 300,
        failureCacheInterval: TimeInterval = 600,
        timeout: Double = 5
    ) {
        self.ghPathOverride = ghPath
        self.gitPath = gitPath
        self.refreshInterval = refreshInterval
        self.failureCacheInterval = failureCacheInterval
        self.timeout = timeout
        var initialStorage = Storage()
        if let ghPath {
            initialStorage.resolvedGhPath = .some(ghPath)
        }
        self.storage = Mutex(initialStorage)
    }

    /// Ask for the PR of `branch` in `directory`. See the type doc for throttling / gating rules.
    public func lookup(
        for key: SessionID,
        directory: String,
        branch: String?,
        force: Bool = false,
        completion: @escaping @Sendable (PRInfo?) -> Void
    ) {
        queue.async { [self] in
            let previous = storage.withLock { $0.sessions[key] }
            let now = Date()

            // Uniform "does the app need to hear about this?" rule, used at every exit below: a
            // forced call always reports; otherwise only a change from what's cached is worth a
            // callback (the app re-renders on every one it gets).
            func report(_ pr: PRInfo?) {
                if force || pr != previous?.pr {
                    completion(pr)
                }
            }

            guard let branch, !branch.isEmpty else {
                // No branch: no PR, definitionally.
                storage.withLock { s in
                    s.sessions[key] = SessionEntry(
                        pr: nil, directory: directory, branch: branch,
                        lastAttemptAt: previous?.lastAttemptAt, lastFailureAt: previous?.lastFailureAt)
                }
                report(nil)
                return
            }

            if !force, let previous {
                // A cached failure suppresses attempts regardless of branch/directory changes — a
                // launch failure or timeout isn't branch-specific, so it's checked first.
                let failureFresh =
                    previous.lastFailureAt.map { now.timeIntervalSince($0) < failureCacheInterval }
                    ?? false
                let unchanged = previous.directory == directory && previous.branch == branch
                let fresh =
                    previous.lastAttemptAt.map { now.timeIntervalSince($0) < refreshInterval }
                    ?? false
                if failureFresh || (unchanged && fresh) {
                    return  // cache is authoritative; nothing changed, nothing to report.
                }
            }

            guard isGitHubOrigin(directory: directory) else {
                // Permanent (per directory, until `forget`) — never reaches `gh` for this directory.
                storage.withLock { s in
                    s.sessions[key] = SessionEntry(
                        pr: nil, directory: directory, branch: branch, lastAttemptAt: now,
                        lastFailureAt: previous?.lastFailureAt)
                }
                report(nil)
                return
            }

            guard let ghPath = resolvedGhPath() else {
                // No `gh` on disk: yields `nil`, same treatment as "not applicable".
                storage.withLock { s in
                    s.sessions[key] = SessionEntry(
                        pr: nil, directory: directory, branch: branch, lastAttemptAt: now,
                        lastFailureAt: previous?.lastFailureAt)
                }
                report(nil)
                return
            }

            switch runGh(ghPath: ghPath, directory: directory, branch: branch) {
            case .success(let pr):
                storage.withLock { s in
                    s.sessions[key] = SessionEntry(
                        pr: pr, directory: directory, branch: branch, lastAttemptAt: now,
                        lastFailureAt: nil)
                }
                report(pr)
            case .failure:
                // Launch failure / timeout: cache the failure, but keep whatever PR was last known
                // — a transient 5s timeout shouldn't make the badge vanish for failureCacheInterval.
                let keptPR = previous?.pr
                storage.withLock { s in
                    s.sessions[key] = SessionEntry(
                        pr: keptPR, directory: directory, branch: branch, lastAttemptAt: now,
                        lastFailureAt: now)
                }
                if force { completion(keptPR) }
            }
        }
    }

    /// Drop everything cached for a session (it was removed, or retargeted to another repo). Also
    /// drops that session's directory's GitHub-origin verdict, so a session retargeted onto a fresh
    /// `directory` right after `forget` re-checks the origin instead of racing a stale verdict left
    /// behind by whatever was still in flight for the old one.
    public func forget(_ key: SessionID) {
        storage.withLock { s in
            guard let entry = s.sessions.removeValue(forKey: key) else { return }
            s.isGitHubByDirectory.removeValue(forKey: entry.directory)
        }
    }

    /// Whatever is currently cached for a session, without running anything.
    public func cached(for key: SessionID) -> PRInfo? {
        storage.withLock { $0.sessions[key]?.pr }
    }

    // MARK: - Internal helpers (run on `queue`)

    private enum GhResult {
        case success(PRInfo?)
        case failure
    }

    private func runGh(ghPath: String, directory: String, branch: String) -> GhResult {
        do {
            let output = try GitProcess.run(
                ghPath,
                ["pr", "view", branch, "--json", "number,state,url,isDraft,reviewDecision"],
                currentDirectory: directory,
                timeout: timeout)
            if output.succeeded {
                return .success(Self.parsePR(output.standardOutput))
            }
            // Non-zero: "no PR for this branch" is the overwhelmingly common case and is not a
            // failure — it must not trip the failure cache. There is no reliable way to distinguish
            // "no PR" from other `gh` errors (auth, rate limit, …) from the exit code alone, and the
            // ticket is explicit that a repo whose branches usually have no PR must not be hammered
            // — which `.success(nil)` already achieves via the normal refreshInterval throttle.
            return .success(Optional<PRInfo>.none)
        } catch {
            return .failure
        }
    }

    private func isGitHubOrigin(directory: String) -> Bool {
        if let cached = storage.withLock({ $0.isGitHubByDirectory[directory] }) {
            return cached
        }
        let verdict: Bool
        if let output = try? GitProcess.git(["remote", "get-url", "origin"], in: directory,
                                             gitPath: gitPath, timeout: timeout),
            output.succeeded
        {
            verdict = Self.isGitHubOrigin(output.trimmedOutput)
        } else {
            verdict = false
        }
        storage.withLock { $0.isGitHubByDirectory[directory] = verdict }
        return verdict
    }

    private func resolvedGhPath() -> String? {
        storage.withLock { s in
            if let resolved = s.resolvedGhPath { return resolved }
            let path = Self.resolveGhPath()
            s.resolvedGhPath = .some(path)
            return path
        }
    }

    // MARK: - Pure, directly testable halves

    /// `true` only for a github.com remote — https, ssh (`git@github.com:o/r.git`), `ssh://`,
    /// `git://` and `github.com:` forms. False for Azure DevOps, GitLab, Bitbucket, a path, "".
    ///
    /// GitHub Enterprise (a github.* host that is not `github.com`, e.g. `github.company.com`) is
    /// deliberately `false` here: the ticket scopes this to github.com only, and `gh` itself needs
    /// separate host configuration (`gh auth login --hostname`) to talk to an Enterprise instance,
    /// so treating it as GitHub would invoke `gh` somewhere it is not set up to work.
    public static func isGitHubOrigin(_ remoteURL: String) -> Bool {
        let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return false }

        // scp-like form: git@github.com:owner/repo.git, or bare github.com:owner/repo.
        if let colonRange = url.range(of: ":"), !url.contains("://") {
            let hostPart = url[..<colonRange.lowerBound]
            let host = hostPart.contains("@") ? hostPart.split(separator: "@").last.map(String.init) ?? "" : String(hostPart)
            return host.lowercased() == "github.com"
        }

        guard let components = URLComponents(string: url), let host = components.host else {
            return false
        }
        return host.lowercased() == "github.com"
    }

    /// Parses `gh pr view --json number,state,url,isDraft,reviewDecision` output. Empty output,
    /// "no pull requests found" and malformed JSON all yield `nil`, never a throw.
    public static func parsePR(_ output: String) -> PRInfo? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let number = json["number"] as? Int
        else {
            return nil
        }
        return PRInfo(
            number: number,
            url: json["url"] as? String,
            state: json["state"] as? String,
            isDraft: json["isDraft"] as? Bool ?? false,
            reviewDecision: json["reviewDecision"] as? String)
    }

    /// Where `gh` is, searching `PATH` then `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`.
    public static func resolveGhPath(fileManager: FileManager = .default) -> String? {
        var candidates: [String] = []
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: pathVar.split(separator: ":").map(String.init))
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])

        for dir in candidates {
            let candidate = (dir as NSString).appendingPathComponent("gh")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                fileManager.isExecutableFile(atPath: candidate)
            {
                return candidate
            }
        }
        return nil
    }
}
