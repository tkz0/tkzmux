// CodexHooksInstaller — the second place tkzmux ever edits a file the user owns (TKZ-86 part 3).
// The first is `StatuslineInstaller`; this type follows the same protocol and the same caution:
// detect before touching anything, plan the exact before/after so a consent sheet can show it,
// write a `previous-<accountKey>.json` record before the edit so `uninstall` can put back exactly
// what was there, and never trade a record naming a real previous value down to one naming an
// absence.
//
// Why this file has to exist at all — measured against a real logged-in codex-cli 0.155.0 during
// the TKZ-86 spike, not assumed from documentation:
//
//     `codex exec -c 'hooks.Stop=[…]' 'Reply with pong'`                        → no hooks fired
//     the same run, plus `--dangerously-bypass-hook-trust`                     → hooks fired
//
// A hook injected on the command line parses but does not run. Codex keys hook trust by source,
// and a `-c` override has no persisted trust entry, so it is skipped silently — nothing on stdout,
// nothing on stderr, the turn otherwise completing normally. That rules out doing for Codex what
// the other supported agent's shim does per invocation, and it is why this installer, and the
// consent it requires, exist.
//
// The same trust rule applies to whatever this installer writes: a hook it adds will not run until
// the user reviews and trusts it inside Codex's own hook-review command. `--dangerously-bypass-hook-trust`
// is not a workaround for that — it bypasses trust for every hook of the invocation, including the
// user's own and any plugin's — so nothing here ever references it, and `detect` exists in part to
// make the "not yet trusted" state visible rather than hidden.
//
// Schema: `hooks.json` is not created by Codex itself — the file is created by whoever adds
// hooks — so there was nothing to capture from a plain run, and an earlier draft of this file
// guessed a flat shape (`{"Stop": [{"type": "command", "command": …}]}`) that turned out wrong.
// Three shapes were written to `$CODEX_HOME/hooks.json` and driven against a real logged-in
// codex-cli 0.155.0, each with `--dangerously-bypass-hook-trust` so trust could not mask the
// result:
//
//     {"Stop":[{"type":"command","command":"…"}]}                              → did not fire
//     {"Stop":[{"hooks":[{"type":"command","command":"…"}]}]}                  → did not fire
//     {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"…"}]}]}}        → fired
//
// Only the third — a top-level `hooks` key, then the event name, then an array of *groups*, each
// carrying its own `hooks` array of `{"type": "command", "command": …}` entries — actually runs.
// The first two are not rejected and produce no error; Codex simply ignores them, so a flat
// `hooks.json` is installed, consented to, and permanently silent, which is indistinguishable from
// the trust problem `detect` otherwise reports. The verified shape is captured verbatim at
// this module's own `Fixtures/codex/hooks-json-verified.json` and this installer's tests
// build on it rather than on a hand-written literal. It mirrors `config.toml` exactly:
// `[[hooks.Stop]]` is a group and `[[hooks.Stop.hooks]]` is an entry within that group.
//
// The same session measured two more things `detect` and `install` depend on: a `Stop` hook in
// `hooks.json` and one in `config.toml` both fired — Codex merges the two sources rather than one
// winning, which is why `configTomlHasHooks` has to be surfaced rather than treated as irrelevant
// once `hooks.json` carries ours — and two entries inside one group's own `hooks` array both fired,
// in order, which is what licenses this installer to append rather than ever needing to replace.
//
// `[features] hooks = true` in `config.toml`: the ticket that started this file said to require it.
// That turned out to be obsolete — `codex features list` on 0.155.0 reports `hooks stable true`, on
// by default — so nothing here checks for it, and nothing should ever be written that tells a user
// to set it.
import Foundation

/// What is producing this account's Codex hooks right now, from `hooks.json` alone.
///
/// Codex also reads hooks out of `config.toml`, which this installer only ever text-scans — see
/// `CodexHooksDetection.configTomlHasHooks` — so `.none` here is never proof the user has no hooks
/// at all, only that this file does not carry any of ours or anyone else's.
public enum CodexHooksProducer: Equatable, Sendable {
    /// No `hooks.json`, or none of the events this installer manages holds any entry at all — in
    /// either case meaning no group under that event's array carries an entry in its own `hooks`
    /// array.
    case none
    /// Every event this installer manages already carries exactly the command this build would
    /// write, somewhere inside some group's own `hooks` array. Nothing to offer.
    case tkzmux
    /// A `tkzmux-hook` command is present for at least one managed event, but it runs a binary at
    /// a different support-directory path than this build's own — an older install, a `.build`
    /// binary, a second checkout. The paths reported are exactly what a repair would repoint.
    case stale(paths: Set<String>)
    /// At least one managed event already carries an entry that is not a `tkzmux-hook` command at
    /// all — the user's own hook, or another tool's. `install` appends a new group alongside it;
    /// existing groups are never replaced or removed.
    case other
}

