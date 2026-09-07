// TerminalSession.swift — the VT bridge. See docs/design.md → *Terminal engine → VT bridge*.
//
// One `TerminalSession` owns one libghostty-vt terminal: it feeds it pty bytes, answers the
// terminal's "effects" (queries, OSC), publishes `TerminalEvent`s, and hands the render layer a
// locked window onto the terminal handle.
//
// ## The single most important constraint: callbacks run *inside* `vt_write`
//
// Every effect callback (`WRITE_PTY`, `BELL`, `TITLE_CHANGED`, `CLIPBOARD_WRITE`, …) is invoked
// **synchronously, on the calling thread, from within `ghostty_terminal_vt_write`**
// (terminal.h: "All callbacks are invoked synchronously during VT writes … must not call
// ghostty_terminal_vt_write() on the same terminal (no reentrancy)"). `vt_write` only ever runs
// inside `state.withLock`, so a callback that tried to take the lock — directly, or indirectly by
// calling back into `TerminalSession` — would deadlock instantly.
//
// The design that makes that impossible rather than merely unlikely:
//
//   * `userdata` does **not** point at `TerminalSession` (whose state lives behind the `Mutex`).
//     It points at `IOContext`, a plain non-Sendable class that is *owned by* the locked state.
//     A callback therefore cannot reach the lock: it has no reference to the session at all.
//   * A callback only ever appends to `IOContext` buffers (`pendingPty`, `pendingEvents`) and
//     reads terminal data through the `terminal` handle it is given as its first argument.
//     Because it runs under the lock (transitively — its caller holds it), that access is
//     exclusive by construction.
//   * After `vt_write` returns, still under the lock, the session *harvests* the buffers.
//     The lock is then released, and only afterwards are the consumer closures (`onWritePty`,
//     the `AsyncStream` continuation, `renderSignal`) invoked. No consumer code ever runs while
//     the lock is held.
//
// ## Threading
//
// `ioQueue` is a serial `.userInteractive` queue that the pty layer (M1.2) reads on; ingestion
// (`write(ptyBytes:)`) is *synchronous* so it can also be driven straight from a test or from
// `tkzmux-vtdump replay` with no scheduling in between. `renderSignal` is the seam the view layer
// (M1.6 / TKZ-12) wires a `DispatchSourceUserDataOr` to; this module never touches AppKit.
import Darwin
import Foundation
import Synchronization
import GhosttyVt
import TkzCore

// MARK: - Options

/// Everything that is configured on the terminal at construction (and re-applied after a restore).
public struct TerminalSessionOptions: Sendable {
    public var cols: UInt16
    public var rows: UInt16
    public var cellWidthPx: UInt32
    public var cellHeightPx: UInt32
    public var theme: Theme
    /// `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES`. The library default is only 10 000 bytes
    /// (measured; ≈557 rows at 120 cols), so this must always be set explicitly.
    public var scrollbackMaxBytes: Int
    /// `GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES`. Must be non-zero **before any bytes are
    /// written** or `ghostty_snapshot_encode_alloc` cannot capture an unfinished sequence.
    public var continuationMaxBytes: Int
    /// `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT`. Small on purpose: we do not render
    /// Kitty graphics in v1, and a large limit is just a memory hole per session.
    public var kittyImageStorageLimit: UInt64
    /// Reported for `CSI > q` (XTVERSION).
    public var xtversion: String
    /// Reported for an XTGETTCAP `TN` query.
    public var terminfoName: String
    public var cursorStyle: CursorStyle
    public var cursorBlink: Bool
    /// Answered to `CSI ? 996 n`.
    public var darkColorScheme: Bool

    public enum CursorStyle: Sendable, Hashable {
        case bar, block, underline, blockHollow

        var raw: GhosttyTerminalCursorStyle {
            switch self {
            case .bar: return GHOSTTY_TERMINAL_CURSOR_STYLE_BAR
            case .block: return GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK
            case .underline: return GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE
            case .blockHollow: return GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW
            }
        }
    }

