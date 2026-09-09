// ScrollIndicator — the overlay scrollbar thumb over the Metal surface (M2.5 / TKZ-45).
//
// ## Why there is one at all
//
// The terminal had no scroll indicator of any kind, which read as a bug rather than a decision:
// the sidebar and the command palette both have real `NSScrollView`s with visible scrollers, and
// sessions here carry a 24 MiB scrollback that M5 restores mid-history. Scrolled up in a long
// session there was nothing on screen that said so.
//
// ## Why it is not an NSScrollView
//
// Wrapping `TerminalMetalView` in one would fight the display link, `presentsWithTransaction` and
// the grid-derivation paths, and AppKit would want to own a scroll geometry the terminal already
// owns — libghostty is the single source of truth for `{total, offset, len}`. So: a `CALayer` over
// the right edge, a sublayer of the `CAMetalLayer` exactly like `MouseController.linkOverlay`.
//
// ## Why it is a poll, and why the poll lives in the renderer
//
// `vt/terminal.h` is explicit that scroll state has *intentionally* no change notification, and
// tells callers to poll `DATA_SCROLLBAR` once per frame and diff it. `FrameBuilder.update` already
// takes the terminal lock once per frame, so the read rides along there and lands on
// `TerminalSurface.scrollMetrics`; this file only ever diffs the result. (`withTerminal` is
// `package` to TkzTerminalRender, so the view layer could not do the read itself even if it wanted
// to — the module boundary happens to enforce the right design.)
//
// ## The idle guarantee, which is the whole constraint
//
// M1.6 buys "an idle terminal costs nothing" with `DisplayLinkPolicy.shouldRun`. Two rules keep
// that true here, and both are load-bearing:
//
//   * Nothing in this file touches `DisplayLinkDriver` or `surface.markNeedsDisplay()`. A moved
//     thumb is a layer change, not GPU content; requesting a frame for one would pin the link at
//     120 Hz forever.
//   * The fade is Core Animation plus one main-actor timer — never ticked frames. Same shape as
//     the cursor blink, and for the same reason.
//
// ## Split
//
// `ScrollIndicatorGeometry` (pure, rows → rect) and `ScrollIndicatorOverlay` (AppKit, owns the
// layer), mirroring `DisplayLinkPolicy` / `DisplayLinkDriver`: the arithmetic that the acceptance
// criteria are actually about unit-tests with no layer, no window and no run loop.
//
// ## Deferred
//
// The thumb is an indicator, not a control. Dragging it needs `GHOSTTY_SCROLL_VIEWPORT_ROW` (which
// exists, and shares `scrollbar.offset`'s row space so a position round-trips) plumbed through
// `MouseControllerTerminal`, plus hit-testing ahead of `selectionPress` so it cannot collide with
// selection drags. That, and anything stronger keyed off `DATA_VIEWPORT_ACTIVE` (dimming, a "jump
// to bottom" affordance), is a separate ticket.

import AppKit
import QuartzCore
import TkzTerminalCore

// MARK: - Geometry

/// Turns `{total, offset, visible}` rows into a thumb rect, or `nil` for "draw nothing".
///
/// A pure value: no layer, no view, no clock. This is where "the thumb's size and position match
/// `{total, offset, len}`" becomes something you can assert rather than eyeball.
public struct ScrollIndicatorGeometry: Sendable, Hashable {
    /// Thumb width in points. macOS overlay scrollers are 7 pt over content.
    public var width: CGFloat = 7
    /// Gap between the thumb and the right edge of the surface.
    public var edgeInset: CGFloat = 2
    /// Gap at the top and bottom of the track.
    public var endInset: CGFloat = 2
    /// The thumb never shrinks below this, however deep the scrollback — a 24 MiB history would
    /// otherwise compute a sub-pixel thumb.
    public var minimumLength: CGFloat = 24

    public init() {}

