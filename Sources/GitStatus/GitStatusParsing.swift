// GitStatusParsing — the text half of M4.1 (TKZ-26). Pure functions, no processes.
//
// design.md → *Git integration*: a refresh is two git calls, `status --porcelain=v2 --branch -z`
// and `diff HEAD --shortstat`. Everything that can go wrong in reading them is a parsing bug, so
// the parsing lives here as free functions over `String` and is tested against literal fixtures —
// `GitStatusService` only supplies the text.
//
// The `-z` trap, in one place so it is never re-learnt: in `--porcelain=v2 -z` **every** line is
// NUL-terminated (the `# branch.*` headers too), and a rename/copy record (`2 …`) is followed by a
// *second* NUL-separated field holding the original path. That trailing path is not a record; a
// naive "one field = one entry" loop counts every rename twice and then tries to parse a bare path
// as a status record. `parsePorcelainV2` consumes it explicitly.

import Foundation

/// One path out of a `git status` record: what changed, and how.
public struct ChangedPath: Hashable, Sendable {
    /// Repo-relative, exactly as git printed it.
    public let path: String
    /// The porcelain letter — `M`, `A`, `D`, `R`, `C`, `U`, or `?` for untracked.
    public let status: String

    public init(path: String, status: String) {
        self.path = path
        self.status = status
    }
}

/// What `git status --porcelain=v2 --branch -z` said.
///
/// `ahead`/`behind` are optional rather than `0`: a branch with no upstream has no `# branch.ab`
/// line at all, and "no upstream" is a different fact from "in sync with upstream". The service
/// flattens them to `0` when it builds `GitSummary`.
public struct PorcelainStatus: Hashable, Sendable {
    /// `# branch.head`, or `nil` in a detached HEAD.
    public var branch: String?
    /// `# branch.upstream`, e.g. `origin/main`.
    public var upstream: String?
    /// `# branch.ab +N`, or `nil` when there is no `# branch.ab` line.
    public var ahead: Int?
    /// `# branch.ab -M`, or `nil` when there is no `# branch.ab` line.
    public var behind: Int?
    /// `1`, `2` and `u` records: tracked files with changes, staged or not.
    public var changedFiles: Int
    /// `?` records.
    public var untrackedFiles: Int
    /// `# branch.oid`, or `nil` on an unborn branch.
    public var oid: String?
    /// `# branch.head (detached)`.
    public var isDetached: Bool
    /// `# branch.oid (initial)` — a repo with no commit yet. `branch` is still the head name.
    public var isUnborn: Bool
    /// The paths behind ``changedFiles`` and ``untrackedFiles``, in git's order, capped at
    /// ``GitStatusParsing/pathLimit``.
    ///
    /// These are parsed out of records that were already being walked, so they cost one array
    /// append each. They are deliberately **not** part of `GitSummary`: that struct drives the
    /// store and the "did anything change?" gate, and a path list churns on every keystroke of
    /// every file save, where the counts do not.
    public var paths: [ChangedPath]

    public init(
        branch: String? = nil,
        upstream: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        changedFiles: Int = 0,
        untrackedFiles: Int = 0,
        oid: String? = nil,
        isDetached: Bool = false,
        isUnborn: Bool = false,
        paths: [ChangedPath] = []
    ) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changedFiles = changedFiles
        self.untrackedFiles = untrackedFiles
        self.oid = oid
        self.isDetached = isDetached
        self.isUnborn = isUnborn
        self.paths = paths
    }
}

public enum GitStatusParsing {
    /// Parses `git status --porcelain=v2 --branch -z` output.
    ///
    /// Unknown header keys and `!` (ignored) records are skipped rather than treated as an error:
    /// git adds header lines over time and this must not start miscounting when it does.
    public static func parsePorcelainV2(_ text: String) -> PorcelainStatus {
        var result = PorcelainStatus()
        // `-z` terminates every line, so the split leaves an empty tail; `omittingEmptySubsequences`
        // drops it, and also any stray double NUL.
        let fields = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)

        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard let marker = field.first else { continue }