/// Whether tkzmux's hooks appear to be trusted, per Codex's own hook-trust ledger.
///
/// This is deliberately weak. Codex keys trust by a hash over a normalised hook identity computed
/// inside the binary, and this installer has no way to reproduce that hash — writing a guessed one
/// would look like tampering, which is why nothing here ever writes to the ledger. What can be
/// checked safely is whether the ledger's own text mentions the path to this account's
/// `hooks.json` at all, which is evidence one of its entries has been reviewed, never proof that
/// *these* entries have, and never something `install` or `uninstall` act on.
public enum CodexHooksTrustState: Equatable, Sendable {
    /// The ledger file does not exist, is empty, or cannot be read as text.
    case unknown
    /// The ledger's text mentions this account's `hooks.json` path.
    case mentionsOurConfig
    /// The ledger exists and was readable, but does not mention this account's `hooks.json` path.
    case doesNotMentionOurConfig
}

/// The full picture `detect` can offer for one account, without writing anything.
public struct CodexHooksDetection: Equatable, Sendable {
    public var producer: CodexHooksProducer
    /// True when `config.toml` text-scans positive for a `[[hooks.<Event>]]` array-of-tables
    /// header. Codex merges both files, so a caller must surface this alongside `producer` rather
    /// than let a `.none` producer imply the user has no hooks configured anywhere.
    public var configTomlHasHooks: Bool
    public var trust: CodexHooksTrustState

    public init(
        producer: CodexHooksProducer, configTomlHasHooks: Bool, trust: CodexHooksTrustState
    ) {
        self.producer = producer
        self.configTomlHasHooks = configTomlHasHooks
        self.trust = trust
    }
}

/// The exact before/after a consent sheet shows. Nothing has been written when this is built.
public struct CodexHooksInstallPlan: Equatable, Sendable {
    public var hooksPath: String
    public var accountKey: String
    /// `hooks.json`'s current text, verbatim; `nil` when the file does not exist yet.
    public var before: String?
    /// What `hooks.json` will become.
    public var after: String
    public var detection: CodexHooksDetection

    public init(
        hooksPath: String, accountKey: String, before: String?, after: String,
        detection: CodexHooksDetection
    ) {
        self.hooksPath = hooksPath
        self.accountKey = accountKey
        self.before = before
        self.after = after
        self.detection = detection
    }
}

public enum CodexHooksInstallerError: Error, Equatable, Sendable {
    /// `hooks.json` exists but is not JSON this installer can safely merge into — a syntax error,
    /// a non-object root, or a managed event whose value is not an array. Refusing beats guessing:
    /// this is the user's file, and losing it is worse than doing nothing.
    case hooksFileUnusable(path: String)
    /// Asked to uninstall when `hooks.json` no longer carries this build's command for every
    /// managed event — something changed it since, and clobbering that change would be worse than
    /// doing nothing.
    case notInstalled
    /// Asked to uninstall with no record of what came before. A missing companion file is *lost
    /// state*, not evidence there was nothing here, so the file is left alone.
    case previousMissing(path: String)
}

