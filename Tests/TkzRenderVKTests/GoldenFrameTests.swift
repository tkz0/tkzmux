// GoldenFrameTests — the Vulkan renderer against the Mac's golden frames (WOR-313 S6).
//
// Linux twins of `blockCursorGolden` and `barCursorGolden` (Tests/TkzTerminalRenderTests): the same
// screen, replayed from the same synthetic recording, at the goldens' 12.5 pt and backing scale 2,
// read back from the render target (never a screenshot, ADR-0003 §4) and compared with the
// committed Mac PNGs. The goldens are not copied or regenerated: they stay the Mac's.
//
// Not byte for byte. The Mac draws glyphs with CoreText and Linux with FreeType, and the goldens
// were made on a developer Mac the CI runner does not even match (ADR-0003, Context 3). So the
// frame is scored the way ADR-0003 scores a component, cell by cell from the terminal grid:
//
//   cjkEmoji   the wide CJK and emoji cells, masked: Apple Color Emoji and PingFang have no
//              Linux equivalent (ADR-0003 §6).
//   glyph-free every other cell holding no glyph (spaces, empty cells; the selection tint and the
//              cursor on them): every pixel within ±1 per channel. Backgrounds, the selection and
//              the cursor rects are pure GPU work over identical instance bytes, so they get the
//              L3 shader bound, not a raster tolerance.
//   text       the cells holding a glyph, as runs of adjacent cells in a row: each run's SSIM
//              ≥ l5TextMinSSIM, as an L5 text box.
//   whole      the frame's SSIM over everything unmasked ≥ l5ComponentMinSSIM.
//
// SSIM is ADR-0003's (Wang et al. 2004: 11×11 Gaussian, σ 1.5, on the luma of the gamma-encoded
// bytes, the mean over windows whose centre is unmasked). TODO(WOR-322 S1): score through the
// TkzParity comparator once it exists; `FrameScore` is a stand-in implementing the same rules.
//
// The 1.6 scale is compared with WOR-322 S2's terminal-frame reference (the Mac's `vtdump render
// --scale 1.6` of this screen), skipped by name until that reference is committed.
//
// Lavapipe determinism: the frame is rendered twice, on two devices and two renderers, and must be
// byte-identical; its SHA-256 is printed so two CI runs can be compared.

import Foundation
import GhosttyVt
import Testing
import TkzCore
import TkzFontsFT
import TkzPNG
import TkzPlatform
import TkzRenderCore
import TkzTerminalCore
@testable import TkzRenderVK

// MARK: - Thresholds (ADR-0003)

/// The ADR-0003 constants this comparison uses, under their ADR names (WOR-322 S1 moves them into
/// `ParityThresholds.swift`).
enum GoldenThresholds {
    /// L5: every text-run box's SSIM.
    static let l5TextMinSSIM = 0.90
    /// L5: the whole component's SSIM, masked.
    static let l5ComponentMinSSIM = 0.95
    /// L3: per channel, every pixel. Applied to the glyph-free cells.
    static let l3ChannelTolerance = 1
}

// MARK: - The golden screen

extension RendererScreen {
    /// The screen's bytes as a `.tkzrec`, so the twin goes through the recording reader as the
    /// Mac goldens and `vtdump render` do.
    static func makeRecording() throws -> RecordingReader {
        let header = RecordingHeader(cols: columns, rows: rows, argv: ["synthetic"], env: [:],
                                     startedAt: 0, note: "M1.5 golden frame")
        let writer = RecordingWriter(header: header)
        var data = try writer.headerLine()
        data.append(writer.encode(.output(elapsedNanos: 0, bytes: Data(output.utf8))))
        return try RecordingReader(data: data)
    }

    static func makeRecordedSession(theme: Theme = .default) throws -> TerminalSession {
        let session = try TerminalSession(options: TerminalSessionOptions(cols: columns, rows: rows, theme: theme))
        try makeRecording().replay(into: session)
        return session
    }