            if marker == "#" {
                parseHeader(field, into: &result)
                continue
            }
            // Records are `<marker> <space> …`; anything else is the second half of a rename we
            // already consumed, or output we do not understand. Skip it either way.
            guard field.count > 1, field[field.index(after: field.startIndex)] == " " else { continue }

            switch marker {
            case "1", "u":
                result.changedFiles += 1
                append(field, marker: marker, to: &result)
            case "2":
                result.changedFiles += 1
                append(field, marker: marker, to: &result)
                // THE `-z` TRAP: the original path of a rename/copy is its own NUL-separated field.
                index += 1
            case "?":
                result.untrackedFiles += 1
                append(field, marker: marker, to: &result)
            default:
                break  // `!` (ignored) and anything git adds later.
            }
        }
        return result
    }

    /// How many paths one repo contributes. A `git status` in a tree with a huge untracked build
    /// directory can print tens of thousands; the search list shows a handful.
    public static let pathLimit = 2_000

    /// Splits the path off a record. The path is the **last** field and may contain spaces, so the
    /// split is by a fixed count of leading fields, never by "the last token".
    ///
    ///     1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
    ///     2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path>
    ///     u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
    ///     ? <path>
    private static func append(_ field: String, marker: Character, to result: inout PorcelainStatus) {
        guard result.paths.count < pathLimit else { return }
        let leadingFields: Int
        switch marker {
        case "1": leadingFields = 8
        case "2": leadingFields = 9
        case "u": leadingFields = 10
        default: leadingFields = 1
        }
        let parts = field.split(
            separator: " ", maxSplits: leadingFields, omittingEmptySubsequences: false)
        guard parts.count == leadingFields + 1 else { return }
        let path = String(parts[leadingFields])
        guard !path.isEmpty else { return }
        result.paths.append(ChangedPath(path: path, status: status(marker: marker, fields: parts)))
    }

    /// `?` is untracked; otherwise the first of the two XY letters that is not `.` — which is the
    /// staged letter when there is one, and the worktree letter when there is not.
    private static func status(marker: Character, fields: [Substring]) -> String {
        guard marker != "?" else { return "?" }
        guard fields.count > 1 else { return "M" }
        let xy = fields[1]
        return xy.first { $0 != "." }.map(String.init) ?? "M"
    }

    private static func parseHeader(_ line: String, into result: inout PorcelainStatus) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "branch.oid":
            guard parts.count >= 3 else { return }
            if parts[2] == "(initial)" {
                result.isUnborn = true
            } else {
                result.oid = parts[2]
            }
        case "branch.head":
            guard parts.count >= 3 else { return }
            if parts[2] == "(detached)" {
                result.isDetached = true
                result.branch = nil
            } else {
                result.branch = parts[2]
            }
        case "branch.upstream":
            guard parts.count >= 3 else { return }
            result.upstream = parts[2]
        case "branch.ab":
            // `# branch.ab +1 -2`. Either sign may be absent from our reading if git changes the
            // format; a missing half stays `nil` rather than silently becoming 0.
            for token in parts.dropFirst(2) {
                if token.hasPrefix("+") {
                    result.ahead = Int(token.dropFirst())
                } else if token.hasPrefix("-") {
                    result.behind = Int(token.dropFirst())
                }
            }
        default:
            break
        }
    }

    /// Parses `git diff HEAD --shortstat`, e.g. ` 12 files changed, 142 insertions(+), 38 deletions(-)`.
    ///
    /// Any of the three clauses may be absent (a pure addition has no `deletions(-)` clause), and
    /// with a single file/line git writes the singular — `1 file changed, 1 insertion(+)` — so the
    /// match is on the *prefix* of the word, not the plural. Empty output (no diff) is all zeros.
    public static func parseShortstat(_ text: String) -> (files: Int, insertions: Int, deletions: Int) {
        var files = 0
        var insertions = 0
        var deletions = 0
        for clause in text.split(separator: ",") {
            let tokens = clause.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            guard tokens.count >= 2, let count = Int(tokens[0]) else { continue }
            let word = tokens[1]
            if word.hasPrefix("file") {
                files = count
            } else if word.hasPrefix("insertion") {
                insertions = count
            } else if word.hasPrefix("deletion") {
                deletions = count
            }
        }
        return (files, insertions, deletions)
    }
}
