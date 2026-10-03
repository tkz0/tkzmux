// TerminalFaces — the terminal's four bundled JetBrains Mono faces at one size, and their cell
// metrics (WOR-312 S3).
//
// The `FT_Library` and its faces are not thread-safe and not Sendable, so they live together in one
// non-Sendable owner behind a `Mutex`; everything that leaves the lock is a value (metrics, names,
// outline boxes). The metrics are computed once, from the regular face's raw tables, through
// TkzRenderCore's shared formula, so they are the same numbers the Mac derives from CoreText.
//
// Pixel size is `pointSize * scale` in Double, exactly as the Mac's `FontSet` builds its CTFonts
// (14 pt at 1.6 is 22.400000000000002 px there too).

import Foundation
import Synchronization
import TkzRenderCore

public enum TerminalFacesError: Error, Sendable, Equatable {
    /// The TkzFontsFT resource bundle or its Fonts directory was not found.
    case bundledFontsNotFound
    /// A face has no head or hhea table, so no metrics.
    case notSFNT(file: String)
}

public final class TerminalFaces: Sendable {
    public let pointSize: CGFloat
    public let scale: CGFloat
    /// `pointSize * scale`: device pixels per em.
    public let pixelSize: CGFloat
    /// Cell geometry of the regular face, from its raw tables.
    public let metrics: CellMetrics

    private let owner: Mutex<Owner>

    /// The library and the four faces. Only ever touched inside `owner.withLock`.
    private final class Owner {
        let library: FreeTypeLibrary
        let faces: [FontStyle: FreeTypeFace]

        init(library: FreeTypeLibrary, faces: [FontStyle: FreeTypeFace]) {
            self.library = library
            self.faces = faces
        }
    }

    /// Opens the bundled faces.
    public convenience init(pointSize: CGFloat, scale: CGFloat) throws {
        guard let directory = BundledFonts.directory else { throw TerminalFacesError.bundledFontsNotFound }
        try self.init(pointSize: pointSize, scale: scale, fontDirectory: directory)
    }

    /// Opens the four `BundledFonts.jetBrainsMonoFile` faces from `fontDirectory`.
    public init(pointSize: CGFloat, scale: CGFloat, fontDirectory: URL) throws {
        let pixelSize = pointSize * scale
        let library = try FreeTypeLibrary()
        var faces: [FontStyle: FreeTypeFace] = [:]
        for style in FontStyle.allCases {
            let face = try FreeTypeFace(
                library: library,
                url: fontDirectory.appendingPathComponent(BundledFonts.jetBrainsMonoFile(style)))
            try face.requestPixelSize(pixelSize)
            faces[style] = face
        }
        let regularFile = BundledFonts.jetBrainsMonoFile(.regular)
        guard let tables = faces[.regular]?.tables(),
              let metrics = CellMetrics(tables: tables, pixelSize: pixelSize, scale: scale)
        else { throw TerminalFacesError.notSFNT(file: regularFile) }

        self.pointSize = pointSize
        self.scale = scale
        self.pixelSize = pixelSize
        self.metrics = metrics
        self.owner = Mutex(Owner(library: library, faces: faces))
    }

    /// The PostScript name of `style`'s face.
    public func postScriptName(_ style: FontStyle) -> String? {
        owner.withLock { $0.faces[style]?.postScriptName }
    }

    /// The raw table values of `style`'s face, in font units.
    public func tables(_ style: FontStyle) -> FontTables? {
        owner.withLock { $0.faces[style]?.tables() }
    }

    /// The unhinted outline box and advance of `scalar` in `style`'s face, at `pixelSize`.
    public func outlineMetrics(of scalar: Unicode.Scalar, style: FontStyle) -> GlyphOutlineMetrics? {
        owner.withLock { $0.faces[style]?.outlineMetrics(of: scalar) }
    }

    /// `no-stem-darkening` as this stack's library reports it for `module` (`nil`: module absent).
    public func isStemDarkeningDisabled(module: String) -> Bool? {
        owner.withLock { $0.library.isStemDarkeningDisabled(module: module) }
    }
}
