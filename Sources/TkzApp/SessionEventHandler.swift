// SessionEventHandler — M1.9 (TKZ-15): the app-level meaning of a `TerminalEvent`.
//
// `TerminalSession` produces events; this type decides what they *mean* to the application:
// which ones become published state a window binds to, which one becomes a macOS user
// notification, and which one becomes a visible (never audible) alert.
//
// ## Why it does not own the stream
//
// `TerminalSession.events` is an `AsyncStream`, which is **single-consumer**: a second
// `for await` loop over the same stream steals events from the first one rather than
// mirroring them. `DevWindowController` (and M2's real `TerminalHost`) already drains the
// stream, so this type deliberately exposes a synchronous `handle(_:)` that the existing
// loop calls. Wiring is one line at the call site; see `docs/design.md` → *TerminalHost*.
//
// ## Why the notification centre is behind a protocol
//
// `UNUserNotificationCenter.current()` **traps** in a process with no bundle identifier
// (`swift run tkzmux`, `swift test`), so it must not be touched unconditionally.
// `SystemNotificationPresenter` checks `Bundle.main.bundleIdentifier` before it ever names
// the class, and tests inject a fake presenter and never reach UserNotifications at all.

import AppKit
import Foundation
import TkzCore
import TkzTerminalCore
import UserNotifications
import os

// MARK: - Published state

/// Everything a window needs to render *about* a session, as opposed to its grid contents.
///
/// A plain value type on purpose: `CLAUDE.md` rules out `@Observable` for app state, so a
/// consumer subscribes with `onChange` and diffs (or just re-reads) whatever it cares about.
public struct SessionUIState: Equatable, Sendable {
    /// The last OSC 0 / OSC 2 title, or `nil` when the program never set one (or cleared it).
    public var title: String?

    /// The last OSC 7 / OSC 9 / OSC 1337 working directory, **already decoded** to a plain
    /// filesystem path. `TerminalEvent.pwd` carries the raw bytes the shell emitted, which for
    /// OSC 7 is a `file://host/path` URI; decoding is documented as the consumer's job.
    public var pwd: String?

    /// The raw, undecoded pwd payload, kept so a caller can tell `file://` from a bare path.
    public var rawPwd: String?

    /// How many bells arrived. A counter rather than a flag so a consumer can flash once per
    /// bell even when two arrive inside one frame.
    public var bellCount: Int = 0

    /// The most recent OSC 9;4 progress report, or `nil` before any (or after `.remove`).
    public var progress: SessionProgress?

    /// Set once the child process ends; `nil` while the session is alive.
    public var exit: ExitStatus?

    /// True until `.exited` arrives.
    public var isAlive: Bool { exit == nil }

    public init() {}
}

/// An OSC 9;4 progress report, kept as published state.
public struct SessionProgress: Equatable, Sendable {
    public var state: TerminalProgressState
    /// 0…100, or `nil` when the program omitted the percentage.
    public var value: Int?

    public init(state: TerminalProgressState, value: Int?) {
        self.state = state
        self.value = value
    }
}

// MARK: - Seams

/// Where a desktop notification actually goes. Production uses `SystemNotificationPresenter`;
/// tests use a recording fake, which is why this exists at all.
@MainActor
public protocol NotificationPresenting: AnyObject {
    /// Deliver a notification. Implementations must degrade silently — a denied authorization,
    /// or no bundle at all, is a normal condition and never an error the app surfaces.
    func present(title: String, body: String, identifier: String)
}

/// Where the app puts text a program wrote with OSC 52 / OSC 1337 / OSC 5522.
@MainActor
public protocol PasteboardWriting: AnyObject {
    func writeString(_ string: String)
}

/// `NSPasteboard.general`.
@MainActor
public final class SystemPasteboardWriter: PasteboardWriting {
    public init() {}

