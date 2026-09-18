// ClaudeBridge — Claude Code's own session descriptor, and its projection into the generic
// `AgentObservation` the store reacts to.
//
// This lived in TkzCore until TKZ-81. It had to move: it is one agent's file schema, TkzCore is
// the agent-blind half of the app, and the dependency runs ClaudeBridge → TkzCore, so TkzCore
// could not name this type even if that were desirable. What crosses the boundary now is
// `observation`, below.

import Foundation
import TkzCore

/// A parsed `~/.claude/sessions/<pid>.json` (or `~/.claude-work/…`) descriptor.
///
/// **Another program writes this file in place**, so a read can land mid-write: decoding is
/// deliberately forgiving. Only `pid` and `sessionId` are required;
/// every other field is optional, unknown keys are ignored, and unknown enum values fall back to
/// `.unknown(raw)` rather than throwing the whole descriptor away. A *torn* file (truncated JSON)
/// still throws a `DecodingError` — there is nothing to salvage — and the watcher's contract is to
/// keep the previous value in that case.
///
/// `configDir` is **not** in the JSON: it is the directory the file was found in, which is what
/// tells us which account the session belongs to. Inject it with `decode(_:configDir:)`, or set
/// `decoder.userInfo[ClaudeSessionInfo.configDirUserInfoKey]`.
public struct ClaudeSessionInfo: Hashable, Sendable, Decodable {
    public enum Kind: Hashable, Sendable {
        case interactive
        case background
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "interactive": self = .interactive
            case "bg", "background": self = .background
            default: self = .unknown(raw)
            }
        }
    }

    public enum NameSource: Hashable, Sendable {
        case auto
        case derived
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "auto": self = .auto
            case "derived": self = .derived
            default: self = .unknown(raw)
            }
        }
    }

    public enum Status: Hashable, Sendable {
        case idle
        case busy
        /// Claude Code 2.1.263 writes `"waiting"` while a permission prompt is on screen
        /// (measured 2026-09-08: idle → busy on submit → waiting at the prompt → busy the moment
        /// it is answered → idle at Stop). It is the hook-free way to see NEEDS YOU.
        case waiting
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "idle": self = .idle
            case "busy": self = .busy
            case "waiting": self = .waiting
            default: self = .unknown(raw)
            }
        }
    }

    /// The directory the descriptor was found in (`~/.claude`, `~/.claude-work`) — the account key
    /// is its basename. Injected, never decoded.
    public var configDir: String
    public var pid: pid_t
    public var sessionId: String
    public var cwd: String?
    /// Decoded from epoch **milliseconds**; also the pid-reuse guard against `pbi_start_tvsec`.
    public var startedAt: Date?
    public var version: String?
    public var kind: Kind?
    public var entrypoint: String?
    public var name: String?
    public var nameSource: NameSource?
    public var status: Status?
    public var updatedAt: Date?
    public var statusUpdatedAt: Date?
    public var messagingSocketPath: String?
    public var bridgeSessionId: String?
    public var parkedJobId: String?
    public var jobId: String?

    /// The account key: the basename of the config dir **minus its leading dot**, so
    /// `~/.claude` → `"claude"` and `~/.claude-work` → `"claude-work"`. That is the spelling
    /// `Account.key`, `Session.accountKey` and the `statusline/usage-<key>.json` filenames all use, and
    /// the join key for `descriptor.accountKey == session.accountKey` in M3.
    public var accountKey: String {
        let basename = (configDir as NSString).lastPathComponent
        return basename.hasPrefix(".") ? String(basename.dropFirst()) : basename
    }

    /// A background descriptor parked under this job id belongs to the interactive session whose
    /// `jobId` matches.
    public var isBackground: Bool { kind == .background }

    public init(
        configDir: String,
        pid: pid_t,
        sessionId: String,
        cwd: String? = nil,
        startedAt: Date? = nil,
        version: String? = nil,
        kind: Kind? = nil,
        entrypoint: String? = nil,
        name: String? = nil,
        nameSource: NameSource? = nil,
        status: Status? = nil,
        updatedAt: Date? = nil,
        statusUpdatedAt: Date? = nil,
        messagingSocketPath: String? = nil,
        bridgeSessionId: String? = nil,
        parkedJobId: String? = nil,
        jobId: String? = nil
    ) {
        self.configDir = configDir
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.version = version
        self.kind = kind
        self.entrypoint = entrypoint
        self.name = name
        self.nameSource = nameSource
        self.status = status
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.messagingSocketPath = messagingSocketPath
        self.bridgeSessionId = bridgeSessionId
        self.parkedJobId = parkedJobId
        self.jobId = jobId
    }

    /// `decoder.userInfo` key carrying the config dir (a `String`) into `init(from:)`.
    public static let configDirUserInfoKey = CodingUserInfoKey(rawValue: "se.tkz.tkzmux.configDir")!

    /// The supported way to parse a descriptor file.
    /// - Throws: `DecodingError` when the bytes are not a JSON object with `pid` and `sessionId`
    ///   (a torn write); the caller keeps the previous value.
    public static func decode(_ data: Data, configDir: String) throws -> ClaudeSessionInfo {
        let decoder = JSONDecoder()
        decoder.userInfo[configDirUserInfoKey] = configDir
        return try decoder.decode(ClaudeSessionInfo.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, startedAt, version, kind, entrypoint, name, nameSource
        case status, updatedAt, statusUpdatedAt, messagingSocketPath, bridgeSessionId
        case parkedJobId, jobId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configDir = decoder.userInfo[Self.configDirUserInfoKey] as? String ?? ""
        // Required: without these two the descriptor identifies nothing.
        guard let pid = Self.int(c, .pid).map({ pid_t($0) }) else {
            throw DecodingError.keyNotFound(
                CodingKeys.pid,
                .init(codingPath: c.codingPath, debugDescription: "descriptor has no usable 'pid'"))
        }
        guard let sessionId = try? c.decode(String.self, forKey: .sessionId), !sessionId.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.sessionId,
                .init(codingPath: c.codingPath, debugDescription: "descriptor has no 'sessionId'"))
        }
        self.pid = pid
        self.sessionId = sessionId
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        startedAt = Self.date(c, .startedAt)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).map(Kind.init(raw:))
        entrypoint = try? c.decodeIfPresent(String.self, forKey: .entrypoint)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        nameSource = (try? c.decodeIfPresent(String.self, forKey: .nameSource))
            .map(NameSource.init(raw:))
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).map(Status.init(raw:))
        updatedAt = Self.date(c, .updatedAt)
        statusUpdatedAt = Self.date(c, .statusUpdatedAt)
        messagingSocketPath = try? c.decodeIfPresent(String.self, forKey: .messagingSocketPath)
        bridgeSessionId = try? c.decodeIfPresent(String.self, forKey: .bridgeSessionId)
        parkedJobId = try? c.decodeIfPresent(String.self, forKey: .parkedJobId)
        jobId = try? c.decodeIfPresent(String.self, forKey: .jobId)
    }

    /// Number or numeric string — Claude Code has shipped both shapes for ids.
    private static func int(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? c.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let text = try? c.decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }

    /// Epoch **milliseconds** → `Date`; tolerant of a numeric string.
    private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        var millis: Double?
        if let value = try? c.decodeIfPresent(Double.self, forKey: key) { millis = value }
        else if let text = try? c.decodeIfPresent(String.self, forKey: key) { millis = Double(text) }
        guard let millis, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}

extension ClaudeSessionInfo {
    /// The agent-blind half of this descriptor — the only part that crosses into `TkzCore`.
    ///
    /// Deliberately narrow. `jobId`, `messagingSocketPath`, `entrypoint`, `version` and the rest
    /// stay here: nothing in the store reads them, and carrying them across would put Claude's
    /// schema back where this change just took it out of. `parkedJobId` collapses to a boolean for
    /// the same reason — the store only ever asks *whether* a job is parked.
    ///
    /// An unrecognised `status` projects to `nil` rather than to `.idle`: "the descriptor said
    /// something this build does not know" is not the same claim as "the agent is idle", and
    /// `StatusDerivation` treats the absence as no evidence.
    public var observation: AgentObservation {
        AgentObservation(
            pid: pid,
            conversationId: sessionId,
            configDir: configDir,
            cwd: cwd,
            activity: status.flatMap { status in
                switch status {
                case .idle: .idle
                case .busy: .busy
                case .waiting: .waiting
                case .unknown: nil
                }
            },
            parked: parkedJobId != nil,
            name: name,
            nameIsDerived: nameSource == .derived,
            startedAt: startedAt,
            statusUpdatedAt: statusUpdatedAt)
    }
}