    /// What each cell of the screen holds, from the screen's own text: the escape sequences
    /// dropped, then one column per scalar, two for an emoji-presentation or ideographic one.
    static func cellKinds() -> [[CellKind]] {
        var grid = [[CellKind]](repeating: [CellKind](repeating: .glyphFree, count: Int(columns)), count: Int(rows))
        let lines = output.components(separatedBy: "\r\n")
        for (row, line) in lines.prefix(Int(rows)).enumerated() {
            var column = 0
            var scalars = line.unicodeScalars.makeIterator()
            while let scalar = scalars.next() {
                if scalar == "\u{1b}" {
                    // CSI: parameters, then a final byte in 0x40...0x7E.
                    guard scalars.next() == "[" else { continue }
                    while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
                    continue
                }
                let wide = scalar.properties.isEmojiPresentation || scalar.properties.isIdeographic
                let kind: CellKind = wide ? .cjkEmoji : scalar == " " ? .glyphFree : .text
                for span in 0..<(wide ? 2 : 1) where column + span < Int(columns) {
                    grid[row][column + span] = kind
                }
                column += wide ? 2 : 1
            }
        }
        return grid
    }
}

enum CellKind: Equatable {
    case glyphFree, text, cjkEmoji
}

enum GoldenFonts {
    /// `pointSize` at `scale` through FreeType, thickened like the Mac's default glyph cache.
    /// Fallback faces come from the pinned parity fonts when they are fetched (CI), else from the
    /// system; only the masked cells use them.
    static func cache(pointSize: Double, scale: Double) throws -> GlyphCache {
        let parity = FontconfigConfiguration.defaultParityFontDirectory
        let fetched = (try? FileManager.default.contentsOfDirectory(atPath: parity.path))?.contains { !$0.hasPrefix(".") } ?? false
        let configuration: FontconfigConfiguration = fetched
            ? .parity(bundled: BundledFonts.fontDirectories, testFonts: parity, cacheDirectory: RendererFonts.cacheDirectory)
            : .system(bundled: BundledFonts.fontDirectories, cacheDirectory: RendererFonts.cacheDirectory)
        let faces = try TerminalFaces(pointSize: pointSize, scale: scale, fallback: FontFallback(configuration: configuration))
        return GlyphCache(source: FreeTypeGlyphSource(faces: faces))
    }
}

/// Installs a viewport selection through libghostty, as the Mac golden does.
/// TkzRenderCoreTests and TkzTerminalRenderTests carry the same helper; test targets cannot share
/// a file.
func setSelection(
    _ session: TerminalSession, startX: UInt16, startY: UInt32, endX: UInt16, endY: UInt32
) throws {
    var result = GHOSTTY_SUCCESS
    session.withTerminal { terminal in
        func gridRef(_ x: UInt16, _ y: UInt32) -> GhosttyGridRef? {
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_VIEWPORT
            point.value.coordinate = GhosttyPointCoordinate(x: x, y: y)
            var ref = GhosttyGridRef()
            ref.size = MemoryLayout<GhosttyGridRef>.stride
            guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
            return ref
        }
        guard let start = gridRef(startX, startY), let end = gridRef(endX, endY) else {
            result = GHOSTTY_INVALID_VALUE
            return
        }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.stride
        selection.start = start
        selection.end = end
        result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }
    guard result == GHOSTTY_SUCCESS else {
        throw RenderError(result: Int32(result.rawValue), operation: "ghostty_terminal_set(SELECTION)")
    }
}

// MARK: - References

enum GoldenReference {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The Mac's committed goldens, read in place: `Tests/TkzTerminalRenderTests/Fixtures/<name>`.
    static func macGolden(_ name: String) -> URL {
        repoRoot.appendingPathComponent("Tests/TkzTerminalRenderTests/Fixtures/\(name)")
    }

    /// WOR-322 S2's terminal-frame reference of the golden screen at `scale`. TODO(WOR-322 S2): the
    /// exporter writes it here (the name is this test's until the exporter fixes it).
    static func parityTerminalFrame(_ name: String, scale: Double) -> URL {
        repoRoot.appendingPathComponent("Tests/Parity/References/terminal/\(name)-\(scale == 2 ? "2" : String(scale))x.png")
    }

    /// Premultiplied BGRA rows of a PNG, the layout the renderer reads back.
    static func decode(_ url: URL) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        let image = try PNG.decode([UInt8](try Data(contentsOf: url)))
        return (image.width, image.height, image.premultipliedBGRA())
    }
}

