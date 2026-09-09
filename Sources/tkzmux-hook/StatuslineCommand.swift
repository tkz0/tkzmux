// `tkzmux-hook statusline` — the `statusLine` command tkzmux installs into the user's
// `settings.json` (TKZ-32). `Darwin` only, like the rest of this target.
//
// Claude Code hands rate limits and context usage to the statusline command on stdin and nowhere
// else — they never reach disk on their own. This mode reads that payload once, mirrors the parts
// tkzmux renders into two sidecar files under the app's own Application Support directory, and then
// runs whatever statusline command the user had before, passing its output straight through.
//
// Measured 2026-09-09 on Claude Code 2.1.266: `statusLine.command` is run by **`/bin/sh -c`**
// (`$0` is literally `/bin/sh`), `--settings` does override a `statusLine` from settings.json, and
// `COLUMNS`/`LINES` arrive *empty* despite what the docs promise — which is why the child simply
// inherits our environment rather than trying to reconstruct one.
//
// The one hard invariant: the hand-off in `runStatusline`'s final step happens on every path. A
// crash, an unparseable payload, a full disk or an unwritable directory must never blank the user's
// statusline. Nothing here is inside `tkzmux-hook`'s "< 20 ms" hook budget — this mode parses JSON,
// occasionally reads the (large) identity file, and spawns a child.
import Darwin

/// Both sidecars skip a write when the file on disk is younger than this and unchanged.
private let writeThrottleSeconds = 30.0
private let labelMax = 32
private let planMax = 24
private let scopedLabelMax = 40
private let scopedMax = 8
/// The payload is a few KB; the pipe buffer is 64 KiB, so writing it all before `waitpid` cannot
/// deadlock. Anything larger is truncated rather than risking a block.
private let childStdinCap = 64 * 1024

// MARK: - Where things live

/// `~/Library/Application Support/tkzmux`.
///
/// Installed, this binary is `<support>/bin/tkzmux-hook`, so the directory is two levels up. The
/// `bin` check keeps a binary run straight out of `.build/debug` from resolving to `.build`.
/// `TKZMUX_SUPPORT_DIR` overrides both — the seam the tests drive this through.
func statuslineSupportDirectory() -> String {
    if let override = envString("TKZMUX_SUPPORT_DIR"), !override.isEmpty { return override }
    let argv0 = CommandLine.arguments.first ?? ""
    if argv0.hasPrefix("/") {
        let binDirectory = parentPath(argv0)
        if lastPathComponent(binDirectory) == "bin" {
            let support = parentPath(binDirectory)
            if !support.isEmpty { return support }
        }
    }
    return (envString("HOME") ?? "") + "/Library/Application Support/tkzmux"
}

/// `<support>/statusline` — the one directory tkzmux watches for these files.
func statuslineDirectory() -> String { statuslineSupportDirectory() + "/statusline" }

func statuslineUsagePath(account key: String) -> String {
    statuslineDirectory() + "/usage-" + key + ".json"
}

func statuslineContextPath(session id: String) -> String {
    statuslineDirectory() + "/context-" + id + ".json"
}

/// The statusline command that was configured before tkzmux wrapped it, saved verbatim at install
/// time. One file per account key: the install can run independently for two config directories.
func statuslinePreviousPath(account key: String) -> String {
    statuslineDirectory() + "/previous-" + key + ".json"
}

func parentPath(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    if slash == path.startIndex { return "/" }
    return String(path[path.startIndex..<slash])
}

func lastPathComponent(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
}

// MARK: - Account identity

/// The account key: the config dir's basename minus one leading dot, slugified so it is always a
/// safe filename. Must stay identical to `Account.key(forConfigDirectory:)` in TkzCore — the reader
/// keys on this filename and `AppState.usage` keys on `Account.key`, so a mismatch shows up as a
/// permanently empty badge rather than as an error.
func statuslineAccountKey(configDir: String) -> String {
    let base = lastPathComponent(configDir)
    let stripped = base.hasPrefix(".") ? String(base.dropFirst()) : base
    return slugify(stripped) ?? "default"
}

/// Lowercase, `[a-z0-9_-]` only, everything else folded to `-`, trimmed, capped.
func slugify(_ value: String, max: Int = 48) -> String? {
    var out = ""
    for character in value.lowercased() {
        if character == "_" || character == "-" {
            out.append(character)
        } else if character.isASCII, character.isLetter || character.isNumber {
            out.append(character)
        } else {
            out.append("-")
        }
        if out.count >= max { break }
    }
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? nil : out
}

