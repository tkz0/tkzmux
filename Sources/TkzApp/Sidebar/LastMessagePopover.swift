// LastMessagePopover — the sidebar's "what did Claude just say" popover (M3.4 / TKZ-24).
//
// Clicking the status dot of a row that is `idle` with `isDone == true` (the "done" tint) or
// `waiting` shows the session's last `Stop` message — up to 4 KiB, kept by `LiveSessionState` —
// in a transient popover with a scrollable, selectable text view and a Copy button.
//
// A plain `NSPopover(.transient)` rather than a custom window: it already does "click outside to
// dismiss" and anchors to a rect the way the design wants (relative to the clicked row). The text
// view is non-editable but selectable, so the message can be copied by hand as well as by the
// button.

import AppKit
import TkzCore

@MainActor
public final class LastMessagePopover {
    /// The popover's content, at its largest. A short message gets a shorter popover; nothing here
    /// scrolls until the text actually overflows this.
    private static let maxContentSize = NSSize(width: 480, height: 320)
    private static let copyBarHeight: CGFloat = 32
    private static let margin: CGFloat = 8

    private let popover = NSPopover()
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let copyButton: NSButton

    public init(theme: Theme) {
        copyButton = NSButton(title: "Copy", target: nil, action: nil)
        popover.behavior = .transient
        // Animating a close is asynchronous — `isShown` would stay `true` for the duration of the
        // fade, which both looks laggy for a popover this small and makes `close()` untestable
        // headlessly without an artificial wait.
        popover.animates = false

        let container = NSView(
            frame: NSRect(origin: .zero, size: Self.maxContentSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.sidebarBackground.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = Theme.Fonts.ui(Theme.Fonts.ui.body)
        textView.textColor = theme.foreground.nsColor
        textView.textContainerInset = NSSize(width: Self.margin, height: Self.margin)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = NSRect(
            x: 0, y: Self.copyBarHeight, width: Self.maxContentSize.width,
            height: Self.maxContentSize.height - Self.copyBarHeight)

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyMessage)
        copyButton.frame = NSRect(
            x: Self.margin, y: (Self.copyBarHeight - 20) / 2, width: 56, height: 20)
        copyButton.autoresizingMask = [.maxXMargin]

        container.addSubview(scroll)
        container.addSubview(copyButton)

        let viewController = NSViewController()
        viewController.view = container
        popover.contentViewController = viewController
    }

    /// `true` while the popover is on screen.
    public var isShown: Bool { popover.isShown }

    /// Shows `message` anchored to `rect` (in `view`'s coordinate space). Empty messages show
    /// nothing — there is nothing useful to say.
    public func show(message: String, relativeTo rect: NSRect, of view: NSView) {
        guard !message.isEmpty else { return }
        textView.string = message
        popover.contentSize = Self.contentSize(for: message, font: textView.font ?? .systemFont(ofSize: 11))
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }

    public func close() {
        popover.close()
    }

    @objc private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
    }

    /// A popover just tall enough for the message, capped at `maxContentSize` — short messages get
    /// a short popover rather than 320 pt of empty space.
    private static func contentSize(for message: String, font: NSFont) -> NSSize {
        let width = maxContentSize.width
        let usableWidth = width - margin * 2
        let bounding = (message as NSString).boundingRect(
            with: NSSize(width: usableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let textHeight = bounding.height.rounded(.up) + margin * 2
        let height = min(maxContentSize.height, max(80, textHeight + copyBarHeight))
        return NSSize(width: width, height: height)
    }
}
