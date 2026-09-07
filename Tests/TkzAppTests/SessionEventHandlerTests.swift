// SessionEventHandlerTests — M1.9 (TKZ-15).
//
// The acceptance criterion `printf '\e]0;hello\a'` → `.title("hello")` is asserted end to end
// against a real `TerminalSession`: the OSC bytes go through libghostty's parser, out of the
// session's `AsyncStream`, and into `SessionEventHandler`. No GUI, no pty.

import Foundation
import TkzCore
import TkzTerminalCore
import Testing

@testable import TkzApp

/// Records what would have been shown, so a test never touches `UNUserNotificationCenter`
/// (which traps in a process with no bundle identifier — i.e. under `swift test`).
@MainActor
private final class FakeNotifications: NotificationPresenting {
    struct Posted: Equatable {
        var title: String
        var body: String
        var identifier: String
    }
    var posted: [Posted] = []

    func present(title: String, body: String, identifier: String) {
        posted.append(Posted(title: title, body: body, identifier: identifier))
    }
}

@MainActor
private final class FakePasteboard: PasteboardWriting {
    var written: [String] = []
    func writeString(_ string: String) { written.append(string) }
}

@MainActor
private func makeHandler(
    visible: Bool = false
) -> (SessionEventHandler, FakeNotifications, FakePasteboard) {
    let notifications = FakeNotifications()
    let pasteboard = FakePasteboard()
    let handler = SessionEventHandler(
        sessionID: "s1", notifications: notifications, pasteboard: pasteboard)
    handler.isSessionVisible = { visible }
    handler.onBell = {}  // never bounce the Dock icon from a test
    return (handler, notifications, pasteboard)
}

/// Feeds `text` to a fresh session and returns everything the VT produced, in order.
///
/// `TerminalSession.events` buffers unboundedly, so nothing emitted before this attaches is
/// lost, and `finishEvents()` ends the stream so the `for await` below terminates.
private func events(for text: String) async throws -> [TerminalEvent] {
    let session = try TerminalSession(options: TerminalSessionOptions(), label: "test.events")
    session.write(ptyText: text)
    session.finishEvents()
    var collected: [TerminalEvent] = []
    for await event in session.events { collected.append(event) }
    return collected
}

// MARK: - The acceptance criterion

@Test @MainActor func osc0SetsTheTitle() async throws {
    // Exactly what `printf '\e]0;hello\a'` puts on the pty.
    let produced = try await events(for: "\u{1B}]0;hello\u{07}")
    #expect(produced == [.title("hello")])

    let (handler, _, _) = makeHandler()
    for event in produced { handler.handle(event) }
    #expect(handler.state.title == "hello")
}

@Test @MainActor func osc2AlsoSetsTheTitle() async throws {
    // `printf '\e]2;window title\e\\'` — OSC 2 terminated by ST rather than BEL.
    let produced = try await events(for: "\u{1B}]2;window title\u{1B}\\")
    #expect(produced == [.title("window title")])
}

@Test @MainActor func emptyTitleClearsPublishedState() {
    let (handler, _, _) = makeHandler()
    handler.handle(.title("hello"))
    handler.handle(.title(""))
    #expect(handler.state.title == nil)
}

// MARK: - Notifications

@Test @MainActor func notificationIsPostedWhenTheWindowIsNotVisible() {
    let (handler, notifications, _) = makeHandler(visible: false)
    handler.handle(.notification(title: "Claude", body: "needs your input"))
    #expect(notifications.posted == [
        .init(title: "Claude", body: "needs your input", identifier: "s1.1")
    ])
}

@Test @MainActor func notificationIsSuppressedWhileTheSessionIsVisible() {
    let (handler, notifications, _) = makeHandler(visible: true)
    handler.handle(.notification(title: "Claude", body: "needs your input"))
    #expect(notifications.posted.isEmpty)
}

@Test @MainActor func notificationWithoutATitleFallsBackToTheSessionTitle() {
    let (handler, notifications, _) = makeHandler(visible: false)
    handler.handle(.title("claude — tkzmux"))
    handler.handle(.notification(title: "", body: "build finished"))
    #expect(notifications.posted.first?.title == "claude — tkzmux")
}

@Test @MainActor func notificationIdentifiersAreUniquePerSession() {
    let (handler, notifications, _) = makeHandler(visible: false)
    handler.handle(.notification(title: "a", body: "1"))
    handler.handle(.notification(title: "b", body: "2"))
    #expect(notifications.posted.map(\.identifier) == ["s1.1", "s1.2"])
}