// MARK: - Scoring

/// One frame scored against a reference of the same size, cell by cell (see the file comment).
struct FrameScore: CustomStringConvertible {
    struct TextRun {
        let row: Int
        let columns: Range<Int>
        let ssim: Double
    }

    let glyphFreePixels: Int
    /// Glyph-free pixels with a channel more than `l3ChannelTolerance` off.
    let glyphFreeOutliers: Int
    let glyphFreeWorstDelta: Int
    /// The first outlier, for the failure message.
    let firstOutlier: (x: Int, y: Int, rendered: [UInt8], reference: [UInt8])?
    let textRuns: [TextRun]
    let frameSSIM: Double
    let maskedFraction: Double

    var worstTextRun: TextRun? { textRuns.min { $0.ssim < $1.ssim } }

    init(rendered: [UInt8], reference: [UInt8], width: Int, height: Int,
         cell: (width: Int, height: Int), kinds: [[CellKind]]) {
        precondition(rendered.count == width * height * 4 && reference.count == rendered.count)
        func kind(x: Int, y: Int) -> CellKind? {
            let row = y / cell.height, column = x / cell.width
            guard row < kinds.count, column < kinds[row].count else { return nil }  // letterbox
            return kinds[row][column]
        }

        var pixels = 0, outliers = 0, worst = 0, masked = 0
        var first: (x: Int, y: Int, rendered: [UInt8], reference: [UInt8])?
        for y in 0..<height {
            for x in 0..<width {
                let k = kind(x: x, y: y)
                if k == .cjkEmoji { masked += 1 }
                guard k == .glyphFree else { continue }
                pixels += 1
                let offset = (y * width + x) * 4
                var delta = 0
                for channel in 0..<4 { delta = max(delta, abs(Int(rendered[offset + channel]) - Int(reference[offset + channel]))) }
                worst = max(worst, delta)
                if delta > GoldenThresholds.l3ChannelTolerance {
                    outliers += 1
                    if first == nil {
                        first = (x, y, Array(rendered[offset..<offset + 4]), Array(reference[offset..<offset + 4]))
                    }
                }
            }
        }
        glyphFreePixels = pixels
        glyphFreeOutliers = outliers
        glyphFreeWorstDelta = worst
        firstOutlier = first
        maskedFraction = Double(masked) / Double(width * height)

        let map = SSIMMap(a: rendered, b: reference, width: width, height: height)
        frameSSIM = map.mean { kind(x: $0, y: $1) != .cjkEmoji }
        var runs: [TextRun] = []
        for (row, line) in kinds.enumerated() {
            var column = 0
            while column < line.count {
                guard line[column] == .text else { column += 1; continue }
                let start = column
                while column < line.count, line[column] == .text { column += 1 }
                let box = (x: start * cell.width..<column * cell.width, y: row * cell.height..<(row + 1) * cell.height)
                runs.append(TextRun(row: row, columns: start..<column,
                                    ssim: map.mean { box.x.contains($0) && box.y.contains($1) }))
            }
        }
        textRuns = runs
    }

    var description: String {
        var text = "glyph-free: \(glyphFreeOutliers) of \(glyphFreePixels) pixels beyond ±\(GoldenThresholds.l3ChannelTolerance), "
            + "worst channel delta \(glyphFreeWorstDelta)"
        if let first = firstOutlier { text += ", first at (\(first.x), \(first.y)): \(first.rendered) vs \(first.reference)" }
        if let worst = worstTextRun {
            text += "; text runs: \(textRuns.count), worst SSIM \(String(format: "%.4f", worst.ssim)) "
                + "(row \(worst.row), columns \(worst.columns.lowerBound)..<\(worst.columns.upperBound))"
        }
        text += "; frame SSIM \(String(format: "%.4f", frameSSIM)), masked \(String(format: "%.2f", maskedFraction * 100))%"
        return text
    }
}

/// ADR-0003's SSIM map between two equal-sized BGRA images: an 11×11 Gaussian window (σ 1.5),
/// K1 0.01, K2 0.03, L 255, on Y′ = 0.2126 R′ + 0.7152 G′ + 0.0722 B′ of the encoded bytes. A window
/// is centred on every pixel at least 5 px from the edge.
struct SSIMMap {
    static let radius = 5
    static let weights: [Double] = {
        let raw = (-radius...radius).map { exp(-Double($0 * $0) / (2 * 1.5 * 1.5)) }
        let sum = raw.reduce(0, +)
        return raw.map { $0 / sum }
    }()