    public init(
        cols: UInt16 = 120,
        rows: UInt16 = 40,
        cellWidthPx: UInt32 = 0,
        cellHeightPx: UInt32 = 0,
        theme: Theme = .default,
        scrollbackMaxBytes: Int = 24 * 1024 * 1024,
        continuationMaxBytes: Int = 4096,
        kittyImageStorageLimit: UInt64 = 1 * 1024 * 1024,
        xtversion: String = "tkzmux 0.1.0",
        terminfoName: String = "xterm-ghostty",
        cursorStyle: CursorStyle = .block,
        cursorBlink: Bool = true,
        darkColorScheme: Bool = true
    ) {
        self.cols = cols
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.theme = theme
        self.scrollbackMaxBytes = scrollbackMaxBytes
        self.continuationMaxBytes = continuationMaxBytes
        self.kittyImageStorageLimit = kittyImageStorageLimit
        self.xtversion = xtversion
        self.terminfoName = terminfoName
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.darkColorScheme = darkColorScheme
    }
}

// MARK: - DEC 2026 watchdog

/// The DEC 2026 (synchronized output) policy, as a pure value so it can be tested without a VT.
///
/// libghostty-vt does **not** hide unsynchronized frames: with mode 2026 set the render state still
/// reports rows dirty (verified, M1.3). Hiding is the host's job, exactly as in Ghostty's own
/// renderer: skip frames while the mode is set, and force it off if a program leaves it set.
public struct SyncOutputWatchdog: Sendable, Equatable {
    /// How long a program may hold mode 2026 before we stop believing it.
    public var timeout: Duration

    private var activeSince: ContinuousClock.Instant?

    public init(timeout: Duration = .seconds(1)) {
        self.timeout = timeout
        self.activeSince = nil
    }

    public enum Decision: Sendable, Equatable {
        /// Mode 2026 is not set: render normally.
        case render
        /// Mode 2026 has been set for less than `timeout`: skip this frame, keep the link running.
        case skipFrame
        /// Mode 2026 has been held too long: force it off and render.
        case forceOffAndRender
    }

    /// `modeActive` comes from `ghostty_terminal_get(DATA_MODE, ghostty_mode_new(2026, false))`.
    public mutating func evaluate(modeActive: Bool, now: ContinuousClock.Instant) -> Decision {
        guard modeActive else {
            activeSince = nil
            return .render
        }
        guard let since = activeSince else {
            activeSince = now
            return .skipFrame
        }
        if since.duration(to: now) >= timeout {
            activeSince = nil
            return .forceOffAndRender
        }
        return .skipFrame
    }

    /// Test/inspection helper: has the mode been continuously active?
    public var isTracking: Bool { activeSince != nil }
}

// MARK: - IO context (the only thing C callbacks ever see)

/// State that the C effect callbacks append to. Owned by the locked `SessionState`, so it is
/// exclusively accessed while `vt_write` runs. Never touches `TerminalSession` or the `Mutex`.
final class IOContext {
    var pendingPty: [UInt8] = []
    var pendingEvents: [TerminalEvent] = []

    /// XTVERSION must return a `GhosttyString` whose bytes outlive the callback body, so it
    /// cannot be produced from a temporary. Allocated once here, freed in `deinit`.
    private(set) var xtversion: UnsafeMutableBufferPointer<UInt8>

    /// Answered to XTWINOPS / mode 2048 size queries; kept in sync by `resize`.
    var reportedSize: GhosttySizeReportSize

    var colorScheme: GhosttyColorScheme

    init(xtversion versionString: String, size: GhosttySizeReportSize, colorScheme: GhosttyColorScheme) {
        let bytes = Array(versionString.utf8)
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(bytes.count, 1))
        _ = buffer.initialize(fromContentsOf: bytes)
        self.xtversion = UnsafeMutableBufferPointer(rebasing: buffer[0..<bytes.count])
        self.reportedSize = size
        self.colorScheme = colorScheme
        self.allocation = buffer
    }

    private let allocation: UnsafeMutableBufferPointer<UInt8>
    deinit { allocation.deallocate() }
}

/// Resolves the `userdata` pointer every callback receives.
@inline(__always)
private func ioContext(_ userdata: UnsafeMutableRawPointer?) -> IOContext? {
    guard let userdata else { return nil }
    return Unmanaged<IOContext>.fromOpaque(userdata).takeUnretainedValue()
}

