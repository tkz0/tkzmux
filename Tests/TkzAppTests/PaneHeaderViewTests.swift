// PaneHeaderViewTests — the 28 pt pane header and its adapter (design 2c.3 / 2c.4).
//
// Modelled on `TabStripViewTests`: the adapter is a pure function asserted without a view, and
// the view is asserted structurally — layer colours, frames, hidden flags — with no window,
// which is what "no subviews" buys.

import AppKit
import Testing
import TkzCore

@testable import TkzApp

@MainActor
@Suite(.serialized)
struct PaneHeaderViewTests {

    private static func header(
        _ model: PaneHeaderModel, theme: Theme = .default, width: CGFloat = 400
    ) -> PaneHeaderView {
        let view = PaneHeaderView(theme: theme)
        view.frame = NSRect(x: 0, y: 0, width: width, height: PaneHeaderMetrics.height)
        view.configure(model, theme: theme)
        view.layout()
        return view
    }

    private static func rgb(_ color: CGColor?) -> RGB? {
        guard let color, let c = color.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
            let parts = c.components, parts.count >= 3
        else { return nil }
        return RGB(r: parts[0], g: parts[1], b: parts[2], a: parts.count > 3 ? parts[3] : 1)
    }

    private static func isClose(_ a: RGB?, _ b: RGB, tolerance: Double = 0.01) -> Bool {
        guard let a else { return false }
        return abs(a.r - b.r) < tolerance && abs(a.g - b.g) < tolerance
            && abs(a.b - b.b) < tolerance && abs(a.a - b.a) < tolerance
    }

    // MARK: Adapter (pure)

    @Test func homeIsAbbreviatedToATilde() {
        let home = "/Users/someone"
        #expect(PaneHeaderAdapter.abbreviatingHome("/Users/someone/dev/repo", home: home) == "~/dev/repo")
        #expect(PaneHeaderAdapter.abbreviatingHome("/Users/someone", home: home) == "~")
        #expect(PaneHeaderAdapter.abbreviatingHome("/Users/someone/", home: home) == "~")
        #expect(PaneHeaderAdapter.abbreviatingHome("/Users/someone/dev", home: home + "/") == "~/dev")
        // A sibling that merely shares the prefix is not home.
        #expect(PaneHeaderAdapter.abbreviatingHome("/Users/someoneelse/x", home: home) == "/Users/someoneelse/x")
        #expect(PaneHeaderAdapter.abbreviatingHome("/opt/x", home: home) == "/opt/x")
        #expect(PaneHeaderAdapter.abbreviatingHome("/opt/x", home: "/") == "/opt/x")
        #expect(PaneHeaderAdapter.abbreviatingHome("/opt/x", home: "") == "/opt/x")
    }

    /// The pane's own directory names the header; a pane that has not reported one yet shows the
    /// row's, and focus comes from the tab, not from anything the view knows.
    @Test func theModelFollowsThePanesOwnDirectoryAndTheTabsFocus() throws {
        var state = AppState()
        let group = state.addGroup(name: "g", repoRoot: "/Users/someone/dev/repo")
        let session = state.createSession(groupID: group.id, cwd: "/Users/someone/dev/repo")
        state.setLive(LiveSessionState(shellPid: 1, status: .working, attention: true), for: session.id)
        let first = try #require(state.sessions[session.id]?.focusedTerminalID)
        let split = state.splitPane(first, axis: .horizontal)
        let second = try #require(split)
        state.setPaneCwd(second, path: "/Users/someone/dev/repo/.claude/worktrees/wt")
        state.focusPane(first)

        let a = try #require(PaneHeaderAdapter.model(for: first, in: state, home: "/Users/someone"))
        #expect(a.title == "repo")
        #expect(a.path == "~/dev/repo")
        #expect(a.status == .working)
        #expect(a.needsAttention)
        #expect(a.isFocused)

        let b = try #require(PaneHeaderAdapter.model(for: second, in: state, home: "/Users/someone"))
        #expect(b.title == "wt")
        #expect(b.path == "~/dev/repo/.claude/worktrees/wt")
        #expect(b.status == .working, "every pane of a row shares its Claude session")
        #expect(!b.isFocused)

        #expect(PaneHeaderAdapter.model(for: .generate(), in: state, home: "/") == nil)
    }

