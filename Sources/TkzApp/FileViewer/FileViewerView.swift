// The read-only file viewer that a file tab puts in place of the pane tree.
//
// A header naming the file with a READ-ONLY tag, over a non-editable `NSTextView`. Markdown is
// rendered (`MarkdownRenderer`); anything else is shown verbatim in the terminal's mono face.
// An image replaces the text view with an `ImageCanvas`, fitted to the tab and never enlarged.

import AppKit
import TkzCore

final class FileViewerView: NSView, NSTextViewDelegate {
    /// A relative link in a rendered Markdown file that names another local file.
    var onOpenFile: ((URL) -> Void)?

    private(set) var url: URL?
    private(set) var content: FileViewerContent?

    let textView: NSTextView
    let scrollView: NSScrollView
    let imageView = ImageCanvas()
    private let header = NSView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let readOnlyLabel = NSTextField(labelWithString: "READ-ONLY")
    private let headerBorder = NSView()
    private var theme: Theme
    private var home: String = NSHomeDirectory()

    static let headerHeight: CGFloat = 28

    /// The body on screen, which is what should hold the keyboard while the tab is.
    var keyView: NSView { imageView.isHidden ? textView : imageView }

    init(theme: Theme) {
        self.theme = theme
        scrollView = NSTextView.scrollableTextView()
        // swiftlint:disable:next force_cast
        textView = scrollView.documentView as! NSTextView
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 24, height: 18)
        textView.delegate = self
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.font = Theme.Fonts.mono(Theme.Fonts.mono.statusBar)
        readOnlyLabel.font = Theme.Fonts.ui(Theme.Fonts.ui.caption, weight: .semibold)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.wantsLayer = true
        headerBorder.wantsLayer = true
        imageView.isHidden = true