@inline(__always)
private func string(_ value: GhosttyString) -> String {
    guard let ptr = value.ptr, value.len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
}

/// Reads a borrowed `GhosttyString` out of the terminal. Valid only until the next mutating call,
/// which is why the result is copied into a Swift `String` immediately.
@inline(__always)
private func terminalString(_ terminal: GhosttyTerminal?, _ data: GhosttyTerminalData) -> String {
    guard let terminal else { return "" }
    var value = GhosttyString()
    guard ghostty_terminal_get(terminal, data, &value) == GHOSTTY_SUCCESS else { return "" }
    return string(value)
}

// MARK: - C callbacks
//
// Every one of these runs inside `ghostty_terminal_vt_write` (or `ghostty_terminal_paste`), i.e.
// with the session lock already held by the caller. They must not block, must not re-enter the
// terminal's VT writer, and must not touch `TerminalSession`.

private func cbWritePty(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?, _ len: Int
) {
    guard let context = ioContext(userdata), let data, len > 0 else { return }
    context.pendingPty.append(contentsOf: UnsafeBufferPointer(start: data, count: len))
}

private func cbBell(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?) {
    ioContext(userdata)?.pendingEvents.append(.bell)
}

private func cbTitleChanged(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?) {
    guard let context = ioContext(userdata) else { return }
    context.pendingEvents.append(.title(terminalString(terminal, GHOSTTY_TERMINAL_DATA_TITLE)))
}

private func cbPwdChanged(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?) {
    guard let context = ioContext(userdata) else { return }
    // terminal.h explicitly says to read DATA_PWD *inside* this callback.
    context.pendingEvents.append(.pwd(terminalString(terminal, GHOSTTY_TERMINAL_DATA_PWD)))
}

private func cbDesktopNotification(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ notification: UnsafePointer<GhosttyTerminalDesktopNotification>?
) {
    guard let context = ioContext(userdata), let notification else { return }
    context.pendingEvents.append(
        .notification(title: string(notification.pointee.title), body: string(notification.pointee.body))
    )
}

private func cbProgressReport(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ report: UnsafePointer<GhosttyTerminalProgressReport>?
) {
    guard let context = ioContext(userdata), let report else { return }
    let state: TerminalProgressState
    switch report.pointee.state {
    case GHOSTTY_TERMINAL_PROGRESS_STATE_SET: state = .set
    case GHOSTTY_TERMINAL_PROGRESS_STATE_ERROR: state = .error
    case GHOSTTY_TERMINAL_PROGRESS_STATE_INDETERMINATE: state = .indeterminate
    case GHOSTTY_TERMINAL_PROGRESS_STATE_PAUSE: state = .pause
    default: state = .remove
    }
    let progress = report.pointee.progress
    context.pendingEvents.append(.progress(state: state, value: progress < 0 ? nil : Int(progress)))
}

private func cbColorScheme(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ outScheme: UnsafeMutablePointer<GhosttyColorScheme>?
) -> Bool {
    guard let context = ioContext(userdata), let outScheme else { return false }
    outScheme.pointee = context.colorScheme
    return true
}

private func cbSize(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ outSize: UnsafeMutablePointer<GhosttySizeReportSize>?
) -> Bool {
    guard let context = ioContext(userdata), let outSize else { return false }
    outSize.pointee = context.reportedSize
    return true
}

private func cbXtversion(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?
) -> GhosttyString {
    guard let context = ioContext(userdata) else { return GhosttyString() }
    var value = GhosttyString()
    value.ptr = UnsafePointer(context.xtversion.baseAddress)
    value.len = context.xtversion.count
    return value
}