    /// `claude -w` chdirs into the worktree; the shell under it never does. The pane running
    /// Claude names Claude's directory, the same answer the git strip gives, and a plain pane in
    /// the same row keeps its own.
    @Test func thePaneRunningClaudeShowsClaudesDirectory() throws {
        var state = AppState()
        let group = state.addGroup(name: "g", repoRoot: "/Users/someone/dev/repo")
        let session = state.createSession(groupID: group.id, cwd: "/Users/someone/dev/repo")
        state.setLive(LiveSessionState(shellPid: 1), for: session.id)
        let first = try #require(state.sessions[session.id]?.focusedTerminalID)
        let split = state.splitPane(first, axis: .horizontal)
        let second = try #require(split)
        state.setPaneCwd(first, path: "/Users/someone/dev/repo")
        state.setPaneCwd(second, path: "/Users/someone/dev/repo")
        state.updateLive(session.id) {
            $0.descriptor = ClaudeSessionInfo(
                configDir: "/home/.claude", pid: 99, sessionId: "s",
                cwd: "/Users/someone/dev/repo/.claude/worktrees/wt")
        }
        state.setClaudeTerminal(session.id, first)

        let a = try #require(PaneHeaderAdapter.model(for: first, in: state, home: "/Users/someone"))
        #expect(a.title == "wt")
        #expect(a.path == "~/dev/repo/.claude/worktrees/wt")
        let b = try #require(PaneHeaderAdapter.model(for: second, in: state, home: "/Users/someone"))
        #expect(b.title == "repo")
        #expect(b.path == "~/dev/repo")
    }

    // MARK: Structure

    @Test func isExactlyTwentyEightPointsTall() {
        let view = Self.header(PaneHeaderModel(title: "repo", path: "~/dev/repo"))
        #expect(view.intrinsicContentSize.height == 28)
        #expect(PaneHeaderMetrics.height == 28)
    }

    @Test func focusedAndUnfocusedPalettesComeFromTheTokens() {
        let theme = Theme.default
        let focused = Self.header(PaneHeaderModel(title: "repo", path: "~/dev/repo", isFocused: true))
        #expect(Self.isClose(Self.rgb(focused.backgroundColor), theme.paneHeaderBackground))
        #expect(Self.isClose(Self.rgb(focused.titleLayer.foregroundColor), theme.foreground))
        #expect(Self.isClose(Self.rgb(focused.pathLayer.foregroundColor), theme.paneHeaderPath))

        let other = Self.header(PaneHeaderModel(title: "repo", path: "~/dev/repo", isFocused: false))
        #expect(Self.isClose(Self.rgb(other.backgroundColor), theme.paneHeaderBackgroundInactive))
        #expect(Self.isClose(Self.rgb(other.titleLayer.foregroundColor), theme.summaryText))
        #expect(Self.isClose(Self.rgb(other.pathLayer.foregroundColor), theme.paneHeaderPathInactive))

        // Theme-driven, not hardcoded: another preset paints differently.
        let light = Self.header(
            PaneHeaderModel(title: "repo", path: "~/dev/repo", isFocused: true), theme: .light)
        #expect(!Self.isClose(Self.rgb(light.backgroundColor), theme.paneHeaderBackground))
        #expect(Self.isClose(Self.rgb(light.backgroundColor), Theme.light.paneHeaderBackground))
    }

    @Test func theDotFollowsTheStatusAndIdleDrawsNone() {
        let working = Self.header(PaneHeaderModel(title: "r", path: "~", status: .working))
        #expect(!working.dotLayer.isHidden)
        #expect(Self.isClose(Self.rgb(working.dotLayer.fillColor), Theme.default.working))
        #expect(working.dotLayer.bounds.width == PaneHeaderMetrics.dotDiameter)

        let idle = Self.header(PaneHeaderModel(title: "r", path: "~", status: .idle))
        #expect(idle.dotLayer.isHidden)
    }

    @Test func theBadgeAppearsOnlyWhenAttentionIsSet() {
        let quiet = Self.header(PaneHeaderModel(title: "r", path: "~"))
        #expect(quiet.badgeLayer.isHidden)
        let loud = Self.header(PaneHeaderModel(title: "r", path: "~", needsAttention: true))
        #expect(!loud.badgeLayer.isHidden)
        #expect(loud.badgeLayer.frame.maxX <= 400 - PaneHeaderMetrics.insetX + 0.5)
        // The badge is never squeezed: the text gives way, not the pill.
        let narrow = Self.header(
            PaneHeaderModel(title: "a-long-title", path: "~/a/long/path", needsAttention: true),
            width: 120)
        #expect(narrow.badgeLayer.frame.width == loud.badgeLayer.frame.width)
    }

    @Test func thePathGivesWayBeforeTheTitle() {
        let wide = Self.header(PaneHeaderModel(title: "repo", path: "~/dev/repo"))
        let titleNatural = wide.titleLayer.frame.width
        #expect(wide.pathLayer.frame.width > 0)
        #expect(!wide.pathLayer.isHidden)
        #expect(wide.pathLayer.frame.minX >= wide.titleLayer.frame.maxX)

        let squeezed = Self.header(PaneHeaderModel(title: "repo", path: "~/dev/repo"), width: 90)
        #expect(squeezed.titleLayer.frame.width == titleNatural, "the title keeps its width first")
        #expect(squeezed.pathLayer.frame.width < wide.pathLayer.frame.width)
        #expect(squeezed.pathLayer.frame.maxX <= 90 - PaneHeaderMetrics.insetX + 0.5)

        let tiny = Self.header(PaneHeaderModel(title: "a-very-long-directory-name", path: "~/x"), width: 60)
        #expect(tiny.titleLayer.frame.maxX <= 60 - PaneHeaderMetrics.insetX + 0.5)
        #expect(tiny.pathLayer.isHidden)
    }

