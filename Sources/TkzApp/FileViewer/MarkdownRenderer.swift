// Markdown → a styled `NSAttributedString`, with Foundation's own parser.
//
// `AttributedString(markdown:)` with `.full` syntax parses blocks as well as inline spans, but it
// only *annotates* them: every run carries a `presentationIntent` (paragraph, header, list item,
// code block, …) and the text has no newlines between blocks. This walks the runs once, inserting
// the breaks and list markers the intents describe and styling each run from theme tokens. No
// WebKit and no third-party parser, per the dependency rule.

import AppKit
import Foundation
import TkzCore

enum MarkdownRenderer {
    static let bodySize = CGFloat(DesignTokens.Typography.markdownBody.size)
    static let codeSize = CGFloat(DesignTokens.Typography.markdownCode.size)
    /// How far each list or quote level indents.
    static let indentStep = CGFloat(DesignTokens.Typography.markdownIndentStep.value)

    static func render(_ source: String, theme: Theme) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(
                string: source,
                attributes: [
                    .font: Theme.Fonts.mono(codeSize),
                    .foregroundColor: theme.terminalForeground.nsColor,
                ])
        }

        let out = NSMutableAttributedString()
        var previous: PresentationIntent?
        var paragraph = NSParagraphStyle.default
        var started = false

        for run in document.runs {
            let intent = run.presentationIntent
            if !started || intent != previous {
                if started {
                    // The break belongs to the paragraph it ends, so it takes that one's style.
                    out.append(
                        NSAttributedString(
                            string: separator(from: previous, to: intent),
                            attributes: [.paragraphStyle: paragraph]))
                }
                paragraph = paragraphStyle(for: intent)
                if let marker = listMarker(entering: intent, from: previous) {
                    out.append(
                        NSAttributedString(
                            string: marker,
                            attributes: [
                                .font: Theme.Fonts.ui(bodySize),
                                .foregroundColor: theme.foregroundMuted.nsColor,
                                .paragraphStyle: paragraph,
                            ]))
                }
                started = true
            }

            var text = String(document[run.range].characters)
            // A code block's text ends in its closing newline; the separator adds the break.
            if contains(intent, where: { if case .codeBlock = $0 { true } else { false } }),
                text.hasSuffix("\n")
            {
                text.removeLast()
            }
            out.append(
                NSAttributedString(
                    string: text,
                    attributes: attributes(for: run, intent: intent, paragraph: paragraph, theme: theme)))
            previous = intent
        }
        return out
    }

    // MARK: Blocks

    /// Cells of one table row sit on one line, a tab apart; every other block change is a line.
    static func separator(from old: PresentationIntent?, to new: PresentationIntent?) -> String {
        if let row = tableRowIdentity(old), row == tableRowIdentity(new) { return "\t" }
        return "\n"
    }

    private static func tableRowIdentity(_ intent: PresentationIntent?) -> Int? {
        intent?.components.first { component in
            switch component.kind {
            case .tableRow, .tableHeaderRow: true
            default: false
            }
        }?.identity
    }

    /// `•` or `3.` for the first paragraph of a list item, nothing for any later one.
    static func listMarker(entering new: PresentationIntent?, from old: PresentationIntent?) -> String? {
        guard let components = new?.components,
            let itemIndex = components.firstIndex(where: {
                if case .listItem = $0.kind { true } else { false }
            })
        else { return nil }
        let seen = Set(old?.components.map(\.identity) ?? [])
        guard !seen.contains(components[itemIndex].identity),
            case .listItem(let ordinal) = components[itemIndex].kind
        else { return nil }
        let ordered = components[(itemIndex + 1)...].first { component in
            switch component.kind {
            case .orderedList, .unorderedList: true
            default: false
            }
        }.map { if case .orderedList = $0.kind { true } else { false } } ?? false
        return ordered ? "\(ordinal).\t" : "\u{2022}\t"
    }

    static func paragraphStyle(for intent: PresentationIntent?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = CGFloat(DesignTokens.Typography.markdownLineHeightMultiple.value)
        style.paragraphSpacing = 8
        style.paragraphSpacingBefore = 2

        var listDepth = 0
        var quoteDepth = 0
        var isCode = false
        var isTable = false
        for component in intent?.components ?? [] {
            switch component.kind {
            case .header(let level):
                style.paragraphSpacingBefore = level <= 2 ? 14 : 10
                style.paragraphSpacing = 6
            case .orderedList, .unorderedList: listDepth += 1
            case .blockQuote: quoteDepth += 1
            case .codeBlock: isCode = true
            case .table: isTable = true
            default: break
            }
        }
        if listDepth > 0 { style.paragraphSpacing = 3 }
        if isCode {
            style.lineHeightMultiple = CGFloat(DesignTokens.Typography.markdownCodeLineHeightMultiple.value)
            style.paragraphSpacing = 0
            style.paragraphSpacingBefore = 0
        }

        let indent = CGFloat(listDepth + quoteDepth) * indentStep
        style.headIndent = indent
        // The marker hangs one step left of the text, and its tab lands on the text's edge.
        style.firstLineHeadIndent = listDepth > 0 ? indent - indentStep : indent
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        if isTable {
            style.tabStops = (1...12).map {
                NSTextTab(textAlignment: .left, location: indent + CGFloat($0) * 160)
            }
            style.paragraphSpacing = 3
        }
        return style
    }

    // MARK: Runs

    static func attributes(
        for run: AttributedString.Runs.Run,
        intent: PresentationIntent?,
        paragraph: NSParagraphStyle,
        theme: Theme
    ) -> [NSAttributedString.Key: Any] {
        var size = bodySize
        var weight = NSFont.Weight.regular
        var monospaced = false
        var color = theme.foreground.nsColor
        var background: NSColor?

        for component in intent?.components ?? [] {
            switch component.kind {
            case .header(let level):
                size = headerSize(level)
                weight = level <= 2 ? .bold : .semibold
            case .codeBlock:
                monospaced = true
                size = codeSize
                background = theme.paneHeaderBackground.nsColor
            case .blockQuote:
                color = theme.foregroundMuted.nsColor
            case .tableHeaderRow:
                weight = .semibold
            default:
                break
            }
        }

        let inline = run.inlinePresentationIntent ?? []
        if inline.contains(.code) {
            monospaced = true
            size -= 1
            background = theme.paneHeaderBackground.nsColor
        }
        if inline.contains(.stronglyEmphasized) { weight = .bold }

        var font = monospaced ? Theme.Fonts.mono(size, weight: weight) : Theme.Fonts.ui(size, weight: weight)
        if inline.contains(.emphasized) { font = italic(font) }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if let background { attributes[.backgroundColor] = background }
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = run.link {
            attributes[.link] = link
            attributes[.foregroundColor] = theme.accent.nsColor
        }
        return attributes
    }

    static func headerSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: CGFloat(DesignTokens.Typography.markdownHeading1.size)
        case 2: CGFloat(DesignTokens.Typography.markdownHeading2.size)
        case 3: CGFloat(DesignTokens.Typography.markdownHeading3.size)
        default: CGFloat(DesignTokens.Typography.markdownHeading4.size)
        }
    }

    private static func italic(_ font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits.union(.italic)
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize)
            ?? font
    }

    private static func contains(
        _ intent: PresentationIntent?, where predicate: (PresentationIntent.Kind) -> Bool
    ) -> Bool {
        intent?.components.contains { predicate($0.kind) } ?? false
    }
}