private func cbClipboardWrite(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ write: UnsafePointer<GhosttyClipboardWrite>?
) {
    guard let context = ioContext(userdata), let write else { return }
    let request = write.pointee

    var result = GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
    if request.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD {
        if request.contents_len == 0 {
            // A zero-length contents array asks for the destination to be cleared.
            context.pendingEvents.append(.clipboardWrite(""))
            result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
        } else if let contents = request.contents {
            for index in 0..<request.contents_len {
                let entry = contents[index]
                let mime = string(entry.mime)
                guard mime.isEmpty || mime.hasPrefix("text/") else { continue }
                context.pendingEvents.append(.clipboardWrite(string(entry.data)))
                result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
                break
            }
        }
    }

    var reply = GhosttyClipboardWriteReply()
    reply.size = MemoryLayout<GhosttyClipboardWriteReply>.stride  // C sizeof == Swift stride
    reply.result = result
    reply.remember = false
    request.reply?(write, &reply)
}

private func cbClipboardRead(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ read: UnsafePointer<GhosttyClipboardRead>?
) {
    guard let read else { return }
    // Programs never get to read the user's clipboard (docs/design.md → VT bridge: DENIED).
    var reply = GhosttyClipboardReadReply()
    reply.size = MemoryLayout<GhosttyClipboardReadReply>.stride
    reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_DENIED
    read.pointee.reply?(read, &reply)
}

// MARK: - Locked state

/// The terminal handle plus everything that must move under the lock with it.
final class SessionState {
    var terminal: GhosttyTerminalHandle
    let context: IOContext
    var options: TerminalSessionOptions
    var watchdog: SyncOutputWatchdog
    var onWritePty: (@Sendable (Data) -> Void)?
    var renderSignal: (@Sendable () -> Void)?

    init(terminal: GhosttyTerminalHandle, context: IOContext, options: TerminalSessionOptions) {
        self.terminal = terminal
        self.context = context
        self.options = options
        self.watchdog = SyncOutputWatchdog()
    }

    /// Takes everything the callbacks accumulated. Called under the lock, right after `vt_write`.
    func harvest() -> (pty: Data, events: [TerminalEvent]) {
        let pty = context.pendingPty.isEmpty ? Data() : Data(context.pendingPty)
        let events = context.pendingEvents
        context.pendingPty.removeAll(keepingCapacity: true)
        context.pendingEvents.removeAll(keepingCapacity: true)
        return (pty, events)
    }
}

// MARK: - TerminalSession

public final class TerminalSession: Sendable {
    private let state: Mutex<SessionState>
    private let continuation: AsyncStream<TerminalEvent>.Continuation

    /// Events for the app to consume (on the main actor). Buffering is unbounded so nothing that
    /// happened before a consumer attached is dropped.
    public let events: AsyncStream<TerminalEvent>

    /// The serial queue the pty layer should read and write on. Ingestion is synchronous, so this
    /// is a convention for callers rather than something this class dispatches to itself.
    public let ioQueue: DispatchQueue

    public init(options: TerminalSessionOptions = TerminalSessionOptions(), label: String = "tkzmux.session") throws {
        let handle = try GhosttyTerminalHandle(cols: options.cols, rows: options.rows)
        let context = IOContext(
            xtversion: options.xtversion,
            size: GhosttySizeReportSize(
                rows: options.rows, columns: options.cols,
                cell_width: options.cellWidthPx, cell_height: options.cellHeightPx
            ),
            colorScheme: options.darkColorScheme ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        )
        let sessionState = SessionState(terminal: handle, context: context, options: options)
        try TerminalSession.applyOptions(to: sessionState)

        self.state = Mutex(sessionState)
        self.ioQueue = DispatchQueue(label: label, qos: .userInteractive)
        var escapee: AsyncStream<TerminalEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { escapee = $0 }
        self.continuation = escapee
    }

    deinit { continuation.finish() }

    // MARK: Configuration

    /// Installs the sink for bytes the terminal wants written back to the pty (query replies,
    /// mode reports, paste output). Called **outside** the lock, right after a write completes.
    public func setOnWritePty(_ sink: (@Sendable (Data) -> Void)?) {
        state.withLock { $0.onWritePty = sink }
    }

    /// The seam the view layer wires a `DispatchSourceUserDataOr` to in M1.6 (TKZ-12).
    /// Called outside the lock after every non-empty ingestion.
    public func setRenderSignal(_ signal: (@Sendable () -> Void)?) {
        state.withLock { $0.renderSignal = signal }
    }