@Test @MainActor func osc9ProducesANotificationEvent() async throws {
    // `printf '\e]9;hello from the shell\e\\'`
    let produced = try await events(for: "\u{1B}]9;hello from the shell\u{1B}\\")
    #expect(produced == [.notification(title: "", body: "hello from the shell")])
}

// MARK: - The rest of the event surface

@Test @MainActor func bellIsCountedAndSignalledVisibly() async throws {
    let produced = try await events(for: "\u{07}\u{07}")
    #expect(produced == [.bell, .bell])

    let (handler, _, _) = makeHandler()
    var flashes = 0
    handler.onBell = { flashes += 1 }
    for event in produced { handler.handle(event) }
    #expect(handler.state.bellCount == 2)
    #expect(flashes == 2)
}

@Test @MainActor func progressIsPublishedAndClearedByRemove() {
    let (handler, _, _) = makeHandler()
    handler.handle(.progress(state: .set, value: 42))
    #expect(handler.state.progress == SessionProgress(state: .set, value: 42))
    handler.handle(.progress(state: .indeterminate, value: nil))
    #expect(handler.state.progress == SessionProgress(state: .indeterminate, value: nil))
    handler.handle(.progress(state: .remove, value: nil))
    #expect(handler.state.progress == nil)
}

@Test @MainActor func osc94ProducesAProgressEvent() async throws {
    // `printf '\e]9;4;1;70\e\\'` — state 1 (set), 70 %.
    let produced = try await events(for: "\u{1B}]9;4;1;70\u{1B}\\")
    #expect(produced == [.progress(state: .set, value: 70)])
}

@Test @MainActor func exitIsPublishedAndEndsLiveness() {
    let (handler, _, _) = makeHandler()
    #expect(handler.state.isAlive)
    handler.handle(.exited(.exited(code: 3)))
    #expect(handler.state.exit == .exited(code: 3))
    #expect(!handler.state.isAlive)
}

@Test @MainActor func clipboardWriteGoesToThePasteboardSeam() {
    let (handler, _, pasteboard) = makeHandler()
    handler.handle(.clipboardWrite("copied"))
    #expect(pasteboard.written == ["copied"])
    // Clipboard writes are an effect, not state: nothing observable changed.
    #expect(handler.state == SessionUIState())
}

@Test @MainActor func onChangeFiresOnlyWhenStateActuallyChanges() {
    let (handler, _, _) = makeHandler()
    var changes = 0
    handler.onChange = { _ in changes += 1 }
    handler.handle(.title("a"))
    handler.handle(.title("a"))       // same value → no callback
    handler.handle(.foreground(pgid: 42, path: nil, cwd: nil))  // not published state
    handler.handle(.title("b"))
    #expect(changes == 2)
}

// MARK: - pwd decoding

@Test func pwdDecodingHandlesBothProtocols() {
    // OSC 7 sends a file:// URI; OSC 9 / OSC 1337 send a bare path.
    #expect(SessionEventHandler.decodePwd("/Users/x/dev/tkzmux") == "/Users/x/dev/tkzmux")
    #expect(SessionEventHandler.decodePwd("file:///Users/x/dev/tkzmux") == "/Users/x/dev/tkzmux")
    #expect(SessionEventHandler.decodePwd("file://localhost/Users/x/a%20b") == "/Users/x/a b")
    #expect(SessionEventHandler.decodePwd("") == nil)
    // A URI naming another machine is not a path here.
    #expect(SessionEventHandler.decodePwd("file://elsewhere.local/Users/x") == nil)
}

@Test @MainActor func osc7SetsBothRawAndDecodedPwd() async throws {
    let produced = try await events(for: "\u{1B}]7;file://localhost/tmp/a%20b\u{1B}\\")
    #expect(produced == [.pwd("file://localhost/tmp/a%20b")])

    let (handler, _, _) = makeHandler()
    for event in produced { handler.handle(event) }
    #expect(handler.state.rawPwd == "file://localhost/tmp/a%20b")
    #expect(handler.state.pwd == "/tmp/a b")
}

// MARK: - Stream draining

@Test @MainActor func consumeDrainsAWholeStream() async throws {
    let session = try TerminalSession(options: TerminalSessionOptions(), label: "test.consume")
    let (handler, _, _) = makeHandler()
    session.write(ptyText: "\u{1B}]0;first\u{07}\u{1B}]0;second\u{07}")
    session.finishEvents()
    await handler.consume(session.events)
    #expect(handler.state.title == "second")
}