        for view in [header, scrollView, imageView, pathLabel, readOnlyLabel, headerBorder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(header)
        addSubview(scrollView)
        addSubview(imageView)
        header.addSubview(pathLabel)
        header.addSubview(readOnlyLabel)
        header.addSubview(headerBorder)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            pathLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            pathLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: readOnlyLabel.leadingAnchor, constant: -12),
            readOnlyLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            readOnlyLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            headerBorder.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerBorder.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerBorder.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerBorder.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Self.imageInset),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.imageInset),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.imageInset),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.imageInset),
        ])
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `url` in `theme`. Re-reads only when the file changed; re-renders only when either did.
    func show(_ url: URL, theme: Theme, home: String) {
        let fileChanged = url != self.url
        let themeChanged = theme != self.theme
        guard fileChanged || themeChanged else { return }
        self.url = url
        self.theme = theme
        self.home = home
        if fileChanged { content = FileViewerLoader.load(url) }
        applyChrome()
        render()
        if fileChanged { textView.scrollToBeginningOfDocument(nil) }
    }

    private static let imageInset: CGFloat = 16

    private func applyChrome() {
        layer?.backgroundColor = theme.terminalBackground.cgColor
        header.layer?.backgroundColor = theme.paneHeaderBackground.cgColor
        headerBorder.layer?.backgroundColor = theme.border.cgColor
        pathLabel.textColor = theme.paneHeaderPath.nsColor
        readOnlyLabel.textColor = theme.foregroundDim.nsColor
        scrollView.backgroundColor = theme.terminalBackground.nsColor
        textView.backgroundColor = theme.terminalBackground.nsColor
        textView.insertionPointColor = theme.foreground.nsColor
        textView.selectedTextAttributes = [.backgroundColor: theme.selection.nsColor]
        textView.linkTextAttributes = [
            .foregroundColor: theme.accent.nsColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        if let url {
            let path = url.path
            pathLabel.stringValue = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
    }

    private func render() {
        if case .image(let url) = content {
            if imageView.image == nil || imageView.url != url {
                imageView.show(NSImage(contentsOf: url).flatMap { $0.isValid ? $0 : nil }, url: url)
            }
            if imageView.image != nil {
                showImageBody(true)
                return
            }
            content = .notice("This image could not be decoded.")
        }
        showImageBody(false)

        let rendered: NSAttributedString
        switch content {
        case .markdown(let source):
            rendered = MarkdownRenderer.render(source, theme: theme)
        case .text(let text):
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = CGFloat(DesignTokens.Typography.fileViewerLineHeightMultiple.value)
            rendered = NSAttributedString(
                string: text,
                attributes: [
                    .font: Theme.Fonts.font(DesignTokens.Typography.fileViewerText),
                    .foregroundColor: theme.terminalForeground.nsColor,
                    .paragraphStyle: style,
                ])
        case .notice(let message):
            rendered = NSAttributedString(
                string: message,
                attributes: [
                    .font: Theme.Fonts.ui(Theme.Fonts.ui.title),
                    .foregroundColor: theme.foregroundMuted.nsColor,
                ])
        case .image, nil:
            rendered = NSAttributedString()
        }
        textView.textStorage?.setAttributedString(rendered)
    }

    private func showImageBody(_ image: Bool) {
        imageView.isHidden = !image
        scrollView.isHidden = image
        if !image { imageView.show(nil, url: nil) }
        let size = image ? imageView.pixelSize.map { "\($0.width) × \($0.height) · " } ?? "" : ""
        readOnlyLabel.stringValue = size + "READ-ONLY"
    }

    // MARK: NSTextViewDelegate

    /// Web links open in the browser; a relative link to a file next to this one opens in the
    /// viewer. Anything else is refused rather than handed to `NSWorkspace`, for the same reason
    /// `terminalLinkAction` refuses unknown schemes.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let string = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        if let url = URL(string: string), let scheme = url.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme)
        {
            NSWorkspace.shared.open(url)
            return true
        }
        guard let base = self.url?.deletingLastPathComponent() else { return true }
        let path = string.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        let decoded = path.removingPercentEncoding ?? path
        if !decoded.isEmpty,
            let target = FilePathResolver.resolve(decoded, bases: [base.path], home: home)
        {
            onOpenFile?(target)
        }
        return true
    }
}

/// An image tab's body: the picture centred, scaled down to fit and never up, and ⌘C-able.
final class ImageCanvas: NSImageView {
    /// The file the image came from, so ⌘C can put the file on the pasteboard next to the pixels.
    private(set) var url: URL?

    init() {
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyDown
        imageAlignment = .alignCenter
        imageFrameStyle = .none
        animates = true
        isEditable = false
        focusRingType = .none
        // The tab decides the size; a big image must not push the window around.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentCompressionResistancePriority(.defaultLow, for: orientation)
            setContentHuggingPriority(.defaultLow, for: orientation)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: NSImage?, url: URL?) {
        self.image = image
        self.url = image == nil ? nil : url
    }

    /// The largest bitmap's pixel dimensions; a vector image has no pixels, so its point size.
    var pixelSize: (width: Int, height: Int)? {
        guard let image else { return nil }
        let bitmap = image.representations
            .map { (width: $0.pixelsWide, height: $0.pixelsHigh) }
            .filter { $0.width > 0 && $0.height > 0 }
            .max { $0.width * $0.height < $1.width * $1.height }
        return bitmap ?? (Int(image.size.width.rounded()), Int(image.size.height.rounded()))
    }

    // Read-only, but still the keyboard's home while the tab is on screen: typing must not fall
    // through to the shell behind it.
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    @objc func copy(_ sender: Any?) {
        copy(to: .general)
    }

    func copy(to pasteboard: NSPasteboard) {
        guard let image else { return }
        pasteboard.clearContents()
        var items: [NSPasteboardWriting] = [image]
        if let url { items.append(url as NSURL) }
        pasteboard.writeObjects(items)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copy(_:)) ? image != nil : super.validateMenuItem(menuItem)
    }
}