/// Installs and removes tkzmux's hooks in one Codex account's `hooks.json`, and reports what is
/// there without ever touching `config.toml` or the hook-trust ledger.
public struct CodexHooksInstaller: HookConfigInstaller, Sendable {
    /// The eight events this build installs a hook for, in the order they are written. Anything
    /// else already in the file — another event name, an unrelated top-level key — is preserved
    /// untouched and unexamined.
    public static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop", "Interrupt",
        "PermissionRequest", "PreToolUse", "PostToolUse",
    ]

    /// tkzmux's application support directory, exactly what `AgentIntegration` already hands the
    /// other installed hooks writer of its own.
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The installed hook binary, already signed and already copied into `bin/` by the shim
    /// installer. Installing Codex's hooks therefore adds no new executable of its own.
    public var hookBinary: URL {
        directory.appendingPathComponent("bin/tkzmux-hook", isDirectory: false)
    }

    public var codexHooksDirectory: URL {
        directory.appendingPathComponent("codex-hooks", isDirectory: true)
    }

    public func previousURL(accountKey: String) -> URL {
        codexHooksDirectory.appendingPathComponent(
            "previous-\(accountKey).json", isDirectory: false)
    }

    public static func hooksPath(configDir: String) -> String {
        (configDir as NSString).appendingPathComponent("hooks.json")
    }

    public static func configTomlPath(configDir: String) -> String {
        (configDir as NSString).appendingPathComponent("config.toml")
    }

    /// Codex's own hook-trust ledger. Read-only, and only ever text-scanned — see
    /// `CodexHooksTrustState`.
    public static func hooksStatePath(configDir: String) -> String {
        (configDir as NSString).appendingPathComponent("hooks.state")
    }

    /// The command this installer writes for one event. Quoted because the support directory may
    /// contain spaces (`~/Library/Application Support/…`).
    public func command(for event: String) -> String {
        "\"\(hookBinary.path)\" \(event)"
    }

    // MARK: - Detection

    public func detect(configDir: String, fileManager: FileManager = .default) -> CodexHooksDetection {
        CodexHooksDetection(
            producer: detectProducer(configDir: configDir, fileManager: fileManager),
            configTomlHasHooks: Self.configTomlHasHooksBlocks(
                configDir: configDir, fileManager: fileManager),
            trust: trustState(configDir: configDir, fileManager: fileManager))
    }

    public func isInstalled(configDir: String, fileManager: FileManager = .default) -> Bool {
        detect(configDir: configDir, fileManager: fileManager).producer == .tkzmux
    }

    private func detectProducer(
        configDir: String, fileManager: FileManager
    ) -> CodexHooksProducer {
        let path = Self.hooksPath(configDir: configDir)
        guard let data = fileManager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              case .object(let rootPairs)? = Self.parseDocument(text),
              let hooksField = rootPairs.first(where: { $0.key == "hooks" }),
              case .object(let hookPairs) = hooksField.value
        else { return .none }

        // "Fully covered" means every managed event has *some* `tkzmux-hook` entry for it,
        // whether that entry is exactly this build's command or a stale one from elsewhere. Only
        // when every event clears that bar does `.stale` mean what `repair` assumes it means — a
        // complete prior install that just needs repointing — rather than a handful of stale
        // leftovers mixed in with events nobody has ever hooked, which `repair` alone could not
        // finish (see `repair`'s own doc comment).
        var fullyCovered = true
        var stalePaths: Set<String> = []
        var sawAnyEntry = false

        for event in Self.events {
            guard let field = hookPairs.first(where: { $0.key == event }),
                  case .array(let groups) = field.value
            else {
                fullyCovered = false
                continue
            }
            let ourCommand = command(for: event)
            var coveredForThisEvent = false
            // An entry lives two levels down from the event: the event's array holds *groups*,
            // and each group's own `hooks` array holds the `{type, command}` entries — the shape
            // measured to actually run (see this file's header comment).
            for cmd in Self.commandStrings(inGroups: groups) {
                sawAnyEntry = true
                if cmd == ourCommand {
                    coveredForThisEvent = true
                } else if Self.runsTkzmuxHook(for: event, command: cmd) {
                    stalePaths.insert(Self.tkzmuxHookPath(in: cmd) ?? cmd)
                    coveredForThisEvent = true
                }
            }
            if !coveredForThisEvent { fullyCovered = false }
        }

        if fullyCovered { return stalePaths.isEmpty ? .tkzmux : .stale(paths: stalePaths) }
        if sawAnyEntry { return .other }
        return .none
    }

    /// True when `command` runs *a* `tkzmux-hook <event>` — any tkzmux-hook, any path, any
    /// quoting — for exactly this event. Mirrors the other installed-hook writer's own detection
    /// of a stale statusline command; the same "quoted because the support directory may contain
    /// spaces" reasoning applies here.
    static func runsTkzmuxHook(for event: String, command: String) -> Bool {
        var remainder = Substring(command)
        while let hook = remainder.range(of: "tkzmux-hook") {
            let tail = remainder[hook.upperBound...].drop { $0 == "\"" || $0 == "'" || $0 == " " }
            if tail.hasPrefix(event) {
                let afterEvent = tail.dropFirst(event.count)
                if afterEvent.isEmpty || afterEvent.first == " " || afterEvent.first == "\"" {
                    return true
                }
            }
            remainder = remainder[hook.upperBound...]
        }
        return false
    }

    /// The path portion of a `tkzmux-hook` command, for reporting where a stale install points.
    /// `nil` when `command` does not contain a recognisable invocation.
    static func tkzmuxHookPath(in command: String) -> String? {
        guard let range = command.range(of: "tkzmux-hook") else { return nil }
        var start = command.startIndex
        if let quote = command[..<range.lowerBound].lastIndex(of: "\"") {
            start = command.index(after: quote)
        }
        return String(command[start..<range.upperBound])
    }

    /// Text-scans `config.toml` for a `[[hooks.<Event>]]` array-of-tables header. There is no TOML
    /// parser in this codebase and this installer must not add one — a line-level scan for the
    /// syntax Codex itself requires for a hook table is enough to answer "does the user already
    /// have hooks configured there", which is all this needs to know; `config.toml` is never
    /// parsed further and never edited.
    static func configTomlHasHooksBlocks(configDir: String, fileManager: FileManager) -> Bool {
        let path = Self.configTomlPath(configDir: configDir)
        guard let data = fileManager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[["), line.hasSuffix("]]") else { continue }
            let inner = line.dropFirst(2).dropLast(2)
            if inner.hasPrefix("hooks.") { return true }
        }
        return false
    }

    /// See `CodexHooksTrustState`: a heuristic text-scan of the ledger, never a computation of the
    /// hash Codex uses, and never a write.
    private func trustState(configDir: String, fileManager: FileManager) -> CodexHooksTrustState {
        let path = Self.hooksStatePath(configDir: configDir)
        guard let data = fileManager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty
        else { return .unknown }
        let hooksJSONPath = Self.hooksPath(configDir: configDir)
        return text.contains(hooksJSONPath) ? .mentionsOurConfig : .doesNotMentionOurConfig
    }

    // MARK: - Planning

    /// Builds the before/after for a consent sheet without writing anything.
    public func plan(
        configDir: String, accountKey: String, fileManager: FileManager = .default
    ) throws -> CodexHooksInstallPlan {
        let path = Self.hooksPath(configDir: configDir)
        let detection = detect(configDir: configDir, fileManager: fileManager)
        let existingText = try Self.readExisting(path: path, fileManager: fileManager)
        let existingRoot = try Self.validatedRoot(of: existingText, path: path)
        let after = Self.serializePretty(merge(existingRoot))
        return CodexHooksInstallPlan(
            hooksPath: path, accountKey: accountKey, before: existingText, after: after,
            detection: detection)
    }

    // MARK: - Install / uninstall / repair

    /// Appends a new group carrying this build's command to every managed event's array, creating
    /// `hooks.<event>` (and the file) where it does not exist yet. Existing groups for those
    /// events — anyone's — are never replaced, reordered or merged into; this only ever adds a
    /// sibling group.
    public func install(
        configDir: String, accountKey: String, fileManager: FileManager = .default
    ) throws {
        switch detect(configDir: configDir, fileManager: fileManager).producer {
        case .tkzmux:
            return
        case .stale:
            // Already tkzmux's hooks, just the wrong binary path. Re-point them and leave the
            // record that is already on disk alone — recording now would save tkzmux's own
            // command as the thing a future uninstall restores.
            _ = try repair(configDir: configDir, accountKey: accountKey, fileManager: fileManager)
            return
        case .none, .other:
            break
        }

        let path = Self.hooksPath(configDir: configDir)
        try fileManager.createDirectory(at: codexHooksDirectory, withIntermediateDirectories: true)

        let existingText = try Self.readExisting(path: path, fileManager: fileManager)
        let existingRoot = try Self.validatedRoot(of: existingText, path: path)

        // The record is the whole prior document, verbatim, or the sentinel `"null"` when there
        // was no file — never a reconstruction. That is what lets `uninstall` restore the file
        // byte-for-byte instead of re-deriving it through the same merge logic a second time.
        let saved = existingText ?? "null"
        if shouldRecord(saved, accountKey: accountKey, fileManager: fileManager) {
            try Self.writeVerbatim(
                saved, to: previousURL(accountKey: accountKey), fileManager: fileManager)
        }

        try Self.write(
            Self.serializePretty(merge(existingRoot)), to: URL(fileURLWithPath: path),
            fileManager: fileManager)
    }

    /// Re-points every stale `tkzmux-hook` command to this build's own binary, in place, without
    /// adding an entry or touching the `previous-<accountKey>.json` record.
    ///
    /// Only ever called when `detect` reports `.stale`, which (see `detectProducer`) means every
    /// managed event already has *some* `tkzmux-hook` entry — this only repoints, it never adds a
    /// missing event's first entry, so it would leave a partially-hooked file exactly as partial.
    @discardableResult
    public func repair(
        configDir: String, accountKey: String, fileManager: FileManager = .default
    ) throws -> Bool {
        guard case .stale = detect(configDir: configDir, fileManager: fileManager).producer else {
            return false
        }
        let path = Self.hooksPath(configDir: configDir)
        guard let text = try Self.readExisting(path: path, fileManager: fileManager) else {
            return false
        }
        guard let root = Self.parseDocument(text) else {
            throw CodexHooksInstallerError.hooksFileUnusable(path: path)
        }
        try Self.write(
            Self.serializePretty(repointStaleCommands(root)), to: URL(fileURLWithPath: path),
            fileManager: fileManager)
        return true
    }

    /// Whether the record `install` is about to save may replace the one already on disk.
    ///
    /// `previous-<accountKey>.json` is the only state here that cannot be reconstructed from
    /// anything else, so it is never traded down: a record naming "there was no file" written over
    /// a record naming a real prior document would strand `uninstall` with nothing real to restore.
    /// The older, richer record can at worst restore a file that had already been emptied by hand,
    /// which is visible the moment it happens and undone by removing it again — the opposite trade
    /// to losing it silently.
    private func shouldRecord(
        _ saved: String, accountKey: String, fileManager: FileManager
    ) -> Bool {
        if Self.recordsHooksDocument(saved) { return true }
        let existing = previousURL(accountKey: accountKey)
        guard let data = fileManager.contents(atPath: existing.path),
              let text = String(data: data, encoding: .utf8)
        else { return true }
        return !Self.recordsHooksDocument(text)
    }

    /// True when a saved document is a real prior `hooks.json` rather than the `"null"` sentinel
    /// recording "there was no file".
    static func recordsHooksDocument(_ saved: String) -> Bool {
        guard let data = saved.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else { return false }
        return !(value is NSNull)
    }

    /// Puts back exactly what was there — the saved document verbatim, or removes the file when
    /// there was none — or refuses when doing so would destroy something.
    ///
    /// Refuses in two cases, both meaning "this would destroy something": the live `hooks.json` no
    /// longer carries this build's command for every managed event (something rewired it), or the
    /// companion record is gone.
    public func uninstall(
        configDir: String, accountKey: String, fileManager: FileManager = .default
    ) throws {
        switch detect(configDir: configDir, fileManager: fileManager).producer {
        case .tkzmux, .stale: break
        case .none, .other: throw CodexHooksInstallerError.notInstalled
        }
        let path = Self.hooksPath(configDir: configDir)
        let previous = previousURL(accountKey: accountKey)
        guard let data = fileManager.contents(atPath: previous.path),
              let saved = String(data: data, encoding: .utf8)
        else {
            throw CodexHooksInstallerError.previousMissing(path: previous.path)
        }
        if Self.recordsHooksDocument(saved) {
            try Self.writeVerbatim(saved, to: URL(fileURLWithPath: path), fileManager: fileManager)
        } else {
            try? fileManager.removeItem(atPath: path)
        }
        try? fileManager.removeItem(at: previous)
    }

    // MARK: - Merge

    /// Appends a new group carrying this build's command to every managed event, leaving every
    /// other key — the top-level `hooks` wrapper, every other event, every existing group and
    /// every entry inside it — exactly where it was. A key this installer has not seen before
    /// (including `hooks` itself, when the file predates any hook at all) is appended at the end
    /// rather than inserted, which is the only ordering choice that does not require guessing
    /// where the user would have put it.
    private func merge(_ existingRoot: CodexJSON?) -> CodexJSON {
        var rootPairs: [CodexJSONField]
        if case .object(let existing)? = existingRoot { rootPairs = existing } else { rootPairs = [] }

        let hooksIndex = rootPairs.firstIndex(where: { $0.key == "hooks" })
        var hookPairs: [CodexJSONField]
        if let index = hooksIndex, case .object(let existing) = rootPairs[index].value {
            hookPairs = existing
        } else {
            hookPairs = []
        }

        for event in Self.events {
            let ourCommand = command(for: event)
            if let index = hookPairs.firstIndex(where: { $0.key == event }) {
                guard case .array(var groups) = hookPairs[index].value else { continue }
                let alreadyPresent = Self.commandStrings(inGroups: groups).contains(ourCommand)
                if !alreadyPresent {
                    groups.append(Self.group(command: ourCommand))
                }
                hookPairs[index] = CodexJSONField(key: event, value: .array(groups))
            } else {
                hookPairs.append(
                    CodexJSONField(key: event, value: .array([Self.group(command: ourCommand)])))
            }
        }

        if let index = hooksIndex {
            rootPairs[index] = CodexJSONField(key: "hooks", value: .object(hookPairs))
        } else {
            rootPairs.append(CodexJSONField(key: "hooks", value: .object(hookPairs)))
        }
        return .object(rootPairs)
    }

    /// Rewrites a stale command string in place, wherever it sits inside a group's own `hooks`
    /// array — the group itself, and every other entry inside it, are left untouched.
    private func repointStaleCommands(_ root: CodexJSON) -> CodexJSON {
        guard case .object(var rootPairs) = root,
              let hooksIndex = rootPairs.firstIndex(where: { $0.key == "hooks" }),
              case .object(var hookPairs) = rootPairs[hooksIndex].value
        else { return root }

        for event in Self.events {
            guard let eventIndex = hookPairs.firstIndex(where: { $0.key == event }),
                  case .array(var groups) = hookPairs[eventIndex].value
            else { continue }
            let ourCommand = command(for: event)
            for groupIndex in groups.indices {
                guard case .object(var groupFields) = groups[groupIndex],
                      let hooksFieldIndex = groupFields.firstIndex(where: { $0.key == "hooks" }),
                      case .array(var entries) = groupFields[hooksFieldIndex].value
                else { continue }
                for entryIndex in entries.indices {
                    guard case .object(var entryFields) = entries[entryIndex],
                          let commandIndex = entryFields.firstIndex(where: { $0.key == "command" }),
                          case .string(let cmd) = entryFields[commandIndex].value,
                          cmd != ourCommand,
                          Self.runsTkzmuxHook(for: event, command: cmd)
                    else { continue }
                    entryFields[commandIndex] = CodexJSONField(
                        key: "command", value: .string(ourCommand))
                    entries[entryIndex] = .object(entryFields)
                }
                groupFields[hooksFieldIndex] = CodexJSONField(key: "hooks", value: .array(entries))
                groups[groupIndex] = .object(groupFields)
            }
            hookPairs[eventIndex] = CodexJSONField(key: event, value: .array(groups))
        }
        rootPairs[hooksIndex] = CodexJSONField(key: "hooks", value: .object(hookPairs))
        return .object(rootPairs)
    }

    /// One group: the unit an event's array holds. `[[hooks.<Event>]]` in `config.toml` is exactly
    /// this — a group — and `[[hooks.<Event>.hooks]]` is an entry inside it, which is what this
    /// mirrors on the JSON side.
    private static func group(command: String) -> CodexJSON {
        .object([
            CodexJSONField(key: "hooks", value: .array([entry(command: command)]))
        ])
    }

    private static func entry(command: String) -> CodexJSON {
        .object([
            CodexJSONField(key: "type", value: .string("command")),
            CodexJSONField(key: "command", value: .string(command)),
        ])
    }

    private static func commandString(of value: CodexJSON) -> String? {
        guard case .object(let fields) = value,
              let field = fields.first(where: { $0.key == "command" }),
              case .string(let command) = field.value
        else { return nil }
        return command
    }

    /// Every `command` found inside any of `groups`' own `hooks` arrays — the only place Codex
    /// was measured to actually read an entry from (see this file's header comment).
    private static func commandStrings(inGroups groups: [CodexJSON]) -> [String] {
        var commands: [String] = []
        for group in groups {
            guard case .object(let fields) = group,
                  let hooksField = fields.first(where: { $0.key == "hooks" }),
                  case .array(let entries) = hooksField.value
            else { continue }
            for entry in entries {
                if let command = commandString(of: entry) { commands.append(command) }
            }
        }
        return commands
    }

    // MARK: - Reading and validating the existing file

    /// `nil` when the file does not exist; throws when it exists but is not readable text, which
    /// is treated the same as unparsable JSON — refuse rather than guess.
    private static func readExisting(path: String, fileManager: FileManager) throws -> String? {
        guard let data = fileManager.contents(atPath: path) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexHooksInstallerError.hooksFileUnusable(path: path)
        }
        return text
    }

    /// Parses and validates `text` (when present) into the value `merge` and `repair` operate on,
    /// throwing rather than returning `nil` so every call site's failure looks the same.
    private static func validatedRoot(of text: String?, path: String) throws -> CodexJSON? {
        guard let text else { return nil }
        guard let root = parseDocument(text) else {
            throw CodexHooksInstallerError.hooksFileUnusable(path: path)
        }
        return root
    }

    /// Parses `text` as JSON and validates only what this installer is about to touch: the root
    /// must be an object; a top-level `hooks` key, if present, must be an object; any managed
    /// event already present under it must hold an array of groups; and any such group that
    /// already carries its own `hooks` key must hold an array there too. Every other key, at any
    /// depth — including a group with no `hooks` key of its own, and any key this installer does
    /// not manage — is accepted without further inspection: this installer has no opinion on it
    /// and must preserve it untouched.
    private static func parseDocument(_ text: String) -> CodexJSON? {
        var parser = CodexJSONParser(text)
        guard let value = parser.parse(), case .object(let rootPairs) = value else { return nil }
        guard let hooksField = rootPairs.first(where: { $0.key == "hooks" }) else { return value }
        guard case .object(let hookPairs) = hooksField.value else { return nil }
        for event in events {
            guard let field = hookPairs.first(where: { $0.key == event }) else { continue }
            guard case .array(let groups) = field.value else { return nil }
            for group in groups {
                guard case .object(let groupFields) = group else { return nil }
                if let groupHooks = groupFields.first(where: { $0.key == "hooks" }) {
                    guard case .array = groupHooks.value else { return nil }
                }
            }
        }
        return value
    }

    /// For a document this installer generates itself (the freshly merged `hooks.json`): normalised
    /// to end in exactly one trailing newline, the convention for a file a human reads and diffs.
    private static func write(_ text: String, to url: URL, fileManager: FileManager) throws {
        var contents = text
        if !contents.hasSuffix("\n") { contents += "\n" }
        try ShimInstaller.writeAtomically(
            Data(contents.utf8), to: url, permissions: 0o644, fileManager: fileManager)
    }

    /// For a document this installer only captured (the `previous-<accountKey>.json` record, and
    /// `hooks.json` on `uninstall`'s restore path): written exactly as captured, with no trailing
    /// newline added or removed. `install` then `uninstall` must restore the file byte-for-byte,
    /// including a file that never had a trailing newline to begin with — `write`'s normalisation
    /// would turn that into an extra byte nobody asked for.
    private static func writeVerbatim(_ text: String, to url: URL, fileManager: FileManager) throws {
        try ShimInstaller.writeAtomically(
            Data(text.utf8), to: url, permissions: 0o644, fileManager: fileManager)
    }
}

