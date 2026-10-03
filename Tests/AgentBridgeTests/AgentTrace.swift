// AgentTrace — the normalized record of what one agent session sent tkzmux and what tkzmux made of
// it (WOR-306 S6). The real-agent probe (`RealAgentProbeTests`, opt-in) builds one from a live
// Claude Code or Codex run; `AgentFixtureReplayTests` rebuilds its `launch`, `hooks` and `notify`
// sections from the payloads that run captured, through the built hook and a real `HookServer`.
// Both compare against the same goldens in `Fixtures/linux/*.trace`, on every OS: a Mac probe run
// that matches them is what "the Linux traces equal the macOS traces" means.
//
// The format is line-per-fact text, grouped into `[section]`s. Everything that differs from run to
// run is a placeholder: paths (`<home>`, `<project>`, `<support>`), ids (`<pane-1>`,
// `<conversation-1>`, in order of first appearance), Codex rollout timestamps. pids and clocks are
// left out. Lines starting with `#` are comments. Sections whose order is not fixed by the agent
// (notify calls, which race each other) are sorted.
import Foundation
import TkzCore

@testable import AgentBridge

/// Rewrites one run's paths and ids into placeholders.
struct TraceNormalizer {
    /// Literal replacements, applied longest first so `<project>` wins over `<home>`.
    private var literals: [(String, String)] = []
    private var ids: [String: String] = [:]
    private var counters: [String: Int] = [:]

    /// `paths` maps a real directory to its placeholder. Each one is also registered under its
    /// realpath (macOS reports `/private/var/…` for `/var/…`) and as Claude's transcript-directory
    /// slug, which is the path with every character that is not a letter or digit turned into `-`.
    init(paths: [(path: String, placeholder: String)]) {
        for (path, placeholder) in paths {
            for spelling in Set([path, Self.realPath(path)]) {
                literals.append((spelling, placeholder))
                literals.append((Self.claudeSlug(spelling), "<\(placeholder.dropFirst().dropLast())-slug>"))
            }
        }
        literals.sort { $0.0.count > $1.0.count }
    }

    /// A stable placeholder for an opaque id: `<kind-1>` for the first one seen, and so on.
    mutating func id(_ raw: String?, kind: String) -> String {
        guard let raw, !raw.isEmpty else { return "-" }
        if let known = ids[raw] { return known }
        let next = (counters[kind] ?? 0) + 1
        counters[kind] = next
        let placeholder = "<\(kind)-\(next)>"
        ids[raw] = placeholder
        return placeholder
    }

