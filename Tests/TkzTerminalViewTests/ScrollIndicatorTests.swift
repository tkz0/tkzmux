// The scroll indicator's arithmetic and its diff, tested without a window, a screen or a run loop.
// `ScrollIndicatorGeometry` is the same code the app runs; an overlay with no host layer is the
// same bookkeeping the app runs.
import AppKit
import Testing
import TkzTerminalCore
@testable import TkzTerminalView

@Suite("Scroll indicator geometry")
struct ScrollIndicatorGeometryTests {
    private let geometry = ScrollIndicatorGeometry()
    /// 400 pt tall, so the track is 396 pt after the 2 pt end insets.
    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)

    private func metrics(total: Int, offset: Int, visible: Int, alt: Bool = false)
        -> TerminalScrollMetrics
    {
        TerminalScrollMetrics(total: total, offset: offset, visible: visible, isAlternateScreen: alt)
    }

    @Test("everything fits: no thumb")
    func fitsExactly() {
        #expect(geometry.thumb(for: metrics(total: 50, offset: 0, visible: 50), in: bounds) == nil)
        #expect(geometry.thumb(for: metrics(total: 20, offset: 0, visible: 50), in: bounds) == nil)
        #expect(geometry.thumb(for: .empty, in: bounds) == nil)
    }

    /// Claude Code's TUI lives on the alternate screen, which has no scrollback. Even if libghostty
    /// reported a `total` there, nothing should be drawn.
    @Test("the alternate screen never shows a thumb, whatever the rows say")
    func alternateScreenIsBlank() {
        let scrollable = metrics(total: 1000, offset: 500, visible: 50, alt: true)
        #expect(scrollable.isScrollable == false)
        #expect(geometry.thumb(for: scrollable, in: bounds) == nil)
    }

    @Test("a window too short for a minimum thumb gets none rather than a squashed one")
    func tinyBounds() {
        let tiny = CGRect(x: 0, y: 0, width: 600, height: 20)
        #expect(geometry.thumb(for: metrics(total: 1000, offset: 0, visible: 50), in: tiny) == nil)
    }

    @Test("thumb length is the visible fraction of the track")
    func lengthIsProportional() throws {
        // 50 of 200 rows visible = a quarter of a 396 pt track = 99 pt, comfortably over the floor.
        let thumb = try #require(geometry.thumb(for: metrics(total: 200, offset: 0, visible: 50),
                                                 in: bounds))
        #expect(thumb.height == 99)
        #expect(thumb.width == geometry.width)
        // Right edge, inset by `edgeInset`.
        #expect(thumb.maxX == bounds.maxX - geometry.edgeInset)
    }

    /// A 24 MiB scrollback would otherwise compute a sub-pixel thumb.
    @Test("a very deep scrollback clamps to the minimum length")
    func minimumLengthClamp() throws {
        let thumb = try #require(geometry.thumb(for: metrics(total: 100_000, offset: 0, visible: 50),
                                                 in: bounds))
        #expect(thumb.height == geometry.minimumLength)
    }

    @Test("offset 0 sits flush against the top inset")
    func topOfHistory() throws {
        let thumb = try #require(geometry.thumb(for: metrics(total: 200, offset: 0, visible: 50),
                                                 in: bounds))
        #expect(thumb.minY == geometry.endInset)
    }

    @Test("the bottom of the scrollback sits flush against the bottom inset")
    func bottomOfHistory() throws {
        // offset == total - visible: the viewport is pinned to the active area.
        let thumb = try #require(geometry.thumb(for: metrics(total: 200, offset: 150, visible: 50),
                                                 in: bounds))
        #expect(thumb.maxY == bounds.maxY - geometry.endInset)
    }

    @Test("halfway through the history puts the thumb halfway down the travel")
    func midHistory() throws {
        let thumb = try #require(geometry.thumb(for: metrics(total: 200, offset: 75, visible: 50),
                                                 in: bounds))
        // travel = 396 - 99 = 297; half of that, plus the top inset.
        #expect(thumb.minY == geometry.endInset + 297 / 2)
    }

    @Test("an offset past the end is clamped, not extrapolated")
    func offsetClamps() throws {
        let thumb = try #require(geometry.thumb(for: metrics(total: 200, offset: 9_999, visible: 50),
                                                 in: bounds))
        #expect(thumb.maxY == bounds.maxY - geometry.endInset)
    }
}

@Suite("Scroll indicator overlay")
@MainActor
struct ScrollIndicatorOverlayTests {
    private let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
    private let color = CGColor(gray: 1, alpha: 0.5)

    private func scrollable(offset: Int = 0) -> TerminalScrollMetrics {
        TerminalScrollMetrics(total: 200, offset: offset, visible: 50, isAlternateScreen: false)
    }

    /// The fade is never scheduled in these tests: `fadeDelay` stays at its default and no run loop
    /// is spun, so the timer cannot fire. `beginFade()` is driven directly where it matters.
    private func makeOverlay() -> (ScrollIndicatorOverlay, CALayer) {
        (ScrollIndicatorOverlay(), CALayer())
    }

