// ParityFontsTests — the pinned parity fonts, their fetch script, and what parity mode resolves
// (WOR-312 S4).
//
// Parity mode sees the bundled fonts and the fetched directory only, so the sorted lists and every
// resolution below are the same in CI (Ubuntu and Arch) and on any desktop: these pins are that
// check. They need scripts/fetch-parity-fonts.sh to have run (CI does it; locally once) and are
// skipped otherwise. The script tests run it against file:// URLs, with no network.

import Foundation
import Testing
import TkzPlatform
import TkzRenderCore
@testable import TkzFontsFT

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite("Parity fonts")
struct ParityFontsTests {

    // MARK: Lockfile

    @Test("the lockfile pins Noto Sans Mono, Noto Sans CJK SC and Noto Color Emoji by SHA-256")
    func lockfile() throws {
        let lock = try ParityLock.load()
        #expect(Set(lock.fonts.map(\.postScriptName)) == [
            "NotoSansMono-Regular", "NotoSansMono-Bold", "NotoSansCJKsc-Regular", "NotoColorEmoji",
        ])
        for font in lock.fonts {
            #expect(font.sha256.count == 64 && font.sha256.allSatisfy(\.isHexDigit), "\(font.file)")
            #expect(font.url.hasPrefix("https://"), "\(font.file)")
            #expect(font.license == "OFL-1.1", "\(font.file)")
            // Pinned: a tag or a commit, never a moving branch.
            #expect(!font.url.contains("/main/") && !font.url.contains("/master/"), "\(font.file)")
        }
        // The script reads one font per line with sed.
        let text = try String(contentsOf: ParityLock.url, encoding: .utf8)
        let fontLines = text.split(separator: "\n").filter { $0.contains("\"file\":") }
        #expect(fontLines.count == lock.fonts.count)
        for line in fontLines {
            #expect(line.contains("\"sha256\":") && line.contains("\"url\":"))
        }
    }

    @Test("CI has fetched the parity fonts, so the pins below run instead of skipping",
          .enabled(if: ProcessInfo.processInfo.environment["TKZMUX_REQUIRE_PARITY_FONTS"] == "1",
                   "TKZMUX_REQUIRE_PARITY_FONTS is not set (CI sets it)"))
    func parityFontsRequired() {
        #expect(TestFallbacks.parityFontsPresent,
                "no parity fonts in \(TestFallbacks.parityFontDirectory.path): run scripts/fetch-parity-fonts.sh")
    }

    @Test("the fetched fonts are the locked bytes, and nothing else is in the directory",
          .enabled(if: TestFallbacks.parityFontsPresent, "run scripts/fetch-parity-fonts.sh"))
    func fetchedFontsMatchTheLock() throws {
        let lock = try ParityLock.load()
        let directory = TestFallbacks.parityFontDirectory
        for font in lock.fonts {
            let data = try Data(contentsOf: directory.appendingPathComponent(font.file))
            #expect(data.count == font.size, "\(font.file)")
            #expect(SHA256.hash(data: data).description == font.sha256, "\(font.file)")
        }
        let present = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
        #expect(Set(present) == Set(lock.fonts.map(\.file)))
    }

    // MARK: Parity resolution

    private static let jetBrainsMono = ["JetBrainsMono-Regular", "JetBrainsMono-Bold", "JetBrainsMono-Italic", "JetBrainsMono-BoldItalic"]

    /// Every list, by PostScript name. Pinned: a change here is a parity change.
    private static let expectedLists: [FontFallback.List: [String]] = [
        .text(.regular): ["NotoSansMono-Regular", "NotoSansMono-Bold", "NotoSansCJKsc-Regular",
                          "JetBrainsMono-Regular", "JetBrainsMono-Bold", "JetBrainsMono-Italic", "JetBrainsMono-BoldItalic",
                          "NotoColorEmoji"],
        .text(.bold): ["NotoSansMono-Bold", "NotoSansMono-Regular", "NotoSansCJKsc-Regular",
                       "JetBrainsMono-Bold", "JetBrainsMono-Regular", "JetBrainsMono-BoldItalic", "JetBrainsMono-Italic",
                       "NotoColorEmoji"],
        .text(.italic): ["NotoSansMono-Regular", "NotoSansMono-Bold", "NotoSansCJKsc-Regular",
                         "JetBrainsMono-Italic", "JetBrainsMono-BoldItalic", "JetBrainsMono-Regular", "JetBrainsMono-Bold",
                         "NotoColorEmoji"],
        .text(.boldItalic): ["NotoSansMono-Bold", "NotoSansMono-Regular", "NotoSansCJKsc-Regular",
                             "JetBrainsMono-BoldItalic", "JetBrainsMono-Italic", "JetBrainsMono-Bold", "JetBrainsMono-Regular",
                             "NotoColorEmoji"],
        .color: ["NotoColorEmoji", "NotoSansMono-Regular", "NotoSansMono-Bold", "NotoSansCJKsc-Regular",
                 "JetBrainsMono-Regular", "JetBrainsMono-Bold", "JetBrainsMono-Italic", "JetBrainsMono-BoldItalic"],
    ]

    @Test("parity mode's sorted lists are exactly the pinned ones",
          .enabled(if: TestFallbacks.parityFontsPresent, "run scripts/fetch-parity-fonts.sh"),
          arguments: [FontFallback.List.text(.regular), .text(.bold), .text(.italic), .text(.boldItalic), .color])
    func sortedLists(list: FontFallback.List) throws {
        let faces = TestFallbacks.parity.faces(in: list)
        #expect(faces.map(\.postScriptName) == Self.expectedLists[list])
        let roots = TestFallbacks.parity.configuration.fontDirectories.map { $0.standardizedFileURL.path + "/" }
        for face in faces {
            #expect(roots.contains { face.path.hasPrefix($0) }, "\(face.path)")
            #expect(face.index == 0)
            #expect(face.isColor == (face.postScriptName == "NotoColorEmoji"))
        }
    }

    /// cluster, style → face, colour, cell span, glyph ids. The glyph ids are the pinned files'.
    struct Resolution: CustomTestStringConvertible, Sendable {
        let cluster: String
        let style: FontStyle
        let face: String
        let isColor: Bool
        let cellSpan: Int
        let glyphs: [UInt32]

        var testDescription: String { "\(cluster) \(style)" }
    }

    static let expectedResolutions: [Resolution] = [
        Resolution(cluster: "A", style: .regular, face: "JetBrainsMono-Regular", isColor: false, cellSpan: 1, glyphs: [1]),
        Resolution(cluster: "A", style: .bold, face: "JetBrainsMono-Bold", isColor: false, cellSpan: 1, glyphs: [1]),
        Resolution(cluster: "你", style: .regular, face: "NotoSansCJKsc-Regular", isColor: false, cellSpan: 2, glyphs: [9987]),
        // Only the Regular CJK face is pinned, so bold CJK is Regular too.
        Resolution(cluster: "你", style: .bold, face: "NotoSansCJKsc-Regular", isColor: false, cellSpan: 2, glyphs: [9987]),
        Resolution(cluster: "你\u{301}", style: .regular, face: "NotoSansCJKsc-Regular", isColor: false, cellSpan: 2, glyphs: [9987, 253]),
        Resolution(cluster: "😀", style: .regular, face: "NotoColorEmoji", isColor: true, cellSpan: 2, glyphs: [883]),
        Resolution(cluster: "👨‍👩‍👧", style: .regular, face: "NotoColorEmoji", isColor: true, cellSpan: 2, glyphs: [2022]),
        Resolution(cluster: "🇸🇪", style: .regular, face: "NotoColorEmoji", isColor: true, cellSpan: 2, glyphs: [1736]),
        Resolution(cluster: "1️⃣", style: .regular, face: "NotoColorEmoji", isColor: true, cellSpan: 2, glyphs: [1485]),
        Resolution(cluster: "❤️", style: .regular, face: "NotoColorEmoji", isColor: true, cellSpan: 2, glyphs: [168]),
        // HarfBuzz composes e + U+0301 to é where the face has it.
        Resolution(cluster: "e\u{301}", style: .regular, face: "JetBrainsMono-Regular", isColor: false, cellSpan: 1, glyphs: [226]),
        Resolution(cluster: "◐", style: .regular, face: "NotoSansMono-Regular", isColor: false, cellSpan: 1, glyphs: [3025]),
        Resolution(cluster: "◐", style: .bold, face: "NotoSansMono-Bold", isColor: false, cellSpan: 1, glyphs: [3025]),
        Resolution(cluster: "⎿", style: .regular, face: "NotoSansCJKsc-Regular", isColor: false, cellSpan: 1, glyphs: [900]),
        // Until WOR-312 S7's symbol subset: ✳ has no text face in the parity set, so the colour
        // font, last in the text list, draws it. S7 moves it to the subset (and never colour).
        Resolution(cluster: "✳", style: .regular, face: "NotoColorEmoji", isColor: true, cellSpan: 1, glyphs: [157]),
        // No parity font has ✢: the bundled face's .notdef (S7's subset covers it).
        Resolution(cluster: "✢", style: .regular, face: "JetBrainsMono-Regular", isColor: false, cellSpan: 1, glyphs: [0]),
    ]

    @Test("parity mode resolves the corpus to the pinned faces and glyphs",
          .enabled(if: TestFallbacks.parityFontsPresent, "run scripts/fetch-parity-fonts.sh"),
          arguments: expectedResolutions)
    func resolutions(expected: Resolution) throws {
        let faces = try TerminalFaces(pointSize: 14, scale: 2, fallback: TestFallbacks.parity)
        let shaped = faces.shape(Array(expected.cluster.unicodeScalars), style: expected.style)
        #expect(faces.name(of: shaped.face) == expected.face)
        #expect(shaped.isColor == expected.isColor)
        #expect(shaped.cellSpan == expected.cellSpan)
        #expect(shaped.glyphs.map(\.glyph.rawValue) == expected.glyphs)
    }

    // MARK: scripts/fetch-parity-fonts.sh

    private struct ScriptRun {
        let status: Int32
        let output: String
    }

    private func runScript(_ arguments: [String]) throws -> ScriptRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", repoRoot.appendingPathComponent("scripts/fetch-parity-fonts.sh").path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptRun(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// A scratch directory with a "font" served from a file:// URL and a lockfile for it.
    private struct Scratch {
        let root: URL
        let source: URL
        let dest: URL
        let sha256: String

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("tkzmux-fetch-parity-\(UUID())")
            source = root.appendingPathComponent("upstream/Test-Regular.ttf")
            dest = root.appendingPathComponent("fonts")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data("not really a font, but bytes with a hash".utf8)
            try bytes.write(to: source)
            sha256 = SHA256.hash(data: bytes).description
        }

        func lock(sha256: String) throws -> URL {
            let url = root.appendingPathComponent("fonts.lock.json")
            let text = """
                {
                  "fonts": [
                    {"file": "Test-Regular.ttf", "sha256": "\(sha256)", "url": "file://\(source.path)"}
                  ]
                }

                """
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("the fetch script installs a file whose SHA-256 matches")
    func fetchAcceptsMatchingHash() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let run = try runScript(["--lock", try scratch.lock(sha256: scratch.sha256).path, scratch.dest.path])
        #expect(run.status == 0, "\(run.output)")
        let installed = scratch.dest.appendingPathComponent("Test-Regular.ttf")
        #expect(try Data(contentsOf: installed) == Data(contentsOf: scratch.source))
        // --check then agrees, and a second run downloads nothing.
        #expect(try runScript(["--lock", scratch.root.appendingPathComponent("fonts.lock.json").path, "--check", scratch.dest.path]).status == 0)
        let again = try runScript(["--lock", scratch.root.appendingPathComponent("fonts.lock.json").path, scratch.dest.path])
        #expect(again.status == 0 && again.output.contains("ok"), "\(again.output)")
    }

    @Test("the fetch script rejects a hash mismatch and leaves no file behind")
    func fetchRejectsMismatch() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let wrong = String(repeating: "0", count: 64)
        let run = try runScript(["--lock", try scratch.lock(sha256: wrong).path, scratch.dest.path])
        #expect(run.status == 1, "\(run.output)")
        #expect(run.output.contains("SHA-256"))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: scratch.dest.path)) ?? []
        #expect(left.isEmpty, "\(left)")
    }

    @Test("the fetch script replaces a tampered file and removes fonts the lock does not list")
    func fetchRepairsTheDirectory() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try FileManager.default.createDirectory(at: scratch.dest, withIntermediateDirectories: true)
        try Data("tampered".utf8).write(to: scratch.dest.appendingPathComponent("Test-Regular.ttf"))
        try Data("stale".utf8).write(to: scratch.dest.appendingPathComponent("Old-Regular.otf"))
        let lock = try scratch.lock(sha256: scratch.sha256)

        #expect(try runScript(["--lock", lock.path, "--check", scratch.dest.path]).status == 1)
        let run = try runScript(["--lock", lock.path, scratch.dest.path])
        #expect(run.status == 0, "\(run.output)")
        #expect(try Data(contentsOf: scratch.dest.appendingPathComponent("Test-Regular.ttf")) == Data(contentsOf: scratch.source))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.dest.path) == ["Test-Regular.ttf"])
    }
}