    /// Paths replaced, known ids replaced, and Codex's dated rollout layout made timeless.
    func text(_ value: String) -> String {
        var result = value
        for (literal, placeholder) in literals where !literal.isEmpty {
            result = result.replacingOccurrences(of: literal, with: placeholder)
        }
        for (raw, placeholder) in ids {
            result = result.replacingOccurrences(of: raw, with: placeholder)
        }
        result = Self.replacing(#"sessions/\d{4}/\d{2}/\d{2}/"#, in: result, with: "sessions/<date>/")
        result = Self.replacing(
            #"rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-"#, in: result, with: "rollout-<time>-")
        return result
    }

    static func claudeSlug(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

enum AgentTrace {
    // MARK: Lines

    static func launchLine(_ launch: LaunchAnnouncement, normalizer: inout TraceNormalizer) -> String {
        let pane = normalizer.id(launch.sessionID?.rawValue ?? launch.rawSid, kind: "pane")
        let argv = launch.argv.map { normalizer.text($0) }.joined(separator: " ")
        return "launch \(launch.agent.rawValue) pane=\(pane) cwd=\(normalizer.text(launch.cwd))"
            + " config=\(normalizer.text(launch.configDir)) argv=[\(argv)]"
    }

    /// One line per hook frame, in arrival order, each with the status a row fed only these
    /// frames would show next. Notify frames (`agent-turn-complete`) come back separately, since
    /// Codex sends them from more than one thread at once.
    ///
    /// The status column is derived from hooks alone: no descriptor, a fixed clock one second per
    /// frame, the row never attended. For Claude that means rule 4b reads a submitted prompt as
    /// working, where the app would have the descriptor's `busy`; the descriptor has its own
    /// section.
    static func hookLines(
        frames: [HookFrame], adapters: [AgentKind: any AgentAdapter], normalizer: inout TraceNormalizer
    ) -> (hooks: [String], notify: [String]) {
        var state = AppState()
        let group = state.addGroup(name: "probe")
        var rows: [String: SessionID] = [:]
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var hooks: [String] = []
        var notify: [String] = []
        var seenTranscripts: Set<String> = []

        for case let .hook(payload, sessionID, _, _) in frames {
            let pane = normalizer.id(sessionID?.rawValue, kind: "pane")
            let conversation = normalizer.id(payload.sessionId, kind: "conversation")
            var line = "hook \(payload.agent.rawValue) \(payload.eventName) pane=\(pane) conversation=\(conversation)"
            if let source = payload.source { line += " source=\(source)" }
            if let reason = payload.reason { line += " reason=\(reason)" }
            if let notification = payload.notificationType { line += " notification=\(notification)" }
            if let last = payload.lastAssistantMessage { line += " last=\(quoted(last))" }
            if let tasks = payload.backgroundTasks { line += " background=\(tasks.count)" }
            if let transcript = payload.transcriptPath, seenTranscripts.insert(transcript).inserted {
                line += " transcript=\(normalizer.text(transcript))"
            }

            guard let adapter = adapters[payload.agent], var event = adapter.mapHook(payload) else {
                hooks.append(line + " -> dropped")
                continue
            }
            event.sessionID = sessionID
            let row = rows[pane] ?? {
                let session = state.createSession(groupID: group.id, cwd: "/", agent: payload.agent, now: start)
                state.setLive(LiveSessionState(status: .idle), for: session.id)
                rows[pane] = session.id
                return session.id
            }()
            let now = start.addingTimeInterval(Double(hooks.count + notify.count + 1))
            state.applyEvent(event, to: row, now: now)
            line += " -> \(kindName(event.kind))"
            if let live = state.sessions[row]?.live {
                let outcome = StatusDerivation.derive(live, now: now)
                line += " => \(outcome.status.name)"
                if outcome.attention { line += " attention" }
                if outcome.isDone { line += " done" }
            }
            if payload.eventName == "agent-turn-complete" {
                notify.append(line)
            } else {
                hooks.append(line)
            }
        }
        return (sortingRuns(of: hooks, where: { $0.contains(" SessionEnd ") }), notify.sorted())
    }

    /// Consecutive lines matching `belongs` sorted among themselves: Codex ends every session of
    /// its daemon at once when the daemon stops, in no fixed order.
    static func sortingRuns(of lines: [String], where belongs: (String) -> Bool) -> [String] {
        var result: [String] = []
        var run: [String] = []
        for line in lines {
            if belongs(line) {
                run.append(line)
                continue
            }
            result += run.sorted()
            run = []
            result.append(line)
        }
        return result + run.sorted()
    }

    static func kindName(_ kind: AgentEvent.Kind) -> String {
        switch kind {
        case .sessionStart: "sessionStart"
        case .sessionEnd(let exited): exited ? "sessionEnd(exited)" : "sessionEnd(kept)"
        case .promptSubmitted: "promptSubmitted"
        case .turnEnded: "turnEnded"
        case .attention(let attention): "attention(\(attention.rawValue))"
        case .attentionCleared: "attentionCleared"
        case .subagentStarted(let info): "subagentStarted(\(info.type ?? "-"))"
        case .subagentStopped: "subagentStopped"
        case .unknown(let name): "unknown(\(name))"
        }
    }

    static func observationLine(_ event: ObservationEvent, normalizer: inout TraceNormalizer) -> String {
        switch event {
        case .updated(let observation, let alive):
            let conversation = normalizer.id(observation.conversationId, kind: "conversation")
            return "observation \(observation.activity?.rawValue ?? "unknown")"
                + " \(alive ? "alive" : "dead") conversation=\(conversation)"
                + " config=\(normalizer.text(observation.configDir))"
                + " cwd=\(normalizer.text(observation.cwd ?? "-"))"
        case .removed(_, let configDir):
            return "observation removed config=\(normalizer.text(configDir))"
        }
    }

    static func statuslineLine(_ event: StatuslineEvent, normalizer: inout TraceNormalizer) -> String {
        switch event {
        case .context(let sidecar):
            let conversation = normalizer.id(sidecar.sessionId, kind: "conversation")
            var line = "context conversation=\(conversation) account=\(sidecar.accountKey ?? "-")"
            if let model = sidecar.model?.displayName ?? sidecar.model?.id { line += " model=\(quoted(model))" }
            if let used = sidecar.contextUsedPercentage { line += " used=\(Int(used))%" }
            if let project = sidecar.workspace?.projectDir { line += " project=\(normalizer.text(project))" }
            return line
        case .contextRemoved(let sessionId):
            return "context removed conversation=\(normalizer.id(sessionId, kind: "conversation"))"
        case .usage(let snapshot):
            return "usage account=\(snapshot.accountKey) five-hour=\(snapshot.fiveHour != nil) seven-day=\(snapshot.sevenDay != nil)"
        case .usageCleared(let accountKey):
            return "usage cleared account=\(accountKey)"
        }
    }

    static func transcriptLines(
        summary: TranscriptSummary?, usage: SessionUsage?, path: String?, conversation: String,
        normalizer: TraceNormalizer
    ) -> [String] {
        var lines: [String] = []
        var line = "transcript conversation=\(conversation) located=\(path.map(normalizer.text) ?? "-")"
        if let summary {
            line += " first-prompt=\(quoted(normalizer.text(summary.firstPrompt ?? "-")))"
            line += " recap=\(quoted(normalizer.text(summary.recap ?? "-")))"
        }
        lines.append(line)
        for model in usage?.perModel.sorted(by: { $0.modelId < $1.modelId }) ?? [] {
            lines.append(
                "usage conversation=\(conversation) model=\(model.modelId) input=\(model.inputTokens)"
                    + " output=\(model.outputTokens) cache-read=\(model.cacheReadTokens)"
                    + " cache-write=\(model.cacheCreationTokens)")
        }
        return lines
    }

    // MARK: Text

    static func quoted(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + (flattened.count > 80 ? String(flattened.prefix(80)) + "…" : flattened) + "\""
    }

    /// Consecutive duplicates collapsed: a descriptor rewritten with the same status, or a
    /// statusline refresh that changed only the cost, says nothing new.
    static func collapsed(_ lines: [String]) -> [String] {
        lines.reduce(into: []) { result, line in
            if result.last != line { result.append(line) }
        }
    }

    static func render(header: [String], sections: [(name: String, lines: [String])]) -> String {
        var text = header.map { "# \($0)" }.joined(separator: "\n") + "\n"
        for section in sections {
            text += "\n[\(section.name)]\n"
            text += section.lines.map { $0 + "\n" }.joined()
        }
        return text
    }

    /// A rendered trace read back: comments and blank lines dropped, lines grouped by section.
    static func sections(of text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                result[current, default: []] = result[current] ?? []
                continue
            }
            result[current, default: []].append(line)
        }
        return result
    }
}