    public func writeString(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// `UNUserNotificationCenter`, guarded so it is never *named* outside an app bundle.
///
/// `UNUserNotificationCenter.current()` raises an `NSInternalInconsistencyException` when the
/// process has no bundle identifier, which is exactly the `swift run tkzmux` / `swift test`
/// case. Every entry point therefore checks `isAvailable` first; when it is false the presenter
/// logs once and drops the notification instead of crashing.
/// It is also the centre's **delegate**: without `willPresent`, macOS silently drops a
/// notification posted while tkzmux is the *active application* — which includes the case this
/// whole feature exists for (the app is frontmost but its window is minimized or occluded).
@MainActor
public final class SystemNotificationPresenter:
    NSObject, NotificationPresenting, UNUserNotificationCenterDelegate
{
    private let logger = Logger(subsystem: "se.tkz.tkzmux", category: "notifications")
    private var authorization: Authorization = .unknown
    private var loggedUnavailable = false
    private var installedDelegate = false

    private enum Authorization {
        case unknown, requesting, granted, denied
    }

    /// True only inside a real `.app` (or any process with a bundle identifier).
    public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    public override init() { super.init() }

    /// `UNUserNotificationCenter.current()`, with our delegate installed the first time it is
    /// reached. Only ever called behind the `isAvailable` guard.
    private func center() -> UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        if !installedDelegate {
            installedDelegate = true
            center.delegate = self
        }
        return center
    }

    /// Show the banner even when tkzmux is the frontmost app. Without this, an OSC 9 that
    /// arrives while the app is active but its window is minimized or occluded is dropped by
    /// the system and the user sees nothing.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    public func present(title: String, body: String, identifier: String) {
        guard SystemNotificationPresenter.isAvailable else {
            if !loggedUnavailable {
                loggedUnavailable = true
                logger.info("no bundle identifier — desktop notifications disabled for this process")
            }
            return
        }
        switch authorization {
        case .granted:
            deliver(title: title, body: body, identifier: identifier)
        case .denied, .requesting:
            return
        case .unknown:
            authorization = .requesting
            let center = center()
            Task { @MainActor [weak self] in
                let granted = await SystemNotificationPresenter.authorize(center)
                guard let self else { return }
                self.authorization = granted ? .granted : .denied
                if granted { self.deliver(title: title, body: body, identifier: identifier) }
            }
        }
    }