// MARK: - A small, ordered JSON value, parser and serializer

// `hooks.json` is a file the user reads and diffs, so a round trip through `JSONSerialization`
// (which is neither order-preserving nor number-text-preserving) is wrong here for the same reason
// it is wrong for the other installed-hook writer's own settings file. That type delegates its
// rewrite to a small hand-written parser in a Foundation-free helper target; this installer has no
// access to that target and must not depend on it, so it carries its own copy of the same idea,
// scoped privately to this file.

private struct CodexJSONField {
    var key: String
    var value: CodexJSON
}

private indirect enum CodexJSON {
    case object([CodexJSONField])
    case array([CodexJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

/// Byte-level recursive-descent parser. Returns `nil` on any malformed input, including trailing
/// garbage after the top-level value.
private struct CodexJSONParser {
    private let bytes: [UInt8]
    private var i = 0

    init(_ s: String) { self.bytes = Array(s.utf8) }

    mutating func parse() -> CodexJSON? {
        skipWhitespace()
        guard let value = parseValue() else { return nil }
        skipWhitespace()
        guard i == bytes.count else { return nil }
        return value
    }

    private mutating func skipWhitespace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    private mutating func parseValue() -> CodexJSON? {
        skipWhitespace()
        guard i < bytes.count else { return nil }
        switch bytes[i] {
        case 0x7B: return parseObject()
        case 0x5B: return parseArray()
        case 0x22: return parseRawString().map(CodexJSON.string)
        case 0x74: return parseLiteral("true", .bool(true))
        case 0x66: return parseLiteral("false", .bool(false))
        case 0x6E: return parseLiteral("null", .null)
        default: return parseNumber()
        }
    }

    private mutating func parseLiteral(_ text: String, _ value: CodexJSON) -> CodexJSON? {
        let literal = Array(text.utf8)
        guard i + literal.count <= bytes.count, Array(bytes[i..<i + literal.count]) == literal
        else { return nil }
        i += literal.count
        return value
    }

    private mutating func parseNumber() -> CodexJSON? {
        let start = i
        if i < bytes.count, bytes[i] == 0x2D { i += 1 }
        var sawDigit = false
        while i < bytes.count, isDigit(bytes[i]) { i += 1; sawDigit = true }
        guard sawDigit else { i = start; return nil }
        if i < bytes.count, bytes[i] == 0x2E {
            i += 1
            var sawFracDigit = false
            while i < bytes.count, isDigit(bytes[i]) { i += 1; sawFracDigit = true }
            guard sawFracDigit else { i = start; return nil }
        }
        if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
            i += 1
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            var sawExpDigit = false
            while i < bytes.count, isDigit(bytes[i]) { i += 1; sawExpDigit = true }
            guard sawExpDigit else { i = start; return nil }
        }
        return .number(String(decoding: bytes[start..<i], as: UTF8.self))
    }

    private func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    private mutating func parseObject() -> CodexJSON? {
        i += 1
        var fields: [CodexJSONField] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == 0x7D { i += 1; return .object(fields) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == 0x22, let key = parseRawString() else { return nil }
            skipWhitespace()
            guard i < bytes.count, bytes[i] == 0x3A else { return nil }
            i += 1
            guard let value = parseValue() else { return nil }
            fields.append(CodexJSONField(key: key, value: value))
            skipWhitespace()
            guard i < bytes.count else { return nil }
            if bytes[i] == 0x2C { i += 1; continue }
            if bytes[i] == 0x7D { i += 1; break }
            return nil
        }
        return .object(fields)
    }

    private mutating func parseArray() -> CodexJSON? {
        i += 1
        var items: [CodexJSON] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == 0x5D { i += 1; return .array(items) }
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            guard i < bytes.count else { return nil }
            if bytes[i] == 0x2C { i += 1; continue }
            if bytes[i] == 0x5D { i += 1; break }
            return nil
        }
        return .array(items)
    }

    private mutating func parseRawString() -> String? {
        guard i < bytes.count, bytes[i] == 0x22 else { return nil }
        i += 1
        var out = String()
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x22 { i += 1; return out }
            if b == 0x5C {
                i += 1
                guard i < bytes.count else { return nil }
                let e = bytes[i]
                switch e {
                case 0x22: out.append("\""); i += 1
                case 0x5C: out.append("\\"); i += 1
                case 0x2F: out.append("/"); i += 1
                case 0x62: out.append("\u{08}"); i += 1
                case 0x66: out.append("\u{0C}"); i += 1
                case 0x6E: out.append("\n"); i += 1
                case 0x72: out.append("\r"); i += 1
                case 0x74: out.append("\t"); i += 1
                case 0x75:
                    i += 1
                    guard let cp1 = readHex4() else { return nil }
                    if cp1 >= 0xD800 && cp1 <= 0xDBFF {
                        guard i + 1 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75 else {
                            out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
                            continue
                        }
                        i += 2
                        guard let cp2 = readHex4(), cp2 >= 0xDC00, cp2 <= 0xDFFF else {
                            out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
                            continue
                        }
                        let combined = 0x10000 + (cp1 - 0xD800) * 0x400 + (cp2 - 0xDC00)
                        if let scalar = Unicode.Scalar(combined) { out.unicodeScalars.append(scalar) }
                    } else if cp1 >= 0xDC00 && cp1 <= 0xDFFF {
                        out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
                    } else if let scalar = Unicode.Scalar(cp1) {
                        out.unicodeScalars.append(scalar)
                    } else {
                        return nil
                    }
                default:
                    return nil
                }
            } else {
                let len = Self.utf8SequenceLength(b)
                guard i + len <= bytes.count else { return nil }
                out += String(decoding: bytes[i..<i + len], as: UTF8.self)
                i += len
            }
        }
        return nil
    }

    private mutating func readHex4() -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = hexDigit(bytes[i]) else { return nil }
            value = (value << 4) | UInt32(digit)
            i += 1
        }
        return value
    }

    private func hexDigit(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    private static func utf8SequenceLength(_ b: UInt8) -> Int {
        if b & 0x80 == 0 { return 1 }
        if b & 0xE0 == 0xC0 { return 2 }
        if b & 0xF0 == 0xE0 { return 3 }
        if b & 0xF8 == 0xF0 { return 4 }
        return 1
    }
}

/// Two-space-indented serialization, for a document a human reads and diffs.
extension CodexHooksInstaller {
    fileprivate static func serializePretty(_ value: CodexJSON, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch value {
        case .object(let fields):
            guard !fields.isEmpty else { return "{}" }
            let body = fields
                .map { "\(inner)\"\(jsonEscape($0.key))\": \(serializePretty($0.value, indent: indent + 1))" }
                .joined(separator: ",\n")
            return "{\n" + body + "\n" + pad + "}"
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            let body = items
                .map { "\(inner)\(serializePretty($0, indent: indent + 1))" }
                .joined(separator: ",\n")
            return "[\n" + body + "\n" + pad + "]"
        case .string(let s):
            return "\"\(jsonEscape(s))\""
        case .number(let raw):
            return raw
        case .bool(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        }
    }

    fileprivate static func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
