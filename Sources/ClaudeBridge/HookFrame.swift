// The parsed form of one NDJSON frame received by `HookServer`. See docs/design.md → Claude
// integration → tkzmux-hook, and the wire protocol in the M3.2 (TKZ-22) ticket.
import Darwin
import TkzCore

/// One decoded wire frame handed to `HookServer`'s `onFrame` callback, in arrival order.
public enum HookFrame: Sendable {
    /// A hook event forwarded by `tkzmux-hook <Event>`. `fullMessage`, `cwd` and `transcriptPath`
    /// carry the untruncated `last_assistant_message`, `payload.cwd` and `payload.transcript_path`
    /// alongside the `HookEvent` (which only keeps a 4 KiB prefix of the message, per
    /// `docs/design.md`). Every hook kind carries the transcript path, so the first frame of a
    /// session is enough to learn where Claude keeps its conversation — `TranscriptReader` reads it.
    case hook(HookEvent, ppid: pid_t, fullMessage: String?, cwd: String?, transcriptPath: String?)
    case launch(LaunchAnnouncement)
}

/// A `launch` frame sent by `tkzmux-hook launch` right after the shim `exec`s the real `claude`,
/// so the shim's pid is known as a `SessionID` before the descriptor file (`<pid>.json`) exists.
public struct LaunchAnnouncement: Hashable, Sendable {
    /// `rawSid` parsed as a `SessionID`, when it is a valid UUID; nil for a missing/empty/invalid sid.
    public var sessionID: SessionID?
    /// The `sid` field exactly as sent (may be empty).
    public var rawSid: String
    public var pid: pid_t
    public var cwd: String
    public var configDir: String
    public var argv: [String]

    public init(sessionID: SessionID?, rawSid: String, pid: pid_t, cwd: String, configDir: String, argv: [String]) {
        self.sessionID = sessionID
        self.rawSid = rawSid
        self.pid = pid
        self.cwd = cwd
        self.configDir = configDir
        self.argv = argv
    }
}
