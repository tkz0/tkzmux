// ChromeViewController — the window's content: the split view (sidebar + terminal) filling the
// whole content area, and the translucent header strip over its top `safeAreaInsets.top` points,
// behind the toolbar items.
//
// The artboards draw a 48 pt header at ~95 % opacity spanning both columns, with a 1 pt bottom
// border. A native titlebar gives that look but with AppKit's `.titlebar` material, which has no
// transparency knob (it came out nearly opaque on 2026-09-08). So the window extends its content
// under a transparent titlebar (`.fullSizeContentView`) and this controller puts its own
// behind-window vibrancy there. The sidebar and the detail half each keep their content below the
// safe area, so the strip covers nothing but the window background — which behind-window blending
// ignores anyway: it samples what is behind the *window*.

import AppKit
import TkzCore

/// Behind-window vibrancy under the toolbar items, with the design's 1 pt bottom border. Empty
/// header pixels drag the window, as a titlebar should.
public final class HeaderBackdropView: NSView {
    /// `.sidebar` is the material of the glass container macOS 26 puts around a sidebar split item
    /// — the look the sidebar had until 2026-09-08 — and it is noticeably more translucent than the
    /// `.titlebar` material behind a native titlebar. `.hudWindow` is the next step up in
    /// transparency if this still reads as too solid.
    public static let material: NSVisualEffectView.Material = .sidebar

    private let effect = NSVisualEffectView()
    private let border = NSView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effect.material = Self.material
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        border.wantsLayer = true
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    public override var mouseDownCanMoveWindow: Bool { true }

    public func apply(theme: Theme) {
        border.layer?.backgroundColor = theme.border.cgColor
    }

    // MARK: Test hooks (internal)

    var effectView: NSVisualEffectView { effect }
    var borderView: NSView { border }
}

/// Wraps the split view controller so the header backdrop can sit above both columns.
final class ChromeViewController: NSViewController {
    let splitViewController: NSSplitViewController
    let headerBackdrop = HeaderBackdropView()
    /// The ⌘-hold cheat sheet. Covers the sidebar, the terminal and the status strip, but not the
    /// toolbar: with `.fullSizeContentView` the titlebar controls live above `contentView`.
    let overlay: NSView

    private var theme: Theme

    init(splitViewController: NSSplitViewController, overlay: NSView, theme: Theme) {
        self.splitViewController = splitViewController
        self.overlay = overlay
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1240, height: 820))
        root.wantsLayer = true
        root.layer?.backgroundColor = theme.windowBackground.cgColor

        addChild(splitViewController)
        let split = splitViewController.view
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)

        headerBackdrop.apply(theme: theme)
        headerBackdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerBackdrop)   // after the split view: above it

        overlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlay)          // last: above the backdrop too

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Exactly the titlebar + toolbar height on screen, and zero headlessly.
            headerBackdrop.topAnchor.constraint(equalTo: root.topAnchor),
            headerBackdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerBackdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerBackdrop.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
        ])
        view = root
    }

    func setTheme(_ theme: Theme) {
        self.theme = theme
        view.layer?.backgroundColor = theme.windowBackground.cgColor
        headerBackdrop.apply(theme: theme)
    }
}
