// GlassSheet — the chrome every floating sheet in the app shares (extracted for TKZ-70).
//
// The rebase sheet (design 5a/5b) established the shape: a `.nonactivatingPanel` carrying an
// `NSVisualEffectView` in `.hudWindow`, an 11 pt corner radius, a 1 pt border of the theme's accent
// at 30 %, placed at the bottom right of the detail area 14 pt in from each edge, key while it is
// up and gone on Escape or on resigning key. The delete-worktree sheets join that family, and the
// ticket asks for them to *look* like it — so the chrome lives here and both build on it.
//
// **Chrome only, no policy.** What each sheet says, how many buttons it has and when they are
// enabled stays in its own model, because that is where the sheets genuinely differ: the rebase
// sheet has one body line and two buttons, the delete sheet has three lines, a conditional dirty
// warning, a checkbox and three buttons. A shared "sheet model" protocol would re-export `title`
// and nothing else, and a shared view would be a pile of `isHidden`. Sharing the 60 lines of panel
// flags is what stops the two drifting apart visibly; sharing anything above them would cost more
// than it saves.

import AppKit
import TkzCore

/// The design's fixed geometry. `width` is per sheet — a list needs more than a sentence — but
/// everything else is the family's.
enum GlassSheetMetrics {
    /// The rebase sheet's width, and the default for a sheet that shows a few lines of text.
    static let width: CGFloat = 318
    static let padding: CGFloat = 14
    static let topPadding: CGFloat = 13
    static let bottomPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 11
    static let buttonHeight: CGFloat = 27
    /// How far the card sits in from the anchor's right and bottom edges.
    static let inset: CGFloat = 14
}

@MainActor
enum GlassSheetPanel {

    /// The panel and the material behind it. The caller adds its own content view to `effect` and
    /// pins it to all four edges.
    ///
    /// `.nonactivatingPanel` so showing the sheet does not steal activation from the terminal;
    /// `hidesOnDeactivate` so ⌘-Tab takes it away; `isFloatingPanel` + `.floating` so it sits over
    /// the detail area rather than behind it. `PromptCardPanel` is what turns Escape into
    /// `onCancel`.
    static func make(
        width: CGFloat = GlassSheetMetrics.width,
        delegate: NSWindowDelegate,
        onCancel: @escaping () -> Void
    ) -> (panel: PromptCardPanel, effect: NSVisualEffectView) {
        let panel = PromptCardPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = delegate
        panel.onCancel = onCancel

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = GlassSheetMetrics.cornerRadius
        effect.layer?.borderWidth = 1
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = effect
        return (panel, effect)
    }

    /// The appearance and the 30 %-accent border. Called again whenever the theme flips.
    static func applyTheme(_ theme: Theme, to effect: NSVisualEffectView) {
        effect.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let accent = theme.accent
        effect.layer?.borderColor = RGB(r: accent.r, g: accent.g, b: accent.b, a: 0.30).cgColor
    }

    /// Bottom right of the anchor (the detail area, in screen coordinates), inset from both edges
    /// — 5a's placement. With no anchor, near the bottom right of the main screen.
    static func frame(for size: NSSize, over anchor: NSRect?) -> NSRect {
        let inset = GlassSheetMetrics.inset
        if let anchor {
            return NSRect(
                x: (anchor.maxX - inset - size.width).rounded(),
                y: (anchor.minY + inset).rounded(),
                width: size.width, height: size.height)
        }
        let host = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(
            x: (host.maxX - inset * 4 - size.width).rounded(),
            y: (host.minY + inset * 4).rounded(),
            width: size.width, height: size.height)
    }
}