    @Test func reconfiguringWithTheSameModelChangesNothing() {
        let view = Self.header(PaneHeaderModel(title: "repo", path: "~/dev/repo", status: .working))
        #expect(view.dotLayer.isPulsing)
        view.configure(PaneHeaderModel(title: "repo", path: "~/dev/repo", status: .working), theme: .default)
        #expect(view.dotLayer.animation(forKey: StatusDotLayer.pulseAnimationKey) != nil)
        #expect(view.model.title == "repo")
    }

    @Test func aClickActivatesThePane() {
        let view = Self.header(PaneHeaderModel(title: "r", path: "~"))
        var activated = 0
        view.onActivate = { activated += 1 }
        view.mouseDown(with: NSEvent())
        #expect(activated == 1)
    }

    /// The `×` sits against the right inset, is always drawn, and is the one part of the header
    /// a click does not focus.
    @Test func theCloseAffordanceIsTheRightEdge() {
        let view = Self.header(PaneHeaderModel(title: "r", path: "~", needsAttention: true))
        let close = PaneHeaderView.closeRect(width: 400, height: PaneHeaderMetrics.height)
        #expect(close.width == PaneHeaderMetrics.closeSize)
        #expect(close.maxX <= 400 - PaneHeaderMetrics.insetX + 2.5)
        #expect(!view.closeLayer.isHidden)
        #expect(view.closeLayer.string as? String == "\u{00D7}")
        #expect(Self.isClose(Self.rgb(view.closeLayer.foregroundColor), Theme.default.foregroundDim))
        #expect(view.isOnClose(CGPoint(x: close.midX, y: close.midY)))
        #expect(!view.isOnClose(CGPoint(x: 20, y: close.midY)))
        // The badge sits to the left of the `×`, not under it.
        #expect(view.badgeLayer.frame.maxX <= close.minX)
        // A wide title still stops short of it.
        let wide = Self.header(PaneHeaderModel(title: String(repeating: "x", count: 200), path: ""))
        #expect(wide.titleLayer.frame.maxX <= close.minX)
    }

    // MARK: The chrome

    @Test func theChromeRingsOnlyTheFocusedPaneAndHidesTheHeaderUntilAsked() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let chrome = PaneChromeView(content: content, theme: .default)
        chrome.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        chrome.layoutSubtreeIfNeeded()

        #expect(!chrome.isHeaderVisible)
        #expect(chrome.header.isHidden)
        #expect(content.frame == NSRect(x: 0, y: 0, width: 300, height: 200))
        #expect(chrome.ringWidth == 0)
        #expect(abs(content.alphaValue - PaneHeaderMetrics.inactiveContentAlpha) < 0.001)

        // Focus without a header is a lone pane: dimming lifts, but no ring (2c.1).
        chrome.setFocused(true)
        #expect(chrome.ringWidth == 0)
        #expect(content.alphaValue == 1)
        chrome.setFocused(false)

        chrome.setHeaderVisible(true)
        chrome.layoutSubtreeIfNeeded()
        #expect(!chrome.header.isHidden)
        #expect(chrome.header.frame.height == PaneHeaderMetrics.height)
        #expect(content.frame.minY == PaneHeaderMetrics.height)
        #expect(content.frame.height == 200 - PaneHeaderMetrics.height)

        chrome.setFocused(true)
        #expect(chrome.ringWidth == PaneHeaderMetrics.focusRingWidth)
        #expect(Self.isClose(Self.rgb(chrome.ringColor), Theme.default.focusRing))
        #expect(content.alphaValue == 1)

        chrome.setFocused(false)
        #expect(chrome.ringWidth == 0)
    }

    // MARK: The divider

    @Test func theGripSitsInTheMiddleOfTheDivider() {
        #expect(SplitMetrics.dividerThickness == 7)
        let vertical = PaneSplitView.gripRect(
            in: CGRect(x: 100, y: 0, width: 7, height: 600), isVertical: true)
        #expect(vertical.width == SplitMetrics.gripThickness)
        #expect(vertical.height == SplitMetrics.gripLength)
        #expect(abs(vertical.midX - 103.5) < 0.01)
        #expect(abs(vertical.midY - 300) < 1)

        let horizontal = PaneSplitView.gripRect(
            in: CGRect(x: 0, y: 200, width: 800, height: 7), isVertical: false)
        #expect(horizontal.height == SplitMetrics.gripThickness)
        #expect(horizontal.width == SplitMetrics.gripLength)
        #expect(abs(horizontal.midY - 203.5) < 0.01)

        // A divider shorter than the pill shortens the pill rather than overflowing.
        let short = PaneSplitView.gripRect(in: CGRect(x: 0, y: 0, width: 7, height: 20), isVertical: true)
        #expect(short.height == 20)
    }
}