struct StatuslineAccount {
    var key: String
    var label: String
    var plan: String?
    var uuid: String?
    var configDir: String

    var json: JSONValue {
        var pairs: [JSONPair] = [
            JSONPair(key: "key", value: .string(key)),
            JSONPair(key: "label", value: .string(label)),
        ]
        pairs.append(JSONPair(key: "plan", value: plan.map(JSONValue.string) ?? .null))
        pairs.append(JSONPair(key: "uuid", value: uuid.map(JSONValue.string) ?? .null))
        pairs.append(JSONPair(key: "config_dir", value: .string(configDir)))
        return .object(pairs)
    }
}

/// Resolves the account behind this statusline.
///
/// The key comes from `CLAUDE_CONFIG_DIR` and never from the identity file: that file is large
/// (272 KB on the author's machine) and rewritten constantly, so a torn read must not be able to
/// invent a second key and split one account's high-water state across two sidecars. A failed
/// identity read costs a pretty label and nothing else.
///
/// `previous` is the `account` block of the sidecar already on disk. When it carries a label for the
/// same config dir we reuse it and never open the identity file at all — this runs on every
/// statusline refresh.
func resolveStatuslineAccount(configDir: String, previous: JSONValue?) -> StatuslineAccount {
    let key = statuslineAccountKey(configDir: configDir)

    if let previous,
       previous.get("config_dir")?.asString == configDir,
       let label = previous.get("label")?.asString, !label.isEmpty {
        return StatuslineAccount(
            key: key,
            label: label,
            plan: previous.get("plan")?.asString,
            uuid: previous.get("uuid")?.asString,
            configDir: configDir)
    }

    // Order matters: a non-default profile keeps identity INSIDE the dir
    // (`~/.claude-work/.claude.json`), the default one keeps it as a SIBLING (`~/.claude.json`).
    for candidate in [configDir + "/.claude.json", configDir + ".json"] {
        guard let bytes = readFile(candidate) else { continue }
        var parser = JSONParser(bytes: bytes)
        guard let root = parser.parse(), let account = root.get("oauthAccount") else { continue }
        return StatuslineAccount(
            key: key,
            label: accountLabel(account, fallback: key),
            plan: accountPlan(account),
            uuid: account.get("accountUuid")?.asString,
            configDir: configDir)
    }

    return StatuslineAccount(key: key, label: key, plan: nil, uuid: nil, configDir: configDir)
}

private func accountLabel(_ account: JSONValue, fallback: String) -> String {
    let email = sanitizeText(account.get("emailAddress")?.asString, max: 64) ?? ""
    let organization = sanitizeText(account.get("organizationName")?.asString, max: labelMax) ?? ""
    // Personal Max/Pro orgs are auto-named "<email>'s Organization" — useless as a label.
    let autoNamed = !email.isEmpty && organization == "\(email)'s Organization"
    if !autoNamed, !organization.isEmpty { return organization }
    if let local = email.split(separator: "@").first, !local.isEmpty {
        return sanitizeText(String(local), max: labelMax) ?? fallback
    }
    return fallback
}

private func accountPlan(_ account: JSONValue) -> String? {
    let tiers = [
        "claude_max": "Max",
        "claude_pro": "Pro",
        "claude_team": "Team",
        "claude_enterprise": "Enterprise",
    ]
    let tier = account.get("organizationType")?.asString.flatMap { tiers[$0] }
    // Only an explicit max_Nx multiplier is surfaced; internal codenames never are.
    var multiplier: String?
    for key in ["userRateLimitTier", "organizationRateLimitTier"] {
        guard let raw = account.get(key)?.asString else { continue }
        if let found = maxMultiplier(in: raw) { multiplier = found; break }
    }
    let parts = [tier, multiplier.map { "\($0)x" }].compactMap { $0 }
    guard !parts.isEmpty else { return nil }
    return sanitizeText(parts.joined(separator: " "), max: planMax)
}

