// SidebarHeaderView — the top of the sidebar, under the toolbar: the section caption with a bell
// that switches the ready sound and a folder button that makes a new group.
//
//       GROUPS                    [bell] [folder+]   22 pt caption row
//
// Replaced the "● N WORKING ● N NEED YOU" strip and the dashed "＋ New group" footer on 2026-10-01:
// the status dots on the rows already say who is working and who needs you, and a folder icon at the
// head of the list is where every other sidebar puts "new folder". A search row stood above the
// caption for a day and was taken out again: ⌘F already opens the same overlay. The bell switches
// the "ready" sound on and off (`AppState.soundOnReady`): filled while on, slashed while off.

import AppKit
import TkzCore

public final class SidebarHeaderView: NSView {
    /// Fixed height of the whole header.
    public static let height: Double = SidebarMetrics.sidebarHeaderHeight

    static let topMargin: CGFloat = 4
    static let captionHeight: CGFloat = 22
    static let iconButtonSize: CGFloat = 20
    /// The caption's text lines up with a group header's name (`GroupRowView.nameLeft`).
    static let captionLeft: CGFloat = 25
    /// A label `NSTextField`'s cell draws its text this far inside its frame; the frame is pulled
    /// left by it so the *glyphs* sit on `captionLeft`, as a group name's `CATextLayer` does.
    static let labelInset: CGFloat = 2
    static let iconGap: CGFloat = 4

    /// The section caption above the groups.
    public static let caption = "GROUPS"

    /// Invoked by the folder button.
    public var onNewGroup: (@MainActor () -> Void)?
    /// Invoked by the bell, with the state it should switch to.
    public var onToggleSound: (@MainActor (Bool) -> Void)?

    /// The folder-with-plus button at the right of the caption row.
    public let newGroupButton = NSButton(frame: .zero)
    /// The bell left of the folder: the ready sound on/off.
    public let soundButton = NSButton(frame: .zero)

    /// Whether the bell shows the sound as on. Set by the controller from the store.
    public private(set) var isSoundOn = false

    private let captionLabel = NSTextField(labelWithString: SidebarHeaderView.caption)

    private var theme: Theme = .default

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        captionLabel.font = Theme.Fonts.ui(Theme.Fonts.ui.caption, weight: .semibold)
        addSubview(captionLabel)

        newGroupButton.isBordered = false
        newGroupButton.imagePosition = .imageOnly
        newGroupButton.title = ""
        newGroupButton.target = self
        newGroupButton.action = #selector(newGroupClicked)
        newGroupButton.toolTip = "New group"
        newGroupButton.setAccessibilityLabel("New group")
        addSubview(newGroupButton)

        soundButton.isBordered = false
        soundButton.imagePosition = .imageOnly
        soundButton.title = ""
        soundButton.target = self
        soundButton.action = #selector(soundClicked)
        addSubview(soundButton)

        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    public func configure(theme: Theme) {
        self.theme = theme
        apply()
    }

    @objc private func newGroupClicked() { onNewGroup?() }
    @objc private func soundClicked() { onToggleSound?(!isSoundOn) }

    /// Reflects the store's `soundOnReady` on the bell.
    public func setSoundOn(_ on: Bool) {
        guard on != isSoundOn else { return }
        isSoundOn = on
        applySound()
    }

    private func applySound() {
        soundButton.image = Self.symbol(isSoundOn ? "bell.fill" : "bell.slash", size: 12, weight: .regular)
        // On reads as on: the accent, like a selected toggle. Off sits back with the folder.
        soundButton.contentTintColor = (isSoundOn ? theme.accent : theme.foregroundMuted).nsColor
        let label = isSoundOn ? "Sound when a session is ready: on" : "Sound when a session is ready: off"
        soundButton.toolTip = label
        soundButton.setAccessibilityLabel(label)
    }

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    private func apply() {
        captionLabel.attributedStringValue = NSAttributedString(string: Self.caption, attributes: [
            .font: Theme.Fonts.ui(theme.fontUI.caption, weight: .semibold),
            .foregroundColor: theme.foregroundDim.nsColor,
            .kern: 0.6,
        ])
        newGroupButton.image = Self.symbol("folder.badge.plus", size: 12, weight: .regular)
        newGroupButton.contentTintColor = theme.foregroundMuted.nsColor
        applySound()
    }

    public override func layout() {
        super.layout()
        let width = bounds.width
        let captionTop = Self.topMargin
        captionLabel.sizeToFit()
        let captionSize = captionLabel.frame.size
        captionLabel.frame.origin = NSPoint(
            x: Self.captionLeft - Self.labelInset, y: captionTop + (Self.captionHeight - captionSize.height) / 2)

        let icon = Self.iconButtonSize
        newGroupButton.frame = NSRect(
            x: width - 12 - icon, y: captionTop + (Self.captionHeight - icon) / 2,
            width: icon, height: icon)
        soundButton.frame = newGroupButton.frame.offsetBy(dx: -(icon + Self.iconGap), dy: 0)
    }

    // MARK: Test hooks (internal)

    var captionText: String { captionLabel.stringValue }
    var captionFrame: NSRect { captionLabel.frame }
}
