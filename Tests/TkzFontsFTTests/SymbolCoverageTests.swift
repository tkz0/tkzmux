// SymbolCoverageTests — Tkzmux Symbols, the bundled symbol subset, and the fallback order that puts
// it before fontconfig (WOR-312 S7).
//
// The font is checked against scripts/symbol-subset.json (its SHA-256, its cmap, its name and its
// licence). Resolution is checked through both users: the terminal (`TerminalFaces`) and chrome
// mono (`GlyphCascade.chromeMono`). An inventory glyph must come from a bundled face without a
// single fontconfig call, so the result cannot depend on the machine's fonts. The comparisons with
// the Mac (bboxes from S1's symbol inventory, advances from S2's chrome dump) skip until those
// references are committed.

import CFreeType
import Foundation
import Testing
import TkzPlatform
import TkzRenderCore
@testable import TkzFontsFT

/// scripts/symbol-subset.json as the tests read it.
struct SymbolRecipe: Decodable {
    struct Output: Decodable {
        let font: String
        let license: String
        let sha256: String
    }
    struct Source: Decodable {
        let file: String
        let sha256: String
        let url: String
        let license: String
        let reservedFontNames: [String]
    }
    struct Glyph: Decodable {
        let scalar: String
        let group: String
        let source: String

        var unicodeScalar: Unicode.Scalar? { UInt32(scalar, radix: 16).flatMap(Unicode.Scalar.init) }
    }
    let family: String
    let postScriptName: String
    let output: Output
    let sources: [String: Source]
    let glyphs: [Glyph]

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func load() throws -> SymbolRecipe {
        try JSONDecoder().decode(SymbolRecipe.self,
                                 from: Data(contentsOf: repoRoot.appendingPathComponent("scripts/symbol-subset.json")))
    }
}

@Suite("Symbol subset")
struct SymbolCoverageTests {
    private static let styles = FontStyle.allCases
    private static let bundledNames: Set<String> = Set(FontStyle.allCases.map {
        "JetBrainsMono-" + ["Regular", "Bold", "Italic", "BoldItalic"][Int($0.rawValue)]
    }).union([BundledSymbols.postScriptName])

    /// A fallback no other test has touched, so its call count starts at 0. Creating it calls
    /// nothing; only a cluster no bundled face covers would.
    private static func freshFallback() -> FontFallback {
        FontFallback(configuration: .system(bundled: BundledFonts.fontDirectories, cacheDirectory: TestFallbacks.cacheDirectory),
                     isMainThread: { false })
    }

    private static func hex(_ scalar: Unicode.Scalar) -> String { "U+" + String(scalar.value, radix: 16, uppercase: true) }

    // MARK: The font

    @Test("the subset in the source tree and in the bundle is what make-symbol-subset.py wrote")
    func pinned() throws {
        let recipe = try SymbolRecipe.load()
        let source = SymbolRecipe.repoRoot.appendingPathComponent(recipe.output.font)
        #expect(SHA256.hash(data: try Data(contentsOf: source)).description == recipe.output.sha256)
        let bundled = try #require(BundledSymbols.url)
        #expect(try Data(contentsOf: bundled) == (try Data(contentsOf: source)))
        #expect(source.lastPathComponent == BundledSymbols.fileName)
    }

