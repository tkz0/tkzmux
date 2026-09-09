import AppKit
import Testing
import TkzCore
@testable import TkzApp

/// The M4.2 half of the status strip (TKZ-27): the segments the git/PR/port services fill in, and
/// the pointer behaviour that goes with them — tooltips, the pointing-hand cursor and clicks.
///
/// Content still goes through the pure `StatusBarView.items(for:theme:)`; interaction goes through
/// `placement()`, which is the same layout `draw` paints, so a test asserts what the pointer would
/// actually hit rather than a second derivation of it.
@MainActor
struct StatusBarInteractionTests {

    static func items(_ model: StatusBarModel, _ theme: Theme = .default) -> [StatusItem] {
        StatusBarView.items(for: model, theme: theme)
    }

    /// A view laid out wide enough that nothing truncates, inside a window so point conversion is
    /// defined.
    static func laidOut(_ model: StatusBarModel, width: CGFloat = 1_200) -> StatusBarView {
        _ = NSApplication.shared
        let view = StatusBarView(theme: .default, model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: StatusBarView.height),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: width, height: StatusBarView.height)
        return view
    }

    // MARK: Upstream

    @Test func noUpstreamDrawsDimmedDashesRatherThanZeroes() throws {
        // `↑0 ↓0` would claim the branch is in sync with a remote it does not have, and drawing
        // nothing would read as "not measured yet". design.md: "no upstream → shown dimmed".
        let model = StatusBarModel(branch: "spike", upstreamMissing: true)
        let items = Self.items(model)
        let sync = try #require(items.first { $0.segment.plainText.contains("\u{2191}") })
        #expect(sync.segment.plainText == "\u{2191}\u{2013} \u{2193}\u{2013}")
        #expect(sync.tooltip == "No upstream")
        #expect(sync.segment.colors == [Theme.default.foregroundDim])
        // The branch tooltip says the same thing, since that is where the user looks first.
        #expect(items.first?.tooltip == "Branch spike\nNo upstream")
    }

    @Test func upstreamPresentDrawsTheCounts() throws {
        let model = StatusBarModel(
            branch: "develop", ahead: 0, behind: 2, upstream: "origin/develop")
        let items = Self.items(model)
        let sync = try #require(items.first { $0.segment.plainText.hasPrefix("\u{2191}") })
        #expect(sync.segment.plainText == "\u{2191}0 \u{2193}2")
        #expect(sync.tooltip == "0 ahead of origin/develop, 2 behind")
        #expect(items.first?.tooltip == "Branch develop\nUpstream origin/develop")
    }

    @Test func unknownUpstreamDrawsNothingAtAll() {
        // Nothing reported yet: not dimmed dashes, not zeroes — no segment.
        let items = Self.items(StatusBarModel(branch: "develop"))
        #expect(!items.contains { $0.segment.plainText.contains("\u{2191}") })
    }

    // MARK: PR badge

    @Test func approvedPullRequestIsATickInTheAddColour() throws {
        let pr = PRInfo(
            number: 123, url: "https://github.com/o/r/pull/123", state: "OPEN",
            reviewDecision: "APPROVED")
        let item = try #require(Self.items(StatusBarModel(pullRequest: pr)).first)
        #expect(item.segment.plainText == "#123 \u{2713}")
        #expect(item.segment.colors.first == Theme.default.diffAdd)
        #expect(item.url?.absoluteString == "https://github.com/o/r/pull/123")
        #expect(item.tooltip?.contains("Pull request #123") == true)
        #expect(item.tooltip?.contains("Review approved") == true)
    }

    @Test func draftBeatsTheReviewDecision() throws {
        let pr = PRInfo(number: 7, state: "OPEN", isDraft: true, reviewDecision: "APPROVED")
        let item = try #require(Self.items(StatusBarModel(pullRequest: pr)).first)
        #expect(item.segment.plainText == "#7 draft")
        #expect(item.segment.colors.first == Theme.default.foregroundDim)
        // No URL in the payload → nothing to click, and no crash constructing one.
        #expect(item.url == nil)
    }

    @Test func changesRequestedUsesTheRemoveColour() throws {
        let pr = PRInfo(number: 9, state: "OPEN", reviewDecision: "CHANGES_REQUESTED")
        let item = try #require(Self.items(StatusBarModel(pullRequest: pr)).first)
        #expect(item.segment.plainText == "#9 \u{25CF}")
        #expect(item.segment.colors.first == Theme.default.diffRemove)
    }

    // MARK: Ports

    @Test func eachPortIsItsOwnClickableItemButOneVisualGroup() {
        let model = StatusBarModel(
            ports: [5173, 3000], portOwners: [3000: "node (pid 900)", 5173: "vite (pid 901)"])
        let items = Self.items(model)
        #expect(items.map(\.segment.plainText) == [":3000", ":5173"])
        // First port opens the group with ` · `; the second is glued on with a space, so the strip
        // still reads `:3000 :5173` rather than `:3000 · :5173`.
        #expect(items[0].separated)
        #expect(!items[1].separated)
        #expect(items[0].url?.absoluteString == "http://localhost:3000")
        #expect(items[1].url?.absoluteString == "http://localhost:5173")
        #expect(items[0].tooltip == ":3000 — node (pid 900)\nOpen http://localhost:3000")
        // A port with no known owner still renders and still has a tooltip.
        let anonymous = Self.items(StatusBarModel(ports: [8080]))
        #expect(anonymous.first?.tooltip == ":8080\nOpen http://localhost:8080")
    }

    // MARK: Hit testing

    @Test func placementResolvesTheItemUnderAPoint() {
        let view = Self.laidOut(StatusBarModel(
            branch: "develop", pullRequest: PRInfo(number: 4, url: "https://x/4"), ports: [3000]))
        let placed = view.placement()
        #expect(placed.count == 3)
        for entry in placed {
            let middle = NSPoint(x: entry.frame.midX, y: entry.frame.midY)
            #expect(view.item(at: middle)?.segment == entry.item.segment)
        }
        // A point in the left inset belongs to no item.
        #expect(view.item(at: NSPoint(x: 2, y: 15)) == nil)
    }

    @Test func clickingAPortOpensLocalhost() throws {
        let view = Self.laidOut(StatusBarModel(branch: "develop", ports: [4321]))
        let opened = OpenedBox()
        view.openURL = { opened.url = $0 }

        let port = try #require(view.placement().first { $0.item.url != nil })
        let point = NSPoint(x: port.frame.midX, y: port.frame.midY)
        let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseUp(with: event)
        #expect(opened.url?.absoluteString == "http://localhost:4321")

        // A click on the branch — an item with no URL — opens nothing.
        opened.url = nil
        let branch = try #require(view.placement().first)
        let branchPoint = NSPoint(x: branch.frame.midX, y: branch.frame.midY)
        let branchEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: view.convert(branchPoint, to: nil),
            modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseUp(with: branchEvent)
        #expect(opened.url == nil)
    }

    /// A reference the click closure can write into from the main actor.
    @MainActor final class OpenedBox {
        var url: URL?
    }

    @Test func tooltipsResolveByPoint() throws {
        let view = Self.laidOut(StatusBarModel(branch: "develop", upstream: "origin/develop"))
        let branch = try #require(view.placement().first)
        let point = NSPoint(x: branch.frame.midX, y: branch.frame.midY)
        let tooltip = view.view(view, stringForToolTip: 0, point: point, userData: nil)
        #expect(tooltip == "Branch develop\nUpstream origin/develop")
        // Off any item: the empty string, not a stale neighbour's text.
        #expect(view.view(view, stringForToolTip: 0, point: NSPoint(x: 2, y: 15), userData: nil) == "")
    }

    @Test func aNoticeStillOwnsTheWholeStripAndHasNoInteraction() {
        let items = Self.items(StatusBarModel(notice: "Restored sidebar from backup", branch: "x"))
        #expect(items.count == 1)
        #expect(items[0].segment.plainText == "Restored sidebar from backup")
        #expect(items[0].url == nil)
        #expect(items[0].tooltip == nil)
    }

    // MARK: Trailing group

    @Test func portsContextAndUsageSitFlushRight() throws {
        // The artboards put a spacer before the ports, so ports · Context · Usage · resets end at
        // the right inset while the branch group starts at the left one.
        let view = Self.laidOut(StatusBarViewTests.full, width: 1_240)
        let placed = view.placement()
        let leading = placed.filter { !$0.item.trailing }
        let trailing = placed.filter(\.item.trailing)
        #expect(leading.count == 6)      // branch, WT, model, diff, files, ↑↓
        #expect(trailing.count == 5)     // :3000, :5173, Context, Usage, resets
        let last = try #require(trailing.last)
        #expect(abs(last.frame.maxX - (view.bounds.maxX - 12)) < 0.5)
        let first = try #require(leading.first)
        #expect(first.frame.minX == 12)
        // The two groups never touch, and the trailing group has no separator before its first item.
        let lastLeading = try #require(leading.last)
        let firstTrailing = try #require(trailing.first)
        #expect(firstTrailing.frame.minX - lastLeading.frame.maxX > 4)
        #expect(firstTrailing.separatorX == nil)
        #expect(placed.allSatisfy { $0.truncatedWidth == nil })
    }

    @Test func aTrailingGroupAloneStillStartsAtTheRight() throws {
        let view = Self.laidOut(StatusBarModel(contextPercent: 62, usagePercent: 5), width: 600)
        let placed = view.placement()
        #expect(placed.count == 2)
        #expect(placed.first?.separatorX == nil)
        let last = try #require(placed.last)
        #expect(abs(last.frame.maxX - (view.bounds.maxX - 12)) < 0.5)
    }

    @Test func aNarrowStripFlowsEverythingFromTheLeftInstead() {
        // 300 pt cannot hold the trailing group and a branch group: the line falls back to a
        // single left-to-right flow that truncates, rather than right-aligning half of it.
        let view = Self.laidOut(StatusBarViewTests.full, width: 300)
        let placed = view.placement()
        #expect(!placed.isEmpty)
        #expect(placed.first?.frame.minX == 12)
        for entry in placed { #expect(entry.frame.maxX <= view.bounds.maxX - 12 + 0.5) }
        #expect(placed.contains { !$0.item.trailing })
    }

    @Test func truncationStillLeavesNoDanglingSeparator() {
        // A width that cannot hold the whole line: the placement stops cleanly and every frame
        // stays inside the view, so nothing is clickable off the end of the strip.
        let view = Self.laidOut(StatusBarViewTests.full, width: 200)
        let placed = view.placement()
        #expect(!placed.isEmpty)
        #expect(placed.count < StatusBarView.items(for: StatusBarViewTests.full, theme: .default).count)
        for entry in placed { #expect(entry.frame.maxX <= view.bounds.maxX + 0.5) }
    }
}