/// The digits of a `max_<N>x` tier string. Hand-rolled: `String.range(of:)` is Foundation.
private func maxMultiplier(in raw: String) -> String? {
    let characters = Array(raw)
    let needle = Array("max_")
    var index = 0
    while index + needle.count <= characters.count {
        defer { index += 1 }
        guard Array(characters[index..<index + needle.count]) == needle else { continue }
        var cursor = index + needle.count
        var digits = ""
        while cursor < characters.count, characters[cursor].isASCII, characters[cursor].isNumber {
            digits.append(characters[cursor])
            cursor += 1
        }
        if !digits.isEmpty, cursor < characters.count, characters[cursor] == "x" { return digits }
    }
    return nil
}

/// Strips control characters, collapses whitespace, trims and caps. These strings come out of a file
/// and end up in the UI.
func sanitizeText(_ value: String?, max: Int) -> String? {
    guard let value else { return nil }
    var out = ""
    var lastWasSpace = false
    for scalar in value.unicodeScalars {
        if scalar.value < 0x20 || scalar.value == 0x7F || scalar == " " || scalar == "\u{00A0}" {
            if !lastWasSpace { out.append(" ") }
            lastWasSpace = true
        } else {
            out.unicodeScalars.append(scalar)
            lastWasSpace = false
        }
    }
    while out.hasPrefix(" ") { out.removeFirst() }
    while out.hasSuffix(" ") { out.removeLast() }
    if out.utf16.count > max {
        let end = out.utf16.index(out.utf16.startIndex, offsetBy: max)
        out = String(String.UnicodeScalarView(out.utf16[out.utf16.startIndex..<end].compactMap {
            Unicode.Scalar($0)
        }))
    }
    return out.isEmpty ? nil : out
}

// MARK: - Payload → sidecars

/// `used_percentage` clamped to 0…100 and rounded, as the reader expects.
func percentValue(_ value: JSONValue?) -> Int? {
    guard let raw = value?.asNumber, raw.isFinite else { return nil }
    return Int(Swift.min(100, Swift.max(0, raw)).rounded(.toNearestOrAwayFromZero))
}

/// `rate_limits.*.resets_at` is unix epoch **seconds**; the sidecar contract is ISO-8601, because
/// that is what `UsageWindow` decodes. Values past 1e12 are treated as milliseconds.
func isoString(fromEpoch value: JSONValue?) -> String? {
    guard let raw = value?.asNumber, raw.isFinite, raw > 0 else {
        // Some producers already write ISO; pass a plausible string through untouched.
        return value?.asString.flatMap { $0.isEmpty ? nil : $0 }
    }
    let seconds = raw > 1e12 ? raw / 1000 : raw
    return isoString(seconds: seconds)
}