    /// Applies every option in `state.options` to `state.terminal`. Re-run after `restore(from:)`,
    /// because a snapshot restores grid content only — no callbacks, colors or limits.
    private static func applyOptions(to state: SessionState) throws {
        try applyOptions(terminal: state.terminal.raw, context: state.context, options: state.options)
    }

    /// Applies every option to a bare terminal handle. Split out of the `SessionState` overload so
    /// `restore(from:)` can fully configure a decoded terminal *before* committing it.
    private static func applyOptions(
        terminal: GhosttyTerminal, context: IOContext, options: TerminalSessionOptions
    ) throws {

        func set(_ option: GhosttyTerminalOption, _ value: UnsafeRawPointer?, _ name: String) throws {
            try ghosttyCheck(ghostty_terminal_set(terminal, option, value), "ghostty_terminal_set(\(name))")
        }
        func setCallback(_ option: GhosttyTerminalOption, _ pointer: UnsafeRawPointer, _ name: String) throws {
            try set(option, pointer, name)
        }

        // USERDATA first: every callback below is handed this pointer. It refers to the IOContext,
        // never to TerminalSession — see the file header for why that is load-bearing.
        try set(GHOSTTY_TERMINAL_OPT_USERDATA, UnsafeRawPointer(Unmanaged.passUnretained(context).toOpaque()), "USERDATA")

        // Effects. Function pointers are passed *as* the value (not a pointer to them).
        let writePty: GhosttyTerminalWritePtyFn = cbWritePty
        try setCallback(GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self), "WRITE_PTY")
        let bell: GhosttyTerminalBellFn = cbBell
        try setCallback(GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self), "BELL")
        let titleChanged: GhosttyTerminalTitleChangedFn = cbTitleChanged
        try setCallback(GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(titleChanged, to: UnsafeRawPointer.self), "TITLE_CHANGED")
        let pwdChanged: GhosttyTerminalPwdChangedFn = cbPwdChanged
        try setCallback(GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(pwdChanged, to: UnsafeRawPointer.self), "PWD_CHANGED")
        let clipboardWrite: GhosttyTerminalClipboardWriteFn = cbClipboardWrite
        try setCallback(GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(clipboardWrite, to: UnsafeRawPointer.self), "CLIPBOARD_WRITE")
        let clipboardRead: GhosttyTerminalClipboardReadFn = cbClipboardRead
        try setCallback(GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, unsafeBitCast(clipboardRead, to: UnsafeRawPointer.self), "CLIPBOARD_READ")
        let notification: GhosttyTerminalDesktopNotificationFn = cbDesktopNotification
        try setCallback(GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, unsafeBitCast(notification, to: UnsafeRawPointer.self), "DESKTOP_NOTIFICATION")
        let progress: GhosttyTerminalProgressReportFn = cbProgressReport
        try setCallback(GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, unsafeBitCast(progress, to: UnsafeRawPointer.self), "PROGRESS_REPORT")
        let colorScheme: GhosttyTerminalColorSchemeFn = cbColorScheme
        try setCallback(GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(colorScheme, to: UnsafeRawPointer.self), "COLOR_SCHEME")
        let size: GhosttyTerminalSizeFn = cbSize
        try setCallback(GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self), "SIZE")
        let xtversion: GhosttyTerminalXtversionFn = cbXtversion
        try setCallback(GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(xtversion, to: UnsafeRawPointer.self), "XTVERSION")
        // DEVICE_ATTRIBUTES is deliberately *not* installed: libghostty already answers DA1 with
        // `ESC[?62;22c` and DA2 with `ESC[>1;<version>;0c` on its own (verified M1.3). A callback
        // would only be needed to advertise a different feature set.

        // Values.
        var terminfo = GhosttyString()
        try options.terminfoName.withCString { cString in
            let bytes = UnsafeRawPointer(cString).assumingMemoryBound(to: UInt8.self)
            terminfo.ptr = bytes
            terminfo.len = strlen(cString)
            // The string is copied into the terminal, so a temporary is fine here.
            try set(GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &terminfo, "TERMINFO_NAME")
        }

        var scrollback = options.scrollbackMaxBytes
        try set(GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback, "SCROLLBACK_MAX_BYTES")
        // Snapshot encoding needs continuation tracking enabled *before* any bytes are fed.
        var continuation = options.continuationMaxBytes
        try set(GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation, "CONTINUATION_MAX_BYTES")
        var kittyLimit = options.kittyImageStorageLimit
        try set(GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kittyLimit, "KITTY_IMAGE_STORAGE_LIMIT")
        var cursorStyle = options.cursorStyle.raw
        try set(GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &cursorStyle, "DEFAULT_CURSOR_STYLE")
        var cursorBlink = options.cursorBlink
        try set(GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &cursorBlink, "DEFAULT_CURSOR_BLINK")
        // A program can set a title and read it back into the input stream; keep that off.
        var titleReport = false
        try set(GHOSTTY_TERMINAL_OPT_TITLE_REPORT, &titleReport, "TITLE_REPORT")

        // Colors from the theme. 0…15 come from the design tokens; 16…255 stay Ghostty's defaults.
        var foreground = options.theme.terminalForeground.ghostty
        try set(GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground, "COLOR_FOREGROUND")
        var background = options.theme.terminalBackground.ghostty
        try set(GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background, "COLOR_BACKGROUND")
        var cursor = options.theme.accent.ghostty
        try set(GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor, "COLOR_CURSOR")

        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        palette.withUnsafeMutableBufferPointer { buffer in
            ghostty_color_palette_default(buffer.baseAddress)
        }
        for (index, color) in options.theme.terminalPalette16.enumerated() where index < 16 {
            palette[index] = color.ghostty
        }
        try palette.withUnsafeBufferPointer { buffer in
            try set(GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress, "COLOR_PALETTE")
        }
    }

    // MARK: Ingestion

    /// Feed bytes read from the pty master into the VT parser.
    ///
    /// Synchronous: the caller (the pty read source on `ioQueue`, a test, or `vtdump replay`) owns
    /// the timing. Everything the terminal produced in response is delivered after the lock drops.
    public func write(ptyBytes bytes: Data) {
        guard !bytes.isEmpty else { return }
        let (pty, events, sink, signal) = state.withLock {
            (state: inout SessionState) -> (Data, [TerminalEvent], (@Sendable (Data) -> Void)?, (@Sendable () -> Void)?) in
            bytes.withUnsafeBytes { state.terminal.write($0) }
            let harvest = state.harvest()
            return (harvest.pty, harvest.events, state.onWritePty, state.renderSignal)
        }
        deliver(pty: pty, events: events, sink: sink, signal: signal)
    }

    /// Convenience for tests and `vtdump`.
    public func write(ptyText text: String) { write(ptyBytes: Data(text.utf8)) }

    private func deliver(
        pty: Data, events: [TerminalEvent],
        sink: (@Sendable (Data) -> Void)?, signal: (@Sendable () -> Void)?
    ) {
        if !pty.isEmpty { sink?(pty) }
        for event in events { continuation.yield(event) }
        signal?()
    }

    /// Publishes a child-process exit. The pty layer owns `waitpid`; this only republishes.
    public func noteExit(_ status: ExitStatus) { continuation.yield(.exited(status)) }

    /// Publishes a foreground-process change observed by the pty layer.
    public func noteForeground(pgid: pid_t, path: String?, cwd: String?) {
        continuation.yield(.foreground(pgid: pgid, path: path, cwd: cwd))
    }

    /// Ends the event stream. Call when the session row is removed.
    public func finishEvents() { continuation.finish() }

    // MARK: Geometry

    public func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32? = nil, cellHeightPx: UInt32? = nil) throws {
        let (pty, events, sink, signal) = try state.withLock {
            (state: inout SessionState) -> (Data, [TerminalEvent], (@Sendable (Data) -> Void)?, (@Sendable () -> Void)?) in
            state.options.cols = cols
            state.options.rows = rows
            if let cellWidthPx { state.options.cellWidthPx = cellWidthPx }
            if let cellHeightPx { state.options.cellHeightPx = cellHeightPx }
            try state.terminal.resize(
                cols: cols, rows: rows,
                cellWidthPx: state.options.cellWidthPx, cellHeightPx: state.options.cellHeightPx
            )
            state.context.reportedSize = GhosttySizeReportSize(
                rows: rows, columns: cols,
                cell_width: state.options.cellWidthPx, cell_height: state.options.cellHeightPx
            )
            let harvest = state.harvest()
            return (harvest.pty, harvest.events, state.onWritePty, state.renderSignal)
        }
        deliver(pty: pty, events: events, sink: sink, signal: signal)
    }

    public var size: (cols: UInt16, rows: UInt16) {
        state.withLock { ($0.options.cols, $0.options.rows) }
    }

    // MARK: Queries

    /// Whether a DEC private (or ANSI) mode is currently set.
    public func mode(_ value: UInt16, ansi: Bool = false) -> Bool {
        state.withLock { state in
            var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
            guard ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS
            else { return false }
            return config.value
        }
    }

    /// `GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS` — the current kitty keyboard protocol flags.
    public var kittyKeyboardFlags: UInt8 {
        state.withLock { state in
            var flags: UInt8 = 0
            _ = ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
            return flags
        }
    }

    /// True when any mouse tracking mode (X10 / normal / button / any) is active.
    public var mouseTrackingEnabled: Bool {
        state.withLock { state in
            var tracking = false
            _ = ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
            return tracking
        }
    }

    public var title: String {
        state.withLock { terminalString($0.terminal.raw, GHOSTTY_TERMINAL_DATA_TITLE) }
    }

    public var pwd: String {
        state.withLock { terminalString($0.terminal.raw, GHOSTTY_TERMINAL_DATA_PWD) }
    }

    public var scrollbackRows: Int {
        state.withLock { state in
            var rows = 0
            _ = ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &rows)
            return rows
        }
    }

    /// The active screen through libghostty's formatter. `PLAIN` is the golden-screen format.
    public func formatted(
        _ format: GhosttyFormatterFormat = GHOSTTY_FORMATTER_FORMAT_PLAIN,
        trim: Bool = true,
        unwrap: Bool = false
    ) throws -> String {
        try state.withLock { try $0.terminal.formatted(format, trim: trim, unwrap: unwrap) }
    }

    // MARK: DEC 2026

    /// One render-tick decision. Reads mode 2026 under the lock, runs the watchdog, and forces the
    /// mode off when a program has held it past the timeout.
    ///
    /// - Parameter now: injected so the policy is testable; pass `ContinuousClock.now` in the app.
    @discardableResult
    public func syncOutputDecision(now: ContinuousClock.Instant = ContinuousClock.now) -> SyncOutputWatchdog.Decision {
        state.withLock { state in
            var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
            let active = ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS
                && config.value
            let decision = state.watchdog.evaluate(modeActive: active, now: now)
            if decision == .forceOffAndRender {
                var off = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
                _ = ghostty_terminal_set(state.terminal.raw, GHOSTTY_TERMINAL_OPT_MODE, &off)
            }
            return decision
        }
    }

    /// The watchdog timeout, for the app's settings (default 1 s, matching Ghostty).
    public var syncOutputTimeout: Duration {
        get { state.withLock { $0.watchdog.timeout } }
        set { state.withLock { $0.watchdog.timeout = newValue } }
    }

    // MARK: Snapshot

    /// Encodes the whole terminal (screens, scrollback, modes, unfinished VT continuation) into a
    /// `.ghsnap` blob. Requires `continuationMaxBytes > 0`, which `applyOptions` guarantees.
    public func snapshot() throws -> Data {
        try state.withLock { state in
            var buffer: UnsafeMutablePointer<UInt8>?
            var length = 0
            try ghosttyCheck(
                ghostty_snapshot_encode_alloc(state.terminal.raw, nil, &buffer, &length),
                "ghostty_snapshot_encode_alloc"
            )
            guard let buffer else { return Data() }
            defer { ghostty_free(nil, buffer, length) }
            return Data(UnsafeBufferPointer(start: buffer, count: length))
        }
    }

    /// Replaces the terminal with one decoded from a snapshot, then re-applies every option.
    ///
    /// A snapshot carries grid content and terminal modes but **not** callbacks, userdata, colors
    /// or limits — those are host configuration — so `applyOptions` must run again on the new
    /// handle. The `IOContext` (and therefore the userdata pointer) is unchanged.
    public func restore(from data: Data) throws {
        try state.withLock { (state: inout SessionState) in
            // `ghostty_snapshot_decoder_new_buf` BORROWS the bytes ("The bytes are not copied.
            // ptr must remain valid and immutable until FINISH is reached or the decoder is
            // freed" — snapshot.h), so the whole decode happens inside this one `withUnsafeBytes`.
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, !raw.isEmpty else {
                    throw GhosttyError(result: GHOSTTY_INVALID_VALUE, operation: "ghostty_snapshot_decoder_new_buf")
                }
                var decoder: GhosttySnapshotDecoder?
                try ghosttyCheck(
                    ghostty_snapshot_decoder_new_buf(
                        nil, &decoder, base.assumingMemoryBound(to: UInt8.self), raw.count
                    ),
                    "ghostty_snapshot_decoder_new_buf"
                )
                guard let decoder else {
                    throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_snapshot_decoder_new_buf")
                }
                defer { ghostty_snapshot_decoder_free(decoder) }

                // READY hands back a validated, renderable terminal before the old history is
                // decoded; the remaining history pages stream in with `next`.
                var decoded: GhosttyTerminal?
                try ghosttyCheck(ghostty_snapshot_decoder_ready(decoder, &decoded), "ghostty_snapshot_decoder_ready")
                guard let decoded else {
                    throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_snapshot_decoder_ready")
                }
                // Own it immediately so no path below can leak it.
                let restored = GhosttyTerminalHandle(adopting: decoded)

                // Configure *before* committing: if this throws, the session keeps its old,
                // fully configured terminal and `restored` is freed by ARC.
                try TerminalSession.applyOptions(
                    terminal: restored.raw, context: state.context, options: state.options
                )
                while ghostty_snapshot_decoder_next(decoder) == GHOSTTY_SUCCESS {}

                state.terminal = restored
            }

            var cols: UInt16 = 0, rows: UInt16 = 0
            _ = ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            _ = ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            if cols > 0, rows > 0 {
                state.options.cols = cols
                state.options.rows = rows
                state.context.reportedSize = GhosttySizeReportSize(
                    rows: rows, columns: cols,
                    cell_width: state.options.cellWidthPx, cell_height: state.options.cellHeightPx
                )
            }
            _ = state.harvest()  // options are applied silently; nothing to publish
        }
    }

    /// Compress eligible scrollback (idle-timer work; see docs/design.md → Threading).
    /// Not thread-safe against anything else, hence the lock.
    /// Returns `true` when more incremental work remains (`PENDING`), i.e. the idle timer should
    /// call again; `false` on `COMPLETE`, `UNSUPPORTED`, or an error.
    @discardableResult
    public func compress(full: Bool = false) -> Bool {
        state.withLock { state in
            var result = GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED
            let mode = full ? GHOSTTY_TERMINAL_COMPRESSION_MODE_FULL : GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL
            guard ghostty_terminal_compress(state.terminal.raw, mode, &result) == GHOSTTY_SUCCESS else { return false }
            return result == GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING
        }
    }

    // MARK: Render seam

    /// Runs `body` with exclusive access to the terminal handle.
    ///
    /// This is how `TerminalSurface` (M1.5) calls `ghostty_render_state_begin_update` — and *only*
    /// begin_update: `end_update` and row/cell iteration touch render-state memory only and must
    /// happen outside this closure so the IO thread is not blocked (verified M1.3, render.h).
    /// `body` must not call back into `TerminalSession`.
    package func withTerminal<T: Sendable>(_ body: (GhosttyTerminal) throws -> T) rethrows -> T {
        try state.withLock { (state: inout SessionState) in
            let terminal = state.terminal.raw
            return try body(terminal)
        }
    }
}

// MARK: - Theme bridging

extension RGB {
    /// The opaque 8-bit sRGB triple libghostty wants. Alpha is dropped (terminal colors are opaque).
    var ghostty: GhosttyColorRgb {
        let (r, g, b) = bytes
        return GhosttyColorRgb(r: r, g: g, b: b)
    }
}
