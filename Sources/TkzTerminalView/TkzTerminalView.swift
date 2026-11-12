// TkzTerminalView — the AppKit half of the terminal engine.
//
// This file holds the module marker and `TerminalRenderContext`: the one app-wide owner of the
// font set, glyph atlases and `TerminalRenderer`. It lives here rather than in `TerminalMetalView`
// because it outlives any individual view — M2 puts several views (or a view that is torn down and
// rebuilt) in front of the same context.

import AppKit
import Foundation
import Metal
import TkzCore
import TkzTerminalRender

/// Module marker used by the smoke tests.
public enum TkzTerminalViewModule {
    public static let name = "TkzTerminalView"
}

// MARK: - TerminalRenderContext

/// The app-wide render context: one `FontSet` → one `GlyphCache` → one `TerminalRenderer`, plus the
/// registry of live `TerminalSurface`s that must be re-attached when any of those are rebuilt.
///
/// ## Why this type exists: the backing-scale trap
///
/// A `GlyphCache` rasterizes at `pointSize * scale` and hands out **atlas positions**. Those
/// positions are cached inside every `TerminalSurface`'s per-row glyph instances. Move the window
/// from a 2x display to a 1x display and the atlas must be rebuilt at the new pixel size — at which
/// point every cached position in every surface points at the wrong pixels. There is no way to
/// patch that up: the only correct answer is a new `FontSet`, a new `GlyphCache`, a new
/// `TerminalRenderer`, and a **re-attach of every surface** (an attach always produces
/// `DIRTY_FULL`, so the next frame rebuilds every row from scratch).
///
/// `setScale(_:)` does exactly that, in that order, and is the reason surfaces register here.
///
/// Everything it owns (`FontSet`, `GlyphCache`, `TerminalSurface`) is render-thread-only and not
/// internally synchronized, so the whole type is `@MainActor` — in tkzmux the main thread *is* the
/// render thread.
@MainActor
public final class TerminalRenderContext {
    public private(set) var renderer: TerminalRenderer
    public private(set) var fontSet: FontSet
    /// Backing scale factor the font set and atlases were built at.
    public private(set) var scale: CGFloat
    /// Terminal font size in points the font set was built at.
    public private(set) var pointSize: Double
    /// How many times `setScale(_:)` or `setPointSize(_:)` actually rebuilt. Diagnostics and tests.
    public private(set) var rebuildCount: Int = 0

    /// Posted (object: the context) after `setPointSize(_:)` rebuilt. Every `TerminalMetalView` on
    /// this context resizes its grid on it: the cell got bigger or smaller, so a different number
    /// of columns and rows fits the same bounds, and the pty has to hear about it.
    ///
    /// Not posted by `setScale(_:)`: a scale change reaches every view through its own
    /// `viewDidChangeBackingProperties`, which already resizes the grid.
    public static let metricsDidChangeNotification =
        Notification.Name("TerminalRenderContext.metricsDidChange")

    public var theme: Theme {
        didSet {
            guard theme != oldValue else { return }
            renderer.theme = theme
            for surface in liveSurfaces() { surface.markNeedsDisplay() }
        }
    }

    /// Surfaces are owned by their views; the context only needs to reach them on a rebuild.
    private final class WeakSurface {
        weak var surface: TerminalSurface?
        init(_ surface: TerminalSurface) { self.surface = surface }
    }
    private var registry: [WeakSurface] = []

    /// - Parameter pointSize: terminal font size; `nil` = the theme's own (`fontMono.terminal`).
    public init(
        theme: Theme = .default,
        scale: CGFloat = 2,
        pointSize: Double? = nil,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        guard let device else {
            throw RenderError(result: -1, operation: "MTLCreateSystemDefaultDevice")
        }
        self.theme = theme
        self.scale = scale
        let pointSize = pointSize ?? theme.fontMono.terminal
        self.pointSize = pointSize
        let fontSet = TerminalRenderContext.makeFontSet(theme: theme, pointSize: pointSize, scale: scale)
        self.fontSet = fontSet
        self.renderer = try TerminalRenderer(
            device: device,
            glyphCache: GlyphCache(fontSet: fontSet, device: device, thicken: theme.fontMono.thicken),
            theme: theme)
    }

    private static func makeFontSet(theme: Theme, pointSize: Double, scale: CGFloat) -> FontSet {
        FontSet(
            family: theme.fontMono.family,
            fallback: theme.fontMono.fallback,
            pointSize: CGFloat(pointSize),
            scale: max(1, scale))
    }

    /// Cell geometry of the current atlas, in **device pixels**.
    public var metrics: CellMetrics { renderer.glyphCache.metrics }

    public var device: MTLDevice { renderer.device }

    // MARK: Surface registry

    public func register(_ surface: TerminalSurface) {
        compact()
        guard !registry.contains(where: { $0.surface === surface }) else { return }
        registry.append(WeakSurface(surface))
    }

    public func unregister(_ surface: TerminalSurface) {
        registry.removeAll { $0.surface === surface || $0.surface == nil }
    }

    /// Registered surfaces that are still alive.
    public func liveSurfaces() -> [TerminalSurface] {
        compact()
        return registry.compactMap(\.surface)
    }

    private func compact() { registry.removeAll { $0.surface == nil } }

    // MARK: Scale

    /// Rebuilds the font set, atlases and renderer at `newScale` and re-attaches every registered
    /// surface. Returns `true` when a rebuild happened.
    ///
    /// Re-attaching preserves the session; it throws away render state, row caches and stale atlas
    /// positions, and guarantees the next frame is a `DIRTY_FULL` rebuild.
    @discardableResult
    public func setScale(_ newScale: CGFloat) throws -> Bool {
        let clamped = max(1, newScale)
        guard clamped != scale else { return false }
        try rebuild(scale: clamped, pointSize: pointSize)
        return true
    }

    // MARK: Font size

    /// Rebuilds at a new terminal font size — the same font set / atlas / renderer / re-attach
    /// sequence as `setScale(_:)`, for the same reason (every cached atlas position goes stale) —
    /// then posts `metricsDidChangeNotification` so each view resizes its grid. Returns `true`
    /// when a rebuild happened.
    @discardableResult
    public func setPointSize(_ newSize: Double) throws -> Bool {
        guard newSize.isFinite, newSize > 0, newSize != pointSize else { return false }
        try rebuild(scale: scale, pointSize: newSize)
        NotificationCenter.default.post(name: Self.metricsDidChangeNotification, object: self)
        return true
    }

    /// Everything is built before anything is assigned, so a throw leaves the old, consistent set.
    private func rebuild(scale: CGFloat, pointSize: Double) throws {
        let device = renderer.device
        let fontSet = TerminalRenderContext.makeFontSet(theme: theme, pointSize: pointSize, scale: scale)
        let renderer = try TerminalRenderer(
            device: device,
            glyphCache: GlyphCache(fontSet: fontSet, device: device, thicken: theme.fontMono.thicken),
            theme: theme)

        self.fontSet = fontSet
        self.renderer = renderer
        self.scale = scale
        self.pointSize = pointSize
        rebuildCount += 1
        try reattachAll()
    }

    /// Detaches and re-attaches every live surface. Public because a theme change that alters the
    /// font would need the same treatment (M2).
    public func reattachAll() throws {
        for surface in liveSurfaces() {
            guard let session = surface.session else { continue }
            // `attach` detaches first, so this frees the old render state before allocating a new one.
            try surface.attach(session)
        }
    }
}