    @Test("it is named Tkzmux Symbols, keeps no source or reserved name, and is one plain outline face")
    func naming() throws {
        let recipe = try SymbolRecipe.load()
        #expect(recipe.family == BundledSymbols.family && recipe.postScriptName == BundledSymbols.postScriptName)
        let library = try FreeTypeLibrary()
        let face = try FreeTypeFace(library: library, url: try #require(BundledSymbols.url))
        #expect(face.postScriptName == BundledSymbols.postScriptName)
        #expect(face.handle.pointee.family_name.map { String(cString: $0) } == BundledSymbols.family)
        #expect(face.handle.pointee.style_name.map { String(cString: $0) } == "Regular")
        #expect(face.handle.pointee.num_faces == 1)
        // Never colour, so ✳ cannot come out of it as an emoji; no strikes, no bold.
        #expect(face.handle.pointee.face_flags & FT_Long(FT_FACE_FLAG_COLOR) == 0)
        #expect(face.isScalable && !face.hasBitmapStrikes && !face.isBold)
        for (key, source) in recipe.sources {
            #expect(source.license == "OFL-1.1", "\(key)")
            for reserved in source.reservedFontNames {
                #expect(!recipe.family.localizedCaseInsensitiveContains(reserved), "\(key) reserves \(reserved)")
            }
        }
        // "Noto" is Google's trademark; a modified subset does not carry it.
        #expect(!recipe.family.contains("Noto") && !recipe.postScriptName.contains("Noto"))
    }

    @Test("OFL.txt ships next to it, with every source's copyright line")
    func licenceShips() throws {
        let directory = try #require(BundledSymbols.directory)
        let text = try String(contentsOf: directory.appendingPathComponent("OFL.txt"), encoding: .utf8)
        #expect(text.contains("SIL Open Font License, Version 1.1"))
        #expect(text.contains("Copyright 2022 The Noto Project Authors (https://github.com/notofonts/symbols)"))
        #expect(text.contains("Copyright 2022 The Noto Project Authors (https://github.com/notofonts/math)"))
        let recipe = try SymbolRecipe.load()
        let source = SymbolRecipe.repoRoot.appendingPathComponent(recipe.output.license)
        #expect(try Data(contentsOf: source) == (try Data(contentsOf: directory.appendingPathComponent("OFL.txt"))))
    }

    @Test("the recipe and BundledSymbols list the same inventory, and the subset maps every glyph it owns")
    func inventoryMatchesRecipe() throws {
        let recipe = try SymbolRecipe.load()
        let recipeScalars = recipe.glyphs.compactMap(\.unicodeScalar)
        #expect(recipeScalars.count == recipe.glyphs.count)
        #expect(recipeScalars == BundledSymbols.inventory)
        #expect(Set(recipeScalars).count == recipeScalars.count)
        #expect(recipe.glyphs.filter { $0.group == "agent" }.compactMap(\.unicodeScalar) == BundledSymbols.agentGlyphs)
        #expect(recipe.glyphs.filter { $0.group == "chrome" }.compactMap(\.unicodeScalar) == BundledSymbols.chromeGlyphs)
        #expect(recipe.glyphs.filter { $0.group == "modifier" }.compactMap(\.unicodeScalar) == BundledSymbols.modifierGlyphs)
        #expect(recipe.glyphs.filter { $0.group == "ui" }.compactMap(\.unicodeScalar) == BundledSymbols.uiGlyphs)

        let library = try FreeTypeLibrary()
        let face = try FreeTypeFace(library: library, url: try #require(BundledSymbols.url))
        try face.requestPixelSize(28)
        let mono = try FreeTypeFace(library: library, url: try #require(BundledFonts.directory)
            .appendingPathComponent(BundledFonts.jetBrainsMonoFile(.regular)))
        var mapped = 0
        for glyph in recipe.glyphs {
            let scalar = try #require(glyph.unicodeScalar)
            let index = FT_Get_Char_Index(face.handle, FT_ULong(scalar.value))
            if glyph.source == "primary" {
                #expect(index == 0, "\(Self.hex(scalar)) is the primary faces'")
                #expect(FT_Get_Char_Index(mono.handle, FT_ULong(scalar.value)) != 0, "\(Self.hex(scalar))")
            } else {
                #expect(index != 0, "the subset lacks \(Self.hex(scalar))")
                #expect(face.outlineMetrics(of: scalar).map { $0.width > 0 && $0.height > 0 } == true,
                        "\(Self.hex(scalar)) has no ink")
                mapped += 1
            }
        }
        // Nothing else: .notdef plus one glyph per owned scalar.
        #expect(Int(face.handle.pointee.num_glyphs) == mapped + 1)
    }

    // MARK: Terminal

    @Test("no inventory glyph resolves to a system font in the terminal, in any style, and none asks fontconfig",
          arguments: [(14.0, 2.0), (14.0, 1.6)] as [(CGFloat, CGFloat)])
    func terminalInventory(pointSize: CGFloat, scale: CGFloat) throws {
        let fallback = Self.freshFallback()
        let faces = try TerminalFaces(pointSize: pointSize, scale: scale, fallback: fallback)
        for scalar in BundledSymbols.inventory {
            for style in Self.styles {
                let shaped = faces.shape([scalar], style: style)
                let name = faces.name(of: shaped.face)
                #expect(Self.bundledNames.contains(name), "\(Self.hex(scalar)) \(style) → \(name)")
                #expect(!shaped.isEmpty && !shaped.isColor, "\(Self.hex(scalar)) \(style)")
                if let descriptor = faces.fallbackFace(of: shaped.face) {
                    #expect(descriptor == BundledSymbols.face)
                }
                let glyph = try #require(faces.rasterize(shaped, style: style), "\(Self.hex(scalar)) \(style)")
                #expect(glyph.bytesPerPixel == 1 && glyph.pixels.contains { $0 != 0 })
            }
        }
        #expect(fallback.statistics.fontconfigCalls == 0)
    }

    @Test("✳ is never colour: monochrome from the subset in every style, also where Noto Color Emoji is installed")
    func eightSpokedAsteriskIsText() throws {
        var fallbacks = [TestFallbacks.system]
        if TestFallbacks.parityFontsPresent { fallbacks.append(TestFallbacks.parity) }
        for fallback in fallbacks {
            let faces = try TerminalFaces(pointSize: 14, scale: 2, fallback: fallback)
            for style in Self.styles {
                let shaped = faces.shape(["\u{2733}"], style: style)
                #expect(!shaped.isColor)
                #expect(faces.name(of: shaped.face) == BundledSymbols.postScriptName)
                let glyph = try #require(faces.rasterize(shaped, style: style))
                #expect(!glyph.isColor && glyph.bytesPerPixel == 1)
            }
        }
        let cascade = try GlyphCascade.chromeMono(fallback: Self.freshFallback())
        let resolved = cascade.resolve(["\u{2733}"])
        #expect(resolved.source == .symbols && !resolved.isColor)
    }

    @Test("an explicit emoji request still goes to the colour list: ✳ + VS16",
          .enabled(if: ColorFixtures.notoColorEmoji != nil, "needs Noto Color Emoji (system or parity fonts)"))
    func variationSelectorStillWins() throws {
        let faces = try TerminalFaces(pointSize: 14, scale: 2, fallback: ColorFixtures.fallback)
        let shaped = faces.shape(["\u{2733}", "\u{FE0F}"])
        #expect(shaped.isColor)
        #expect(faces.name(of: shaped.face) == "NotoColorEmoji")
    }

    @Test("without the subset the same glyphs go to fontconfig: the order is primary, subset, fontconfig")
    func orderWithoutSubset() throws {
        let fallback = Self.freshFallback()
        let faces = try TerminalFaces(pointSize: 14, scale: 2, fallback: fallback, symbols: nil)
        let shaped = faces.shape(["\u{23BF}"])
        #expect(faces.name(of: shaped.face) != BundledSymbols.postScriptName)
        #expect(fallback.statistics.fontconfigCalls > 0)
        // And with it, a scalar it does not cover still reaches fontconfig (☃ is in neither).
        let withSubset = try TerminalFaces(pointSize: 14, scale: 2, fallback: TestFallbacks.system)
        let snowman = withSubset.shape(["\u{2603}"])
        #expect(withSubset.name(of: snowman.face) != BundledSymbols.postScriptName)
    }

    @Test("every subset glyph fits its cell box at 22.4 and 28 px with thicken on and off")
    func subsetGlyphsFitTheCell() throws {
        for (pointSize, scale) in [(14.0, 1.6), (14.0, 2.0)] as [(CGFloat, CGFloat)] {
            let faces = try TerminalFaces(pointSize: pointSize, scale: scale, fallback: Self.freshFallback())
            for scalar in BundledSymbols.inventory {
                let shaped = faces.shape([scalar])
                guard faces.name(of: shaped.face) == BundledSymbols.postScriptName else { continue }
                for thicken in [false, true] {
                    let options = RasterizerOptions(thicken: thicken)
                    let glyph = try #require(faces.rasterize(shaped, options: options))
                    let padding = options.padding
                    #expect(glyph.width - 2 * padding <= faces.metrics.width * shaped.cellSpan + 1, "\(Self.hex(scalar))")
                    #expect(glyph.height - 2 * padding <= faces.metrics.height + 1, "\(Self.hex(scalar))")
                }
            }
        }
    }

    // MARK: Chrome mono

    @Test("chrome mono resolves every inventory glyph to JetBrains Mono or the subset, without fontconfig")
    func chromeMonoInventory() throws {
        let fallback = Self.freshFallback()
        let cascade = try GlyphCascade.chromeMono(fallback: fallback)
        for scalar in BundledSymbols.inventory {
            let resolved = cascade.resolve([scalar])
            #expect(resolved.isBundled, "\(Self.hex(scalar)) → \(resolved.source)")
            #expect(!resolved.isColor && resolved.glyphs.allSatisfy { $0 != 0 })
            #expect(resolved.advanceEm > 0)
        }
        #expect(cascade.resolve("A").source == .primary(0))
        #expect(fallback.statistics.fontconfigCalls == 0)
    }

    @Test("mono 10 pt: · is JetBrains Mono's 6 pt; ⎇ comes from the subset at its hmtx advance")
    func monoAdvances() throws {
        let cascade = try GlyphCascade.chromeMono(fallback: Self.freshFallback())
        let dot = cascade.resolve("\u{00B7}")
        #expect(dot.source == .primary(0) && dot.postScriptName == "JetBrainsMono-Regular")
        #expect(abs(dot.advance(pointSize: 10) - 6) < 0.0001)
        let branch = cascade.resolve("\u{2387}")
        #expect(branch.source == .symbols)
        let library = try FreeTypeLibrary()
        let face = try FreeTypeFace(library: library, url: try #require(BundledSymbols.url))
        var advance: FT_Fixed = 0
        _ = FT_Get_Advance(face.handle, FT_Get_Char_Index(face.handle, 0x2387), FT_Int32(FT_LOAD_NO_SCALE), &advance)
        #expect(abs(branch.advance(pointSize: 10) - CGFloat(advance) / 100) < 0.0001)
        // "⎇ main" as the sidebar's detail line measures it, before tracking.
        #expect(abs(cascade.advance(of: "\u{2387} main", pointSize: 10) - (branch.advance(pointSize: 10) + 5 * 6)) < 0.0001)
    }

    // MARK: What the chrome prints

    /// Every scalar outside ASCII that a string literal in TkzApp or TkzCore spells, literally or
    /// as `\u{…}`: what the chrome can draw. Comment-only lines are skipped.
    static func chromeLiteralScalars() throws -> Set<Unicode.Scalar> {
        let roots = ["Sources/TkzApp", "Sources/TkzCore"].map { SymbolRecipe.repoRoot.appendingPathComponent($0) }
        let literal = try Regex(#""(?:[^"\\]|\\.)*""#)
        let escape = try Regex(#"\\u\{([0-9A-Fa-f]{1,6})\}"#)
        var found: Set<Unicode.Scalar> = []
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for line in text.split(separator: "\n") {
                    let trimmed = line.drop { $0 == " " }
                    if trimmed.hasPrefix("//") { continue }
                    for match in line.matches(of: literal) {
                        let body = String(line[match.range])
                        for scalar in body.unicodeScalars where scalar.value > 0x7F { found.insert(scalar) }
                        for escaped in body.matches(of: escape) {
                            if let hex = escaped.output[1].substring,
                               let value = UInt32(hex, radix: 16), value > 0x7F,
                               let scalar = Unicode.Scalar(value) { found.insert(scalar) }
                        }
                    }
                }
            }
        }
        return found
    }

    @Test("every non-ASCII scalar the chrome's string literals print resolves to a bundled face")
    func chromeLiterals() throws {
        let scalars = try Self.chromeLiteralScalars()
        #expect(scalars.contains("\u{2387}") && scalars.contains("\u{FF0B}"))  // the scan works
        let cascade = try GlyphCascade.chromeMono(fallback: Self.freshFallback())
        for scalar in scalars.sorted(by: { $0.value < $1.value }) {
            // Typographic quotes and dashes too: JetBrains Mono has them.
            let resolved = cascade.resolve([scalar])
            #expect(resolved.isBundled, "\(Self.hex(scalar)) (\(Character(scalar))) → \(resolved.source)")
        }
    }

    // MARK: - The Mac references (WOR-312 S1 and S2)

    static let referenceDirectory = SymbolRecipe.repoRoot.appendingPathComponent("Tests/Parity/References/fonts", isDirectory: true)
    static let symbolInventoryURL = referenceDirectory.appendingPathComponent("symbols.json")
    static let chromeMetricsURL = referenceDirectory.appendingPathComponent("chrome-metrics.json")

    /// TODO(WOR-312 S1): the exporter owns this schema. The Linux side expects, per scalar
    /// JetBrains Mono lacks, the CoreText fallback font and the glyph's ink box in device pixels
    /// (x right, y up from the baseline) at each configuration. Unknown keys are ignored.
    struct SymbolInventory: Decodable {
        struct Entry: Decodable {
            let scalar: String
            let font: String
            let pointSize: Double
            let scale: Double
            let advance: Double
            let bbox: Box
        }
        struct Box: Decodable {
            let x, y, width, height: Double
        }
        let symbols: [Entry]
    }

    @Test("every subset glyph's ink box is within ±1 px of the Mac's",
          .enabled(if: FileManager.default.fileExists(atPath: symbolInventoryURL.path),
                   "DEFERRED: Tests/Parity/References/fonts/symbols.json comes from WOR-312 S1 on the reference Mac"))
    func bboxesMatchMac() throws {
        let inventory = try JSONDecoder().decode(SymbolInventory.self, from: Data(contentsOf: Self.symbolInventoryURL))
        let library = try FreeTypeLibrary()
        let face = try FreeTypeFace(library: library, url: try #require(BundledSymbols.url))
        var compared = 0
        for entry in inventory.symbols {
            guard let value = UInt32(entry.scalar, radix: 16), let scalar = Unicode.Scalar(value),
                  FT_Get_Char_Index(face.handle, FT_ULong(value)) != 0 else { continue }
            try face.requestPixelSize(entry.pointSize * entry.scale)
            let linux = try #require(face.outlineMetrics(of: scalar))
            let mac = entry.bbox
            #expect(abs(linux.xMin - mac.x) <= 1 && abs(linux.yMin - mac.y) <= 1, "\(entry.scalar) origin")
            #expect(abs(linux.width - mac.width) <= 1 && abs(linux.height - mac.height) <= 1, "\(entry.scalar) size")
            compared += 1
        }
        #expect(compared > 0)
    }

    /// TODO(WOR-312 S2): the dump owns this schema. The Linux side expects advances of single
    /// strings per font role and size, in points. Unknown keys are ignored.
    struct ChromeMetrics: Decodable {
        struct Advance: Decodable {
            let font: String  // "mono" or "ui"
            let pointSize: Double
            let weight: String?
            let string: String
            let advance: Double
        }
        let advances: [Advance]
    }

    @Test("⎇ and · advances in mono 10 pt are within ±0.1 pt of the Mac's",
          .enabled(if: FileManager.default.fileExists(atPath: chromeMetricsURL.path),
                   "DEFERRED: Tests/Parity/References/fonts/chrome-metrics.json comes from WOR-312 S2 on the reference Mac"))
    func monoAdvancesMatchMac() throws {
        let metrics = try JSONDecoder().decode(ChromeMetrics.self, from: Data(contentsOf: Self.chromeMetricsURL))
        let cascade = try GlyphCascade.chromeMono(fallback: Self.freshFallback())
        for string in ["\u{2387}", "\u{00B7}"] {
            let mac = try #require(metrics.advances.first { $0.font == "mono" && $0.pointSize == 10 && $0.string == string })
            #expect(abs(cascade.advance(of: string, pointSize: 10) - mac.advance) <= 0.1, "\(string)")
        }
    }
}
