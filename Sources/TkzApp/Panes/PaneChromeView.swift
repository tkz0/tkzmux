// One pane's chrome: the header above the terminal, and the focus ring around both
// (design 2c.3 / 2c.4).
//
// This is the view the split container arranges — the terminal view sits inside it. The wrapper
// exists so that a header can appear and disappear (a lone pane has none, like a lone tab has no
// strip) without the terminal view ever leaving the tree: re-parenting a surface is a
// `DIRTY_FULL`, and the header's appearance is a resize, which the surface already handles.
//
// The ring is the layer's own border. Core Animation composites a layer's border above its
// contents *and* its sublayers, so it sits over the Metal layer with no extra layer and no
// `zPosition` bookkeeping.

import AppKit
import TkzCore

public final class PaneChromeView: NSView {
    let header: PaneHeaderView
    /// The terminal view (or a test's stand-in). Fills the chrome below the header.
    public let content: NSView
    /// "Starting Claude…", over `content` while the pane's boot command is still on its way.
    /// A sibling above the terminal view, so the body dimming below never touches it.
    let startupOverlay: PaneStartupOverlayView

    private var theme: Theme
    private var headerVisible = false
    private var focused = false

    init(content: NSView, theme: Theme) {
        self.content = content
        self.header = PaneHeaderView(theme: theme)
        self.startupOverlay = PaneStartupOverlayView(theme: theme)
        self.theme = theme
        super.init(frame: content.frame)
        wantsLayer = true
        layer?.actions = ["borderColor": NSNull(), "borderWidth": NSNull(), "backgroundColor": NSNull()]
        layer?.backgroundColor = theme.terminalBackground.cgColor
        header.isHidden = true
        content.translatesAutoresizingMaskIntoConstraints = true
        header.translatesAutoresizingMaskIntoConstraints = true
        startupOverlay.translatesAutoresizingMaskIntoConstraints = true
        addSubview(content)
        addSubview(header)
        addSubview(startupOverlay)
        applyFocus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var isFlipped: Bool { true }

    // MARK: Configuration

    /// Shows or hides the header. The terminal's frame changes with it, which is what resizes the
    /// grid — no re-attach.
    func setHeaderVisible(_ visible: Bool) {
        guard visible != headerVisible else { return }
        headerVisible = visible
        header.isHidden = !visible
        applyFocus()
        needsLayout = true
    }

    var isHeaderVisible: Bool { headerVisible }

    /// The ring, the header palette and the body dimming, all from one flag — the store's
    /// `Tab.focusedLeaf`, never the first responder. The ring only ever shows alongside a header:
    /// a lone pane is always its tab's focused leaf, and 2c.1 draws no ring around it.
    func setFocused(_ focused: Bool) {
        guard focused != self.focused else { return }
        self.focused = focused
        applyFocus()
    }

    var isFocused: Bool { focused }

    /// Shows the "Starting Claude…" overlay for `model`, or hides it for `nil`. A no-op on an
    /// equal model, like `PaneHeaderView.configure`.
    func setStartup(_ model: PaneStartupModel?) {
        if let model {
            startupOverlay.show(model, theme: theme)
        } else {
            startupOverlay.hide()
        }
    }

    var isShowingStartup: Bool { startupOverlay.isShowing }

    func apply(theme: Theme) {
        self.theme = theme
        layer?.backgroundColor = theme.terminalBackground.cgColor
        header.setTheme(theme)
        startupOverlay.apply(theme: theme)
        applyFocus()
    }

    private func applyFocus() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let ringed = focused && headerVisible
        layer?.borderWidth = ringed ? PaneHeaderMetrics.focusRingWidth : 0
        layer?.borderColor = ringed ? theme.focusRing.cgColor : nil
        content.alphaValue = focused ? 1 : PaneHeaderMetrics.inactiveContentAlpha
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let headerHeight = headerVisible ? PaneHeaderMetrics.height : 0
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        content.frame = CGRect(
            x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
        startupOverlay.frame = content.frame
    }

    // MARK: Test hooks

    var ringWidth: CGFloat { layer?.borderWidth ?? 0 }
    var ringColor: CGColor? { layer?.borderColor }
}