    /// The thumb rect in `bounds`' coordinate space (points, top-left origin — `TerminalMetalView`
    /// is `isFlipped`), or `nil` when no thumb should be drawn.
    public func thumb(for metrics: TerminalScrollMetrics, in bounds: CGRect) -> CGRect? {
        // The alternate screen has no scrollback: Claude Code's TUI must show no thumb at all.
        // `isScrollable` folds that in with the "everything fits" case.
        guard metrics.isScrollable else { return nil }

        let track = bounds.height - 2 * endInset
        // A window too short to hold even a minimum thumb gets none, rather than a squashed one.
        guard track >= minimumLength, bounds.width > width + edgeInset else { return nil }

        let proportion = CGFloat(metrics.visible) / CGFloat(metrics.total)
        let length = max(minimumLength, track * proportion)
        let travel = max(0, track - length)

        let scrollable = metrics.scrollableRows
        // Clamped, not extrapolated: `offset` is libghostty's and we do not get to assume it stays
        // inside the range implied by a `total` read in the same breath.
        let progress: CGFloat = scrollable > 0
            ? min(1, max(0, CGFloat(metrics.offset) / CGFloat(scrollable)))
            : 0

        return CGRect(
            x: bounds.maxX - edgeInset - width,
            y: bounds.minY + endInset + travel * progress,
            width: width,
            height: length)
    }
}

// MARK: - Overlay

/// Owns the thumb layer and the fade timer. The thin AppKit half.
///
/// Like `DisplayLinkDriver`, an overlay that has never been handed a host layer is still fully
/// functional — it just has nothing to show — which is what lets the headless tests drive the same
/// decision code the app runs.
@MainActor
public final class ScrollIndicatorOverlay {
    /// How long the thumb stays at full opacity after the last scroll.
    public var fadeDelay: TimeInterval = 0.8
    /// How long the fade itself takes.
    public var fadeDuration: TimeInterval = 0.35
    /// Proportions. Settable so a test can pin them.
    public var geometry = ScrollIndicatorGeometry()

    /// The last metrics `apply` acted on, or `nil` when the overlay has been reset. This is the
    /// diff key: `nil` forces the next `apply` to act unconditionally, which is what stops an
    /// incoming session inheriting the outgoing one's thumb.
    public private(set) var lastApplied: TerminalScrollMetrics?
    /// The layer, if a thumb is currently shown. Tests only — mirrors `linkUnderlineLayer`.
    public var thumbLayer: CALayer? { thumb }
    /// How many times the reveal-and-restart-the-fade path ran. Tests only.
    public private(set) var revealCount = 0

    private var thumb: CALayer?
    private var lastBounds: CGRect?
    /// One timer for the lifetime of the overlay, re-armed rather than rebuilt. While output
    /// streams with the viewport pinned to the bottom, `offset` moves every frame, so a fresh
    /// `DispatchSourceTimer` per reveal would mean one allocation per frame at up to 120 Hz.
    private var fadeTimer: DispatchSourceTimer?
    /// Bumped on every arm and cancel. A source that has been cancelled after its handler was
    /// already enqueued on the main queue still runs that handler, which would fade a thumb the
    /// next frame had just revealed; the handler checks this and bails.
    private var fadeGeneration = 0

    private static let opacityKey = "opacity"

    public init() {}

    isolated deinit { fadeTimer?.cancel() }

