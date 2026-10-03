// BundledFontsTests — TkzFontsFT's fonts are TkzTerminalRender's, byte for byte (WOR-312 S3), and
// the three system libraries are the ones the build linked.
//
// The Mac's fonts live in TkzTerminalRender, which is not in the Linux graph, so TkzFontsFT carries
// a copy. Both platforms must draw the same files: a font update applied to one copy only would be
// a silent parity break, so this checksum guards it.

import Foundation
import Testing
import TkzPlatform
import TkzRenderCore
@testable import TkzFontsFT

@Suite("Bundled fonts")
struct BundledFontsTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let macFonts = repoRoot.appendingPathComponent("Sources/TkzTerminalRender/Resources/Fonts")
    private static let linuxFonts = repoRoot.appendingPathComponent("Sources/TkzFontsFT/Resources/Fonts")

    private static func files(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).description
    }

    @Test("the copy holds the same files with the same SHA-256 as TkzTerminalRender's")
    func copyIsByteIdentical() throws {
        let names = try Self.files(in: Self.macFonts)
        #expect(names == (try Self.files(in: Self.linuxFonts)))
        #expect(names.contains("OFL.txt"))
        for name in names {
            let mac = try Self.sha256(Self.macFonts.appendingPathComponent(name))
            let linux = try Self.sha256(Self.linuxFonts.appendingPathComponent(name))
            #expect(mac == linux, "\(name): \(linux) differs from TkzTerminalRender's \(mac)")
        }
    }

    @Test("the resource bundle carries every style's face and the licence")
    func bundleResolves() throws {
        let directory = try #require(BundledFonts.directory)
        for style in FontStyle.allCases {
            let file = directory.appendingPathComponent(BundledFonts.jetBrainsMonoFile(style))
            #expect(try Self.sha256(file) == (try Self.sha256(Self.linuxFonts.appendingPathComponent(file.lastPathComponent))))
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("OFL.txt").path))
    }

    @Test("a missing font file is a FreeType error, not a crash")
    func missingFile() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("tkzmux-no-fonts-\(UUID())")
        #expect(throws: FreeTypeError.self) {
            _ = try TerminalFaces(pointSize: 14, scale: 2, fontDirectory: empty)
        }
    }

    @Test("FreeType, HarfBuzz and fontconfig load and report their versions")
    func systemLibraries() throws {
        let freeType = try #require(FontLibraryVersions.freeType)
        let parts = freeType.split(separator: ".").compactMap { Int($0) }
        // Ubuntu 24.04 has 2.13.2, the oldest FreeType CI builds against; the APIs used here are older.
        #expect(parts.count == 3 && (parts[0], parts[1]) >= (2, 13), "\(freeType)")
        #expect(FontLibraryVersions.harfBuzz.split(separator: ".").count == 3)
        #expect(FontLibraryVersions.fontconfig.split(separator: ".").count == 3)
    }
}
