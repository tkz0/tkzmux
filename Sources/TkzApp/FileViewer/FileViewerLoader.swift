// Reading a file for the read-only viewer.

import Foundation
import UniformTypeIdentifiers

enum FileViewerContent: Equatable {
    case markdown(String)
    case text(String)
    /// An image file. Only classified here; the view decodes it, since decoding is display work.
    case image(URL)
    /// Nothing to render: binary, too large, or unreadable. The string says which.
    case notice(String)
}

enum FileViewerLoader {
    /// Past this the viewer declines. `NSTextView` copes with more, but a multi-megabyte log is not
    /// what ⌘-click on a path is for, and the read happens on the main thread.
    static let maxBytes = 5 * 1024 * 1024

    /// Images get a far larger allowance: a Retina screenshot alone is routinely past `maxBytes`,
    /// and `NSImage` decodes lazily rather than holding the whole file as text.
    static let maxImageBytes = 50 * 1024 * 1024

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// By extension, the way Finder decides: png, jpeg, gif, heic, webp, tiff, svg and friends.
    /// PDF is a document, not an image, and stays out.
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    static func load(_ url: URL) -> FileViewerContent {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let isImage = isImage(url)
        guard size <= (isImage ? maxImageBytes : maxBytes) else {
            let megabytes = Double(size) / 1_048_576
            return .notice(String(format: "This file is too large to preview (%.1f MB).", megabytes))
        }
        if isImage {
            return FileManager.default.isReadableFile(atPath: url.path)
                ? .image(url) : .notice("This file could not be read.")
        }
        guard let data = try? Data(contentsOf: url) else {
            return .notice("This file could not be read.")
        }
        // A NUL in the first few KB is the usual test git and `file` use for "binary".
        guard !data.prefix(8192).contains(0) else {
            return .notice("This looks like a binary file, so there is nothing to show.")
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return isMarkdown(url) ? .markdown(text) : .text(text)
    }
}
