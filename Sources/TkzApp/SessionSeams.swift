// SessionSeams — the two OS surfaces the app writes to, each behind a protocol so tests never
// reach the real one: the notification centre and the pasteboard.
//
// These began as part of `SessionEventHandler` (M1.9), a type that turned a whole `TerminalEvent`
// stream into published state and notifications. The app never adopted it: `MainWindowController`
// drains the stream itself and `AttentionNotifier` owns "this row needs you, post a banner",
// reusing the seams below. That left the handler, `SessionUIState` and `SessionProgress` as 250
// lines of tested code nothing called, and a standing invitation to wire the wrong thing, so they
// are gone. Its one surviving user, the OSC 7 path decoder, is now `PwdDecoder`.
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

// MARK: - Seams

/// One desktop notification, as the app describes it before `UserNotifications` gets involved.
public struct NotificationRequest: Equatable, Sendable {
    /// Stable per subject: posting the same identifier again *replaces* the earlier banner.
    public var identifier: String
    public var title: String
    public var body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

/// Where a desktop notification actually goes. Production uses `SystemNotificationPresenter`;
/// tests use a recording fake, which is why this exists at all.
@MainActor
public protocol NotificationPresenting: AnyObject {
    /// Deliver a notification, with the system's default notification sound. Implementations
    /// must degrade silently — a denied authorization, or no bundle at all, is a normal condition
    /// and never an error the app surfaces. `delivered` says whether macOS took it; it is called
    /// once, on the main actor, possibly after an authorization round trip — or never, if the
    /// request was dismissed while that round trip was still out.
    func present(_ request: NotificationRequest, delivered: @escaping @MainActor (Bool) -> Void)
    /// Take a delivered (or still pending) notification back — the subject was dealt with.
    func dismiss(identifier: String)
    /// Ask macOS now rather than at the first `present`, so the permission dialog lands at a
    /// predictable moment (launch, or the switch turning on). A no-op once granted.
    func requestAuthorization()
    /// The user clicked a banner: called on the main actor with that notification's identifier.
    var onActivate: (@MainActor (String) -> Void)? { get set }
    /// macOS refused (System Settings → Notifications has tkzmux off). Called on the main actor
    /// each time a request finds that out, so the app can say so instead of staying silent.
    var onDenied: (@MainActor () -> Void)? { get set }
}

extension NotificationPresenting {
    /// The M1.9 shape, kept for OSC 9: fire and forget.
    public func present(title: String, body: String, identifier: String) {
        present(NotificationRequest(identifier: identifier, title: title, body: body)) { _ in }
    }
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
    /// Requests that arrived while the authorization round trip was in flight. Flushed on the
    /// answer: delivered on a grant, `delivered(false)` on a denial — never silently dropped.
    private var queued: [(NotificationRequest, @MainActor (Bool) -> Void)] = []

    public var onActivate: (@MainActor (String) -> Void)?
    public var onDenied: (@MainActor () -> Void)?

    /// No `denied` case on purpose: a refusal is re-checked on the next request, so turning
    /// tkzmux on in System Settings takes effect without a relaunch (2026-09-15: a process that
    /// had cached "denied" at launch stayed silent for its whole life).
    private enum Authorization {
        case unknown, requesting, granted
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
    /// the system and the user sees nothing. `.sound` for the same reason: without it the ping a
    /// NEEDS YOU request carries is muted whenever tkzmux is active — which is exactly when a
    /// *different* row than the one being typed into lights up.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// The user clicked the banner (not a dismiss, not an action button): hand the identifier
    /// back on the main actor. The response object is not `Sendable`, so only its identifier
    /// crosses.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let identifier = response.notification.request.identifier
        await MainActor.run { self.onActivate?(identifier) }
    }

    public func requestAuthorization() {
        guard SystemNotificationPresenter.isAvailable, authorization == .unknown else { return }
        beginAuthorization()
    }

    public func present(
        _ request: NotificationRequest, delivered: @escaping @MainActor (Bool) -> Void
    ) {
        guard SystemNotificationPresenter.isAvailable else {
            if !loggedUnavailable {
                loggedUnavailable = true
                logger.info("no bundle identifier — desktop notifications disabled for this process")
            }
            delivered(false)
            return
        }
        switch authorization {
        case .granted:
            deliver(request, delivered: delivered)
        case .requesting:
            queued.append((request, delivered))
        case .unknown:
            queued.append((request, delivered))
            beginAuthorization()
        }
    }

    public func dismiss(identifier: String) {
        // A subject dealt with while the authorization round trip is still out must not surface
        // as a stale banner when the answer lands. Dropped without a `delivered` call: the caller
        // asked for it to go away, so neither the banner nor the fallback ping is wanted.
        queued.removeAll { $0.0.identifier == identifier }
        guard SystemNotificationPresenter.isAvailable else { return }
        let center = center()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// One round trip, then every queued request gets its answer.
    private func beginAuthorization() {
        authorization = .requesting
        let center = center()
        Task { @MainActor [weak self, logger] in
            let granted = await SystemNotificationPresenter.authorize(center, logger: logger)
            guard let self else { return }
            self.authorization = granted ? .granted : .unknown
            let queued = self.queued
            self.queued = []
            for (request, delivered) in queued {
                if granted { self.deliver(request, delivered: delivered) } else { delivered(false) }
            }
            if !granted { self.onDenied?() }
        }
    }

    /// Asks once, lazily. A `.notDetermined` status becomes a real prompt; anything else is
    /// answered from the existing settings without bothering the user again. Every outcome is
    /// logged: a request that macOS never answers (seen 2026-09-15 with an ad-hoc build under a
    /// bundle id the system already knew as a Developer ID app) is invisible otherwise.
    private static func authorize(_ center: UNUserNotificationCenter, logger: Logger) async -> Bool {
        let settings = await center.notificationSettings()
        // `.notice`, not `.info`: `log show` hides info-level lines unless asked, and this is the
        // one line that explains a silent app ("denied" = System Settings → Notifications).
        logger.notice("notification settings: \(Self.describe(settings.authorizationStatus), privacy: .public)")
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                logger.notice("notification authorization: \(granted ? "granted" : "refused", privacy: .public)")
                return granted
            } catch {
                logger.error("notification authorization failed: \(String(describing: error), privacy: .public)")
                return false
            }
        case .denied:
            logger.notice("notifications are off for tkzmux in System Settings; nothing is posted until they are on")
            return false
        default:
            return true
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func deliver(
        _ request: NotificationRequest, delivered: @escaping @MainActor (Bool) -> Void
    ) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        // The system's own notification sound — the one every other app's banner makes. Whether
        // it plays at all is macOS's per-app setting, not ours.
        content.sound = .default
        let system = UNNotificationRequest(
            identifier: request.identifier, content: content, trigger: nil)
        center().add(system) { [logger] error in
            // The completion runs on the centre's own queue; `delivered` is main-actor by contract.
            let accepted = error == nil
            if let error {
                logger.error("notification failed: \(String(describing: error), privacy: .public)")
            }
            Task { @MainActor in delivered(accepted) }
        }
    }
}