func isoString(seconds: Double) -> String? {
    let whole = seconds.rounded(.down)
    var millis = Int(((seconds - whole) * 1000).rounded())
    var time = time_t(whole)
    if millis >= 1000 { millis = 0; time += 1 }
    var parts = tm()
    guard gmtime_r(&time, &parts) != nil else { return nil }
    var buffer = [CChar](repeating: 0, count: 32)
    let written = strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%S", &parts)
    guard written > 0 else { return nil }
    var fraction = String(millis)
    while fraction.count < 3 { fraction = "0" + fraction }
    let stamp = String(decoding: buffer[0..<written].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return stamp + "." + fraction + "Z"
}

/// `updated_at` for a snapshot written right now.
func nowISOString() -> String {
    var tv = timeval()
    gettimeofday(&tv, nil)
    return isoString(seconds: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
        ?? "1970-01-01T00:00:00.000Z"
}

private func windowValue(_ raw: JSONValue?) -> JSONValue? {
    guard let raw, let used = percentValue(raw.get("used_percentage")) else { return nil }
    var pairs = [JSONPair(key: "used_percentage", value: .number(String(used)))]
    pairs.append(JSONPair(
        key: "resets_at",
        value: isoString(fromEpoch: raw.get("resets_at")).map(JSONValue.string) ?? .null))
    return .object(pairs)
}

private func scopedValues(_ raw: JSONValue?) -> [JSONValue] {
    guard let entries = raw?.asArray else { return [] }
    var out: [JSONValue] = []
    for entry in entries.prefix(scopedMax) {
        guard let name = entry.get("display_name")?.asString else { continue }
        let label = sanitizeText(name, max: scopedLabelMax) ?? ""
        guard !label.isEmpty, let used = percentValue(entry.get("utilization")) else { continue }
        out.append(.object([
            JSONPair(key: "display_name", value: .string(label)),
            JSONPair(key: "utilization", value: .number(String(used))),
            JSONPair(
                key: "resets_at",
                value: isoString(fromEpoch: entry.get("resets_at")).map(JSONValue.string) ?? .null),
        ]))
    }
    return out
}

/// The `usage-<key>.json` document, or nil when the payload carries no quota at all (`rate_limits`
/// is absent for non-subscribers and until the first API response of a session).
///
/// Windows the payload does not carry are **omitted, never nulled**: the reader holds its previous
/// value for a missing field, and a null would make the badge flicker to "—".
func buildUsageSnapshot(_ root: JSONValue, account: StatuslineAccount, updatedAt: String) -> JSONValue? {
    guard let limits = root.get("rate_limits") else { return nil }
    var pairs: [JSONPair] = [
        JSONPair(key: "updated_at", value: .string(updatedAt)),
        JSONPair(key: "account", value: account.json),
    ]
    var carriedSomething = false
    if let window = windowValue(limits.get("five_hour")) {
        pairs.append(JSONPair(key: "five_hour", value: window))
        carriedSomething = true
    }
    if let window = windowValue(limits.get("seven_day")) {
        pairs.append(JSONPair(key: "seven_day", value: window))
        carriedSomething = true
    }
    let scoped = scopedValues(limits.get("model_scoped"))
    if !scoped.isEmpty {
        pairs.append(JSONPair(key: "model_scoped", value: .array(scoped)))
        carriedSomething = true
    }
    return carriedSomething ? .object(pairs) : nil
}

/// A session id is about to become part of a filename, so it is validated rather than escaped.
func isSafeSessionID(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    for character in value {
        guard character.isASCII else { return false }
        guard character.isLetter || character.isNumber || character == "-" || character == "_" else {
            return false
        }
    }
    return true
}

/// The `context-<session_id>.json` document.
///
/// Three shapes differ from `SessionSidecar`'s and are translated here rather than in the reader:
/// `workspace.repo` is an object on the wire but a string in the model; `worktree` likewise; and
/// `pr` arrives with Claude Code's `review_state` vocabulary while `PRInfo` is `gh`-shaped.
func buildContextSidecar(_ root: JSONValue, accountKey: String, updatedAt: String) -> (id: String, value: JSONValue)? {
    guard let sessionID = root.get("session_id")?.asString, isSafeSessionID(sessionID) else {
        return nil
    }
    var pairs: [JSONPair] = [
        JSONPair(key: "updated_at", value: .string(updatedAt)),
        JSONPair(key: "session_id", value: .string(sessionID)),
        JSONPair(key: "account_key", value: .string(accountKey)),
    ]

    if let context = root.get("context_window")?.get("used_percentage"), let used = percentValue(context) {
        pairs.append(JSONPair(key: "context_used_percentage", value: .number(String(used))))
    }

    if let model = root.get("model") {
        var modelPairs: [JSONPair] = []
        if let id = model.get("id")?.asString { modelPairs.append(JSONPair(key: "id", value: .string(id))) }
        if let name = model.get("display_name")?.asString {
            modelPairs.append(JSONPair(key: "display_name", value: .string(name)))
        }
        if !modelPairs.isEmpty { pairs.append(JSONPair(key: "model", value: .object(modelPairs))) }
    }

    if let name = sanitizeText(root.get("session_name")?.asString, max: 120) {
        pairs.append(JSONPair(key: "session_name", value: .string(name)))
    }

    if let workspace = root.get("workspace") {
        var workspacePairs: [JSONPair] = []
        if let worktree = workspace.get("git_worktree")?.asString {
            workspacePairs.append(JSONPair(key: "git_worktree", value: .string(worktree)))
        }
        if let projectDir = workspace.get("project_dir")?.asString {
            workspacePairs.append(JSONPair(key: "project_dir", value: .string(projectDir)))
        }
        // `repo` is `{host, owner, name}` on the wire, a single string in the model.
        if let repo = workspace.get("repo"), let name = repo.get("name")?.asString {
            let owner = repo.get("owner")?.asString
            let text = owner.map { "\($0)/\(name)" } ?? name
            workspacePairs.append(JSONPair(key: "repo", value: .string(text)))
        }
        if !workspacePairs.isEmpty {
            pairs.append(JSONPair(key: "workspace", value: .object(workspacePairs)))
        }
    }

    if let worktree = root.get("worktree")?.get("name")?.asString, !worktree.isEmpty {
        pairs.append(JSONPair(key: "worktree", value: .string(worktree)))
    }

    if let pr = root.get("pr"), let number = pr.get("number")?.asNumber, number.isFinite {
        var prPairs: [JSONPair] = [JSONPair(key: "number", value: .number(String(Int(number))))]
        if let url = pr.get("url")?.asString { prPairs.append(JSONPair(key: "url", value: .string(url))) }
        // The payload only ever describes an open PR — it disappears once one merges or closes.
        prPairs.append(JSONPair(key: "state", value: .string("OPEN")))
        let review = pr.get("review_state")?.asString
        prPairs.append(JSONPair(key: "isDraft", value: .bool(review == "draft")))
        let decision: String?
        switch review {
        case "approved": decision = "APPROVED"
        case "changes_requested": decision = "CHANGES_REQUESTED"
        case "pending": decision = "REVIEW_REQUIRED"
        default: decision = nil
        }
        if let decision { prPairs.append(JSONPair(key: "reviewDecision", value: .string(decision))) }
        pairs.append(JSONPair(key: "pr", value: .object(prPairs)))
    }

    if let cost = root.get("cost")?.get("total_cost_usd"), case .number(let raw) = cost {
        pairs.append(JSONPair(key: "cost", value: .number(raw)))
    }

    return (sessionID, .object(pairs))
}

// MARK: - Files

/// Write-to-temp + rename, so a reader can never catch a half-written file. The `.tmp` name
/// deliberately does not match the reader's `usage-*.json` / `context-*.json` globs.
@discardableResult
func writeFileAtomically(_ path: String, _ contents: String) -> Bool {
    let temporary = path + "." + String(getpid()) + ".tmp"
    unlink(temporary)
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { return false }
    let bytes = Array(contents.utf8)
    var written = 0
    while written < bytes.count {
        let n = bytes.withUnsafeBytes { buffer -> Int in
            write(fd, buffer.baseAddress!.advanced(by: written), bytes.count - written)
        }
        if n <= 0 { close(fd); unlink(temporary); return false }
        written += n
    }
    close(fd)
    guard rename(temporary, path) == 0 else { unlink(temporary); return false }
    return true
}

/// A copy of `value` without the given top-level keys, for change comparison.
private func withoutKeys(_ value: JSONValue, _ keys: [String]) -> JSONValue {
    guard let pairs = value.asObject else { return value }
    return .object(pairs.filter { !keys.contains($0.key) })
}

/// Skip the write when the file is still recent and nothing that matters changed. `updated_at` is
/// excluded because it always differs, and `account` because an org rename should not force a write.
private func shouldWrite(_ path: String, _ candidate: JSONValue) -> Bool {
    var info = stat()
    guard stat(path, &info) == 0 else { return true }
    var tv = timeval()
    gettimeofday(&tv, nil)
    let age = Double(tv.tv_sec) - Double(info.st_mtimespec.tv_sec)
    if age < 0 || age > writeThrottleSeconds { return true }
    guard let bytes = readFile(path) else { return true }
    var parser = JSONParser(bytes: bytes)
    guard let previous = parser.parse() else { return true }
    let ignored = ["updated_at", "account"]
    return jsonSerialize(withoutKeys(previous, ignored)) != jsonSerialize(withoutKeys(candidate, ignored))
}

/// `mkdir -p` for the two levels we own. Failures are ignored: the write that follows reports them.
private func ensureStatuslineDirectory() {
    mkdir(statuslineSupportDirectory(), 0o700)
    mkdir(statuslineDirectory(), 0o700)
}

private func writeSidecar(_ path: String, _ value: JSONValue) {
    guard shouldWrite(path, value) else { return }
    ensureStatuslineDirectory()
    if !writeFileAtomically(path, jsonSerialize(value) + "\n") {
        debugLog("statusline: could not write \(path)")
    }
}

// MARK: - Hand-off

/// The command the user's statusline ran before tkzmux wrapped it, or nil when there was none.
/// A `previous-<key>.json` recording `{"statusLine": null}` means "there was nothing here".
func previousStatuslineCommand(account key: String) -> String? {
    guard let bytes = readFile(statuslinePreviousPath(account: key)) else { return nil }
    var parser = JSONParser(bytes: bytes)
    guard let root = parser.parse() else { return nil }
    guard let command = root.get("statusLine")?.get("command")?.asString, !command.isEmpty else {
        return nil
    }
    return command
}

/// Runs the wrapped command under `/bin/sh -c` — measured to be exactly how Claude Code runs a
/// `statusLine.command` itself — with the original stdin bytes and our environment, and exits with
/// its status. stdout and stderr are inherited, so its output reaches Claude Code byte for byte.
private func handOff(command: String, stdinBytes: [UInt8]) -> Never {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { exit(0) }
    let readEnd = fds[0]
    let writeEnd = fds[1]

    var actions = posix_spawn_file_actions_t(bitPattern: 0)
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO)
    posix_spawn_file_actions_addclose(&actions, readEnd)
    posix_spawn_file_actions_addclose(&actions, writeEnd)

    var childPid: pid_t = 0
    let spawned: Int32 = "/bin/sh".withCString { shell in
        "-c".withCString { flag in
            command.withCString { script in
                var argv: [UnsafeMutablePointer<CChar>?] = [
                    UnsafeMutablePointer(mutating: shell),
                    UnsafeMutablePointer(mutating: flag),
                    UnsafeMutablePointer(mutating: script),
                    nil,
                ]
                return posix_spawn(&childPid, shell, &actions, nil, &argv, environ)
            }
        }
    }
    posix_spawn_file_actions_destroy(&actions)
    close(readEnd)

    guard spawned == 0 else {
        debugLog("statusline: could not spawn the previous command (errno \(spawned))")
        close(writeEnd)
        exit(0)
    }

    let payload = stdinBytes.count > childStdinCap ? Array(stdinBytes[0..<childStdinCap]) : stdinBytes
    var written = 0
    while written < payload.count {
        let n = payload.withUnsafeBytes { buffer -> Int in
            write(writeEnd, buffer.baseAddress!.advanced(by: written), payload.count - written)
        }
        if n <= 0 { break }
        written += n
    }
    close(writeEnd)

    var status: Int32 = 0
    while waitpid(childPid, &status, 0) < 0 && errno == EINTR {}
    // WIFEXITED / WEXITSTATUS are C macros, unavailable from Swift.
    if status & 0x7F == 0 {
        exit((status >> 8) & 0xFF)
    }
    exit(0)
}

/// What the statusline shows when tkzmux is the only thing configured. Deliberately plain — a user
/// who wants more installs their own command and tkzmux wraps it.
private func fallbackLine(_ root: JSONValue?) -> String {
    var parts: [String] = []
    if let name = root?.get("model")?.get("display_name")?.asString, !name.isEmpty {
        parts.append(name)
    }
    if let cwd = root?.get("cwd")?.asString, !cwd.isEmpty {
        parts.append(lastPathComponent(cwd))
    }
    if let used = percentValue(root?.get("context_window")?.get("used_percentage")) {
        parts.append("\(used)%")
    }
    return parts.joined(separator: " · ")
}

private func writeStdout(_ text: String) {
    let bytes = Array((text + "\n").utf8)
    bytes.withUnsafeBytes { buffer in
        _ = write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
    }
}

// MARK: - Entry point

/// Never returns: every path either execs into the previous command's exit status or exits 0.
func runStatusline() -> Never {
    let (stdinBytes, hitCap) = readStdin()
    let configDir = claudeConfigDirectory()
    let key = statuslineAccountKey(configDir: configDir)

    var root: JSONValue?
    if !hitCap {
        var parser = JSONParser(bytes: stdinBytes)
        root = parser.parse()
    }

    if let root {
        let updatedAt = nowISOString()
        let usagePath = statuslineUsagePath(account: key)

        var previousAccount: JSONValue?
        if let bytes = readFile(usagePath) {
            var parser = JSONParser(bytes: bytes)
            previousAccount = parser.parse()?.get("account")
        }
        let account = resolveStatuslineAccount(configDir: configDir, previous: previousAccount)

        if let snapshot = buildUsageSnapshot(root, account: account, updatedAt: updatedAt) {
            writeSidecar(usagePath, snapshot)
        }
        if let context = buildContextSidecar(root, accountKey: key, updatedAt: updatedAt) {
            writeSidecar(statuslineContextPath(session: context.id), context.value)
        }
    } else {
        debugLog("statusline: unparseable payload; handing off anyway")
    }

    if let command = previousStatuslineCommand(account: key) {
        handOff(command: command, stdinBytes: stdinBytes)
    }
    writeStdout(fallbackLine(root))
    exit(0)
}