    /// Asks once, lazily. A `.notDetermined` status becomes a real prompt; anything else is
    /// answered from the existing settings without bothering the user again.
    private static func authorize(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    private func deliver(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center().add(request) { [logger] error in
            if let error {
                logger.error("notification failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

// MARK: - SessionEventHandler

/// Turns one session's `TerminalEvent`s into app-level behaviour and published state.
///
/// Deliberately knows nothing about `DevWindowController`, `NSWindow` or the sidebar: the two
/// things it needs from the UI — "is the user looking at this?" and "flash something" — are
/// injected closures.
@MainActor
public final class SessionEventHandler {
    /// The session this handler speaks for. Used as the notification identifier prefix so two
    /// sessions cannot coalesce each other's notifications.
    public let sessionID: String

    /// Current published state. Read it after `onChange` fires, or poll it.
    public private(set) var state = SessionUIState()

    /// Called on the main actor after `state` changed, with the new value.
    public var onChange: (@MainActor (SessionUIState) -> Void)?

    /// A **visible** bell: the app flashes something rather than beeping.
    ///
    /// Default is `NSApp.requestUserAttention(.informationalRequest)` — it bounces the Dock icon
    /// when the app is in the background and does nothing intrusive when it is not. A window can
    /// replace it with a screen flash. Audible bells are deliberately not the default; a caller
    /// that wants `NSSound.beep()` has to ask for it.
    public var onBell: (@MainActor () -> Void)?

    /// Whether the user can currently see this session. Notifications are suppressed while true.
    ///
    /// The default treats "app active **and** its key window on screen and unoccluded" as visible,
    /// which is the condition the ticket asks for ("only when the window is not key/visible").
    public var isSessionVisible: @MainActor () -> Bool = SessionEventHandler.defaultVisibility

    private let notifications: any NotificationPresenting
    private let pasteboard: any PasteboardWriting
    private var notificationCounter = 0

    public init(
        sessionID: String,
        notifications: any NotificationPresenting = SystemNotificationPresenter(),
        pasteboard: any PasteboardWriting = SystemPasteboardWriter()
    ) {
        self.sessionID = sessionID
        self.notifications = notifications
        self.pasteboard = pasteboard
    }

    /// The single entry point. Call it from whatever loop already drains
    /// `TerminalSession.events`; it must not start a second consumer of that stream.
    public func handle(_ event: TerminalEvent) {
        var next = state
        switch event {
        case .title(let title):
            next.title = title.isEmpty ? nil : title

        case .pwd(let raw):
            next.rawPwd = raw.isEmpty ? nil : raw
            next.pwd = SessionEventHandler.decodePwd(raw)

        case .bell:
            next.bellCount += 1
            (onBell ?? SessionEventHandler.defaultBell)()

        case .notification(let title, let body):
            postNotification(title: title, body: body)

        case .progress(let progressState, let value):
            next.progress = progressState == .remove
                ? nil
                : SessionProgress(state: progressState, value: value)

        case .exited(let status):
            next.exit = status

        case .clipboardWrite(let text):
            pasteboard.writeString(text)

        case .foreground:
            break
        }
        commit(next)
    }

    /// Drains a stream into this handler. Only for a caller that does **not** already consume
    /// `session.events` itself — `DevWindowController` does, so it must call `handle(_:)`.
    public func consume(_ events: AsyncStream<TerminalEvent>) async {
        for await event in events { handle(event) }
    }

    private func commit(_ next: SessionUIState) {
        guard next != state else { return }
        state = next
        onChange?(state)
    }

    private func postNotification(title: String, body: String) {
        guard !isSessionVisible() else { return }
        notificationCounter += 1
        let shown = title.isEmpty ? (state.title ?? "tkzmux") : title
        notifications.present(
            title: shown, body: body, identifier: "\(sessionID).\(notificationCounter)")
    }

    // MARK: Defaults

    /// "The user is looking at this app" — active *and* a key window that is on screen and not
    /// covered. `NSApp.isActive` alone is not enough: a fully occluded key window still counts as
    /// active, and the whole point of an OSC 9 notification is to reach a hidden window.
    private static func defaultVisibility() -> Bool {
        guard NSApp?.isActive == true, let window = NSApp.keyWindow else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    private static func defaultBell() {
        NSApp?.requestUserAttention(.informationalRequest)
    }

    // MARK: pwd decoding

    /// Decodes what `TerminalEvent.pwd` carries into a plain path.
    ///
    /// OSC 7 sends `file://<host>/<percent-encoded path>`; OSC 9 and OSC 1337 CurrentDir send a
    /// bare path. Returns `nil` for an empty payload (the shell clearing the pwd) and for a
    /// `file://` URI naming some *other* host, which is not a path on this machine.
    /// Names that mean "this machine" in an OSC 7 URI. Resolved once: `hostName` can block on
    /// reverse DNS, and OSC 7 fires on every `cd` once shell integration lands (M3).
    ///
    /// Deliberately strict — a host this set does not know decodes to `nil`, and only
    /// `SessionUIState.rawPwd` survives. `$HOST` drifting from `ProcessInfo.hostName` (a network
    /// rename) is the way that happens in practice.
    private nonisolated static let localHostNames: Set<String> = {
        var names: Set<String> = ["localhost", "127.0.0.1", "::1"]
        names.insert(ProcessInfo.processInfo.hostName.lowercased())
        if let local = Host.current().localizedName { names.insert(local.lowercased()) }
        for name in Host.current().names { names.insert(name.lowercased()) }
        return names
    }()

    public nonisolated static func decodePwd(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        guard raw.hasPrefix("file://") else { return raw }
        guard let components = URLComponents(string: raw) else { return nil }
        let host = components.host ?? ""
        if !host.isEmpty, !localHostNames.contains(host.lowercased()) { return nil }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        return path.isEmpty ? nil : path
    }
}