    let width: Int
    let height: Int
    /// SSIM per window centre, row-major over the full image; NaN where no window fits.
    private let values: [Double]

    init(a: [UInt8], b: [UInt8], width: Int, height: Int) {
        self.width = width
        self.height = height
        func luma(_ pixels: [UInt8]) -> [Double] {
            (0..<width * height).map { index in
                let offset = index * 4  // B, G, R, A
                return 0.2126 * Double(pixels[offset + 2]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset])
            }
        }
        let x = luma(a), y = luma(b)
        let r = Self.radius
        // Separable blur, valid region only.
        func blur(_ image: [Double]) -> [Double] {
            var horizontal = [Double](repeating: .nan, count: width * height)
            for row in 0..<height {
                for column in r..<max(r, width - r) {
                    var sum = 0.0
                    for k in -r...r { sum += Self.weights[k + r] * image[row * width + column + k] }
                    horizontal[row * width + column] = sum
                }
            }
            var out = [Double](repeating: .nan, count: width * height)
            for row in r..<max(r, height - r) {
                for column in r..<max(r, width - r) {
                    var sum = 0.0
                    for k in -r...r { sum += Self.weights[k + r] * horizontal[(row + k) * width + column] }
                    out[row * width + column] = sum
                }
            }
            return out
        }
        let muX = blur(x), muY = blur(y)
        let xx = blur(zip(x, x).map(*)), yy = blur(zip(y, y).map(*)), xy = blur(zip(x, y).map(*))
        let c1 = (0.01 * 255) * (0.01 * 255), c2 = (0.03 * 255) * (0.03 * 255)
        values = (0..<width * height).map { i in
            let mx = muX[i], my = muY[i]
            let vx = xx[i] - mx * mx, vy = yy[i] - my * my, cxy = xy[i] - mx * my
            return ((2 * mx * my + c1) * (2 * cxy + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2))
        }
    }

    /// The mean SSIM over the window centres `include` accepts; 1 when there are none.
    func mean(_ include: (Int, Int) -> Bool) -> Double {
        var sum = 0.0, count = 0
        for y in 0..<height {
            for x in 0..<width where include(x, y) {
                let value = values[y * width + x]
                guard !value.isNaN else { continue }
                sum += value
                count += 1
            }
        }
        return count == 0 ? 1 : sum / Double(count)
    }
}

// MARK: - Rendering

/// A frame read back from the render target.
private struct GoldenFrame {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let cell: (width: Int, height: Int)
    let outcome: RenderOutcome
    let deviceName: String
}

/// The golden screen through a fresh device and renderer at `pointSize` and `scale`, read back.
private func renderGolden(pointSize: Double = 12.5, scale: Double = 2, configure: (TerminalSession) throws -> Void) throws -> GoldenFrame {
    let device = try VulkanTestDevice.make()
    let renderer = try VulkanTerminalRenderer(device: device, glyphCache: try GoldenFonts.cache(pointSize: pointSize, scale: scale))
    let session = try RendererScreen.makeRecordedSession()
    try configure(session)
    let surface = TerminalSurface()
    try surface.attach(session)
    let size = renderer.drawableSize(columns: Int(RendererScreen.columns), rows: Int(RendererScreen.rows))
    let target = try OffscreenTarget(device: device, width: UInt32(size.width), height: UInt32(size.height))
    let outcome = try renderer.render(surface: surface, to: target)
    let pixels = try target.bgraBytes()
    surface.detach()
    VulkanTestDevice.expectNoValidationErrors(device)
    let metrics = renderer.glyphCache.metrics
    return GoldenFrame(pixels: pixels, width: size.width, height: size.height, cell: (metrics.width, metrics.height),
                       outcome: outcome, deviceName: device.candidate.name)
}

/// The golden screen with a block cursor and a selection over row 7 (`blockCursorGolden`).
private func blockCursorScreen(_ session: TerminalSession) throws {
    try setSelection(session, startX: 0, startY: 7, endX: 15, endY: 7)
}