    /// Diffs `metrics` against the last frame and updates the layer.
    ///
    /// Called once per frame from `TerminalMetalView.renderNow`, so the common case — an idle
    /// terminal, or a frame that changed cells but not the scroll position — must cost nothing but
    /// the comparison.
    public func apply(
        _ metrics: TerminalScrollMetrics,
        bounds: CGRect,
        scale: CGFloat,
        color: CGColor,
        host: CALayer
    ) {
        // Ahead of every early return: backing scale is not part of the diff key, so dragging the
        // window to a display with a different scale changes neither `metrics` nor `bounds` and
        // would otherwise leave a blurry thumb until the next scroll. The assignment is free.
        if let thumb, thumb.contentsScale != scale { thumb.contentsScale = scale }

        let boundsChanged = bounds != lastBounds
        let metricsChanged = metrics != lastApplied
        guard boundsChanged || metricsChanged else { return }
        lastApplied = metrics
        lastBounds = bounds

        guard let rect = geometry.thumb(for: metrics, in: bounds) else {
            hide()
            return
        }

        let layer = thumb ?? makeThumb(in: host, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color
        layer.cornerRadius = rect.width / 2
        layer.frame = rect
        layer.isHidden = false
        if metricsChanged {
            // Setting `opacity` on the model layer does *not* interrupt a running animation on the
            // same key: the presentation would finish fading to 0 and then snap back to 1. Scroll
            // during a fade and that reads as a flicker, so the animation has to go first.
            layer.removeAnimation(forKey: Self.opacityKey)
            layer.opacity = 1
        }
        CATransaction.commit()

        // A resize that did not move the viewport repositions the thumb silently. Restarting the
        // reveal there would flash the thumb back on every time the window is dragged.
        guard metricsChanged else { return }
        revealCount += 1
        scheduleFade()
    }

    /// Fades the thumb out now. Also the tests' entry point, so they need no clock injection.
    public func beginFade() {
        cancelFade()
        guard let thumb, !thumb.isHidden, thumb.opacity > 0 else { return }
        let animation = CABasicAnimation(keyPath: Self.opacityKey)
        animation.fromValue = thumb.opacity
        animation.toValue = 0
        animation.duration = fadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        thumb.opacity = 0
        thumb.add(animation, forKey: Self.opacityKey)
    }

    /// Drops the thumb and forgets the diff, without animating.
    ///
    /// `TerminalMetalView.show(_:)` calls this on every session switch: the incoming session must
    /// paint its own position on its first frame, never inherit a position or a half-finished fade
    /// from the outgoing one.
    public func reset() {
        cancelFade()
        thumb?.removeFromSuperlayer()
        thumb = nil
        lastApplied = nil
        lastBounds = nil
    }

    // MARK: Private

    private func makeThumb(in host: CALayer, scale: CGFloat) -> CALayer {
        let layer = CALayer()
        // Implicit actions off: with them on, the thumb lerps a beat behind the viewport during a
        // scroll instead of tracking it. Same list as `MouseController.linkOverlay`, plus opacity,
        // which this layer animates explicitly and never implicitly.
        layer.actions = [
            "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(),
            "opacity": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull(),
        ]
        layer.zPosition = 1
        layer.contentsScale = scale
        host.addSublayer(layer)
        thumb = layer
        return layer
    }

    private func hide() {
        cancelFade()
        guard let thumb else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.removeAnimation(forKey: Self.opacityKey)
        thumb.isHidden = true
        CATransaction.commit()
    }

    /// One-shot, on the main queue, in the same idiom as the cursor blink timer. It pokes the layer
    /// and nothing else — in particular it never reaches `DisplayLinkDriver`.
    private func scheduleFade() {
        guard fadeDelay > 0 else { return beginFade() }
        fadeGeneration &+= 1
        let generation = fadeGeneration

        let timer = fadeTimer ?? {
            let created = DispatchSource.makeTimerSource(queue: .main)
            created.resume()
            fadeTimer = created
            return created
        }()
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                self.beginFade()
            }
        }
        // Re-arming an already-armed (or already-fired) source just moves its deadline, which is
        // exactly what "the fade restarts on every scroll" means.
        timer.schedule(deadline: .now() + fadeDelay, leeway: .milliseconds(50))
    }

    /// Disarms the pending fade without tearing the source down.
    private func cancelFade() {
        fadeGeneration &+= 1
        fadeTimer?.schedule(deadline: .distantFuture)
    }
}
