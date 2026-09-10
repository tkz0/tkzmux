// BrewCommand — running `brew` from a GUI app without hanging it (TKZ-50).
//
// Why not `GitProcess.run`: it reads stdout to EOF *then* stderr, and says so itself — a child
// that fills the 64 KiB stderr buffer while the reader is blocked on stdout stalls forever. brew
// streams progress to stderr. Here stdout and stderr share **one** `Pipe`, and the calling queue
// drains it line by line until EOF: one consumer on the only buffer the child can block on, so
// the child can never block. EOF arrives when brew *and every child holding the fd* have exited.
//
// Foundation's `Process` puts the child in its own process group (verified 2026-09-10), so a
// timeout signals the *group* — `kill(-pid, …)` — or brew's `git`/`curl` children would keep the
// pipe open and the drain would never finish.
//
// This file is Foundation-only; the protocol is what the tests substitute so `swift test` never
// spawns brew.

import Foundation
import Synchronization

public struct UpdateCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var timeout: TimeInterval

    public init(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

public struct UpdateCommandResult: Sendable, Equatable {
    /// Exit status; `-1` when the process never launched.
    public var status: Int32
    public var timedOut: Bool
    public var launchError: String?
    /// The last non-empty line the command printed, after `UpdateFailureText.clean`.
    public var lastLine: String?

    public init(status: Int32, timedOut: Bool = false, launchError: String? = nil, lastLine: String? = nil) {
        self.status = status
        self.timedOut = timedOut
        self.launchError = launchError
        self.lastLine = lastLine
    }

    public var succeeded: Bool { status == 0 && !timedOut && launchError == nil }
}

/// Blocking; only ever called on `UpgradeRunner`'s serial queue. `onLine` fires once per line of
/// merged stdout+stderr, in order, on the calling thread — synchronously, so it need not be
/// `Sendable` and can append to a plain log object.
public protocol UpdateCommandRunning: Sendable {
    func run(_ command: UpdateCommand, onLine: (String) -> Void) -> UpdateCommandResult
}

/// The real thing.
public struct BrewCommandRunner: UpdateCommandRunning {
    /// How long after SIGTERM the group gets SIGKILL.
    public static let killGrace: TimeInterval = 5

    public init() {}

    public func run(_ command: UpdateCommand, onLine: (String) -> Void) -> UpdateCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return UpdateCommandResult(status: -1, launchError: error.localizedDescription)
        }

        // Timeout: SIGTERM the group, then SIGKILL it. `killed` is read after the drain.
        let killed = Mutex(false)
        let pid = process.processIdentifier
        let term = DispatchWorkItem {
            killed.withLock { $0 = true }
            kill(-pid, SIGTERM)
        }
        let kill9 = DispatchWorkItem { kill(-pid, SIGKILL) }
        Self.timerQueue.asyncAfter(deadline: .now() + command.timeout, execute: term)
        Self.timerQueue.asyncAfter(deadline: .now() + command.timeout + Self.killGrace, execute: kill9)

        // Drain. The write end must be closed on our side or EOF never comes once the child exits.
        try? pipe.fileHandleForWriting.close()
        var lastLine: String?
        var buffer = Data()
        let reader = pipe.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let line = String(decoding: lineData, as: UTF8.self)
                onLine(line)
                if let cleaned = UpdateFailureText.clean(line) { lastLine = cleaned }
            }
        }
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            onLine(line)
            if let cleaned = UpdateFailureText.clean(line) { lastLine = cleaned }
        }
        try? reader.close()
        process.waitUntilExit()
        term.cancel()
        kill9.cancel()

        return UpdateCommandResult(
            status: process.terminationStatus,
            timedOut: killed.withLock { $0 },
            lastLine: lastLine)
    }

    private static let timerQueue = DispatchQueue(label: "se.tkz.tkzmux.update.timeout")
}

/// One line the card can show for a failed step.
public enum UpdateFailureText {
    public static let maxLength = 200

    public static func describe(step: String, result: UpdateCommandResult, timeout: TimeInterval) -> String {
        if let launchError = result.launchError {
            return "Could not run brew: \(launchError)"
        }
        if result.timedOut {
            return "brew \(step) timed out after \(Int(timeout)) s"
        }
        if let line = result.lastLine {
            return "\(line) (exit \(result.status))"
        }
        return "brew \(step) failed (exit \(result.status))"
    }

    /// Strips ANSI colour sequences and `\r` progress fragments, trims, caps the length; `nil`
    /// when nothing readable is left.
    public static func clean(_ raw: String) -> String? {
        // Keep only what came after the last carriage return: that is what a terminal would show.
        var text = raw.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? raw
        text = stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > maxLength {
            text = String(text.prefix(maxLength - 1)) + "…"
        }
        return text
    }

    /// Removes `ESC [ … <letter>` sequences.
    static func stripANSI(_ text: String) -> String {
        var out = ""
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\u{1B}" else { out.append(ch); continue }
            guard let bracket = iterator.next() else { break }
            guard bracket == "[" else { out.append(bracket); continue }
            while let next = iterator.next() {
                if next.isLetter { break }
            }
        }
        return out
    }
}