/// The golden screen with a bar cursor (DECSCUSR 5) and no selection (`barCursorGolden`).
private func barCursorScreen(_ session: TerminalSession) throws {
    session.write(ptyText: "\u{1b}[5 q")
}

/// Scores `frame` against the PNG at `url` and asserts the thresholds.
private func expectMeetsThresholds(
    _ frame: GoldenFrame, reference url: URL, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let reference = try GoldenReference.decode(url)
    #expect(reference.width == frame.width && reference.height == frame.height,
            "\(url.lastPathComponent) is \(reference.width)×\(reference.height), rendered \(frame.width)×\(frame.height)",
            sourceLocation: sourceLocation)
    guard reference.width == frame.width, reference.height == frame.height else { return }

    let score = FrameScore(rendered: frame.pixels, reference: reference.pixels, width: frame.width, height: frame.height,
                           cell: frame.cell, kinds: RendererScreen.cellKinds())
    print("\(url.lastPathComponent): \(score)")
    #expect(score.glyphFreePixels > 0)
    #expect(score.glyphFreeOutliers == 0, "\(score)", sourceLocation: sourceLocation)
    #expect(score.textRuns.count > 10, "the screen has text on every row", sourceLocation: sourceLocation)
    #expect((score.worstTextRun?.ssim ?? 0) >= GoldenThresholds.l5TextMinSSIM, "\(score)", sourceLocation: sourceLocation)
    #expect(score.frameSSIM >= GoldenThresholds.l5ComponentMinSSIM, "\(score)", sourceLocation: sourceLocation)
}

// MARK: - Golden frames

@Suite("Vulkan renderer: golden frames", .serialized,
       .enabled(if: VulkanTestEnvironment.runs, VulkanTestEnvironment.skipReason))
struct VulkanGoldenFrameTests {

    @Test("the golden frame (block cursor, selection) meets the parity thresholds against the Mac golden at 2.0")
    func blockCursorGolden() throws {
        let frame = try renderGolden(configure: blockCursorScreen)
        #expect(frame.outcome.didEncode)
        #expect(frame.outcome.update.dirty == .full)
        #expect(frame.outcome.glyphCount > 40, "the golden screen is far from empty")
        #expect(frame.outcome.rectCount >= 4, "underline, curly, dashed, strike and the cursor")
        try expectMeetsThresholds(frame, reference: GoldenReference.macGolden("golden-block-cursor.png"))
    }

    @Test("the golden frame with a bar cursor meets the parity thresholds against the Mac golden at 2.0")
    func barCursorGolden() throws {
        let frame = try renderGolden(configure: barCursorScreen)
        #expect(frame.outcome.didEncode)
        try expectMeetsThresholds(frame, reference: GoldenReference.macGolden("golden-bar-cursor.png"))
    }

    @Test("two devices and two renderers draw the golden frame to the same bytes")
    func goldenFrameIsDeterministic() throws {
        let first = try renderGolden(configure: blockCursorScreen)
        let second = try renderGolden(configure: blockCursorScreen)
        #expect(difference(first.pixels, second.pixels, width: first.width) == nil)
        let digest = SHA256.hash(data: Data(first.pixels)).description
        print("golden-block-cursor on \(first.deviceName): sha256 \(digest)")
    }

    /// WOR-322 S2 renders GoldenScreen with `vtdump render --scale 1.6`: the theme's terminal font
    /// (14 pt), no selection, the block cursor. So does this.
    @Test("at 1.6 the golden screen meets the parity thresholds against the Mac's 1.6 terminal frame",
          .enabled(if: FileManager.default.fileExists(atPath: GoldenReference.parityTerminalFrame("golden-screen", scale: 1.6).path),
                   "DEFERRED: Tests/Parity/References/terminal/golden-screen-1.6x.png comes from WOR-322 S2 on the reference runner"))
    func goldenScreenAtParityScale() throws {
        let frame = try renderGolden(pointSize: Theme.default.fontMono.terminal, scale: 1.6) { _ in }
        try expectMeetsThresholds(frame, reference: GoldenReference.parityTerminalFrame("golden-screen", scale: 1.6))
    }
}