    private func apply(_ overlay: ScrollIndicatorOverlay, _ metrics: TerminalScrollMetrics,
                       bounds: CGRect, host: CALayer)
    {
        overlay.apply(metrics, bounds: bounds, scale: 2, color: color, host: host)
    }

    @Test("a scrollable session gets a thumb layer under the host")
    func revealsThumb() throws {
        let (overlay, host) = makeOverlay()
        apply(overlay, scrollable(), bounds: bounds, host: host)
        let thumb = try #require(overlay.thumbLayer)
        #expect(thumb.superlayer === host)
        #expect(thumb.isHidden == false)
        #expect(thumb.opacity == 1)
        #expect(thumb.contentsScale == 2)
        #expect(overlay.revealCount == 1)
    }

    @Test("an unchanged frame does no work at all")
    func idleFrameIsFree() {
        let (overlay, host) = makeOverlay()
        apply(overlay, scrollable(), bounds: bounds, host: host)
        apply(overlay, scrollable(), bounds: bounds, host: host)
        apply(overlay, scrollable(), bounds: bounds, host: host)
        #expect(overlay.revealCount == 1, "the diff must swallow repeat frames")
    }

    /// Regression: a window resize repositions the thumb but must not flash it back on. Only a
    /// change in the *scroll position* is a reveal.
    @Test("a bounds-only change repositions silently, without restarting the fade")
    func boundsOnlyChangeIsSilent() {
        let (overlay, host) = makeOverlay()
        apply(overlay, scrollable(), bounds: bounds, host: host)
        overlay.beginFade()
        let faded = overlay.thumbLayer?.opacity

        let taller = CGRect(x: 0, y: 0, width: 600, height: 800)
        apply(overlay, scrollable(), bounds: taller, host: host)

        #expect(overlay.revealCount == 1, "a resize is not a reveal")
        #expect(overlay.thumbLayer?.opacity == faded, "a resize must not re-show a faded thumb")
        // But it *does* resize: an 800 pt window has a 796 pt track, a quarter of which is 199.
        #expect(overlay.thumbLayer?.frame.height == 199)
        #expect(overlay.thumbLayer?.frame.maxX == taller.maxX - overlay.geometry.edgeInset)
    }

    @Test("a scroll during the fade snaps back to full opacity with no animation left behind")
    func scrollDuringFadeSnapsBack() {
        let (overlay, host) = makeOverlay()
        apply(overlay, scrollable(offset: 0), bounds: bounds, host: host)
        overlay.beginFade()
        #expect(overlay.thumbLayer?.animation(forKey: "opacity") != nil)

        apply(overlay, scrollable(offset: 40), bounds: bounds, host: host)

        // Setting `opacity = 1` alone would leave the running animation to finish fading to 0 and
        // then snap back — a visible flicker. The animation has to be removed.
        #expect(overlay.thumbLayer?.animation(forKey: "opacity") == nil)
        #expect(overlay.thumbLayer?.opacity == 1)
        #expect(overlay.revealCount == 2)
    }

    @Test("scrolling into the alternate screen hides the thumb")
    func alternateScreenHides() {
        let (overlay, host) = makeOverlay()
        apply(overlay, scrollable(), bounds: bounds, host: host)
        #expect(overlay.thumbLayer?.isHidden == false)

        let alt = TerminalScrollMetrics(total: 200, offset: 0, visible: 50, isAlternateScreen: true)
        apply(overlay, alt, bounds: bounds, host: host)
        #expect(overlay.thumbLayer?.isHidden == true)
    }

    /// `show(_:)` calls this on every session switch. The next `apply` must act unconditionally, so
    /// the incoming session cannot inherit the outgoing one's position.
    @Test("reset drops the layer and forgets the diff")
    func resetClearsEverything() {
        let (overlay, host) = makeOverlay()
        apply(overlay, scrollable(offset: 40), bounds: bounds, host: host)
        #expect(overlay.lastApplied != nil)

        overlay.reset()
        #expect(overlay.thumbLayer == nil)
        #expect(overlay.lastApplied == nil)
        #expect(host.sublayers?.isEmpty ?? true)

        // The identical metrics still count as a change after a reset — no stale position survives.
        apply(overlay, scrollable(offset: 40), bounds: bounds, host: host)
        #expect(overlay.revealCount == 2)
        #expect(overlay.thumbLayer?.superlayer === host)
    }

    @Test("backing scale is tracked even when nothing else changed")
    func scaleIsNotPartOfTheDiff() {
        let (overlay, host) = makeOverlay()
        apply(overlay, scrollable(), bounds: bounds, host: host)
        #expect(overlay.thumbLayer?.contentsScale == 2)

        // Same metrics, same bounds, different display: the early return must not leave it stale.
        overlay.apply(scrollable(), bounds: bounds, scale: 1, color: color, host: host)
        #expect(overlay.thumbLayer?.contentsScale == 1)
        #expect(overlay.revealCount == 1)
    }
}
