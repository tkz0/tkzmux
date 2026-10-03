// FontFallbackTests — the private FcConfig, its lists and caches (WOR-312 S4).
//
// The configuration tests are pure (the XML). The lookups run against two configurations shared by
// the whole test process, so fontconfig scans each directory once: `system` (bundled fonts, then
// /usr/share/fonts and ~/.local/share/fonts) and `parity` (bundled fonts plus the fetched parity
// fonts; those tests are skipped until scripts/fetch-parity-fonts.sh has run). Both cache into a
// directory under the system temporary directory, never the user's own cache.

import Foundation
import Glibc
import Testing
import TkzPlatform
import TkzRenderCore
@testable import TkzFontsFT

enum TestFallbacks {
    static let cacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tkzmux-tests-fontconfig-\(getuid())", isDirectory: true)

    static let system = FontFallback(configuration: .system(
        bundled: BundledFonts.fontDirectories, cacheDirectory: cacheDirectory))

    static let parityFontDirectory = FontconfigConfiguration.defaultParityFontDirectory

    /// True when scripts/fetch-parity-fonts.sh has filled the parity directory.
    static let parityFontsPresent: Bool = {
        guard let lock = try? ParityLock.load() else { return false }
        return lock.fonts.allSatisfy {
            FileManager.default.fileExists(atPath: parityFontDirectory.appendingPathComponent($0.file).path)
        }
    }()

    static let parity = FontFallback(configuration: .parity(
        bundled: BundledFonts.fontDirectories, testFonts: parityFontDirectory, cacheDirectory: cacheDirectory))

    /// Whether `family` is installed for the system configuration.
    static func systemHas(family: String) -> Bool {
        system.faces(in: .color).contains { $0.family == family }
    }
}

@Suite("Private fontconfig configuration")
struct FontconfigConfigurationTests {
    private let bundled = URL(fileURLWithPath: "/opt/tkzmux/lib/tkzmux/TkzFontsFT.resources/Fonts", isDirectory: true)

    @Test("system: bundled fonts, then /usr/share/fonts, then ~/.local/share/fonts")
    func systemDirectories() {
        let configuration = FontconfigConfiguration.system(
            bundled: [bundled], home: URL(fileURLWithPath: "/srv/user", isDirectory: true),
            cacheDirectory: URL(fileURLWithPath: "/cache/tkzmux/fontconfig", isDirectory: true))
        #expect(configuration.fontDirectories.map(\.path) == [
            bundled.path, "/usr/share/fonts", "/srv/user/.local/share/fonts",
        ])
        let xml = configuration.xml
        let dirs = xml.split(separator: "\n").filter { $0.contains("<dir>") }.map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(dirs == [
            "<dir>\(bundled.path)</dir>", "<dir>/usr/share/fonts</dir>", "<dir>/srv/user/.local/share/fonts</dir>",
        ])
        #expect(xml.contains("<cachedir>/cache/tkzmux/fontconfig</cachedir>"))
    }

    @Test("the document includes nothing: no fonts.conf, no conf.d, no match rules")
    func includesNothing() {
        let xml = FontconfigConfiguration.system(bundled: [bundled]).xml
        #expect(!xml.contains("<include"))
        #expect(!xml.contains("conf.d"))
        #expect(!xml.contains("/etc/fonts"))
        #expect(!xml.contains("<match"))
        #expect(!xml.contains("<alias"))
        for format in ["PCF", "BDF", "Type 1"] {
            #expect(xml.contains("<string>\(format)</string>"))
        }
    }

    @Test("parity: the bundled fonts and the test-font directory, nothing else")
    func parityDirectories() {
        let fonts = URL(fileURLWithPath: "/ci/cache/tkzmux/parity-fonts", isDirectory: true)
        let configuration = FontconfigConfiguration.parity(bundled: [bundled], testFonts: fonts)
        #expect(configuration.fontDirectories == [bundled, fonts])
        #expect(!configuration.xml.contains("/usr/share/fonts"))
        #expect(!configuration.xml.contains(".local/share/fonts"))
    }

    @Test("the cache is $XDG_CACHE_HOME/tkzmux/fontconfig")
    func cacheDirectory() {
        #expect(FontconfigConfiguration.defaultCacheDirectory == AppPaths.cache.appendingPathComponent("fontconfig", isDirectory: true))
        #expect(FontconfigConfiguration.defaultCacheDirectory.path.hasSuffix("/tkzmux/fontconfig"))
    }

    @Test("paths are escaped as XML text")
    func escaping() {
        let configuration = FontconfigConfiguration(
            fontDirectories: [URL(fileURLWithPath: "/fonts/a&b<c>", isDirectory: true)],
            cacheDirectory: URL(fileURLWithPath: "/cache", isDirectory: true))
        #expect(configuration.xml.contains("<dir>/fonts/a&amp;b&lt;c&gt;</dir>"))
    }
}

@Suite("Font fallback")
struct FontFallbackTests {

    // MARK: Isolation

    @Test("a configuration with an empty font directory knows no font at all")
    func nothingFromTheDesktop() throws {
        // If /etc/fonts (and Omarchy's 50-omarchy.conf) or FONTCONFIG_FILE leaked in, the system
        // fonts would show up here.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("tkzmux-empty-fonts-\(UUID())")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let fallback = FontFallback(configuration: FontconfigConfiguration(
            fontDirectories: [empty], cacheDirectory: TestFallbacks.cacheDirectory))
        #expect(fallback.faces(in: .text(.regular)).isEmpty)
        #expect(fallback.faces(in: .color).isEmpty)
        #expect(fallback.face(covering: ["A"], in: .text(.regular)) == nil)
        #expect(fallback.loadFailure == nil)
    }

    @Test("every face in the system lists comes from a configured directory")
    func onlyConfiguredDirectories() {
        let roots = TestFallbacks.system.configuration.fontDirectories.map { $0.standardizedFileURL.path + "/" }
        let faces = TestFallbacks.system.faces(in: .text(.regular))
        #expect(!faces.isEmpty)
        for face in faces {
            #expect(roots.contains { face.path.hasPrefix($0) }, "\(face.path)")
        }
    }

    @Test("the pinned families lead the text lists, colour fonts trail them")
    func listOrder() {
        let faces = TestFallbacks.system.faces(in: .text(.regular))
        let pinnedPositions = FontFallback.pinnedFamilies.compactMap { family in
            faces.firstIndex { $0.family == family }
        }
        #expect(pinnedPositions == pinnedPositions.sorted())
        if let lastPinned = pinnedPositions.last {
            #expect(!faces[...lastPinned].contains { $0.isColor })
        }
        if let firstColor = faces.firstIndex(where: \.isColor) {
            #expect(!faces[firstColor...].contains { !$0.isColor })
        }
    }

    // MARK: Cluster rules

    @Test("default-ignorable scalars need no coverage")
    func ignorables() {
        let family: [Unicode.Scalar] = ["\u{1F468}", "\u{200D}", "\u{1F469}", "\u{200D}", "\u{1F467}"]
        #expect(FontFallback.nonIgnorable(family) == ["\u{1F468}", "\u{1F469}", "\u{1F467}"])
        #expect(FontFallback.nonIgnorable(["1", "\u{FE0F}", "\u{20E3}"]) == ["1", "\u{20E3}"])
        #expect(FontFallback.nonIgnorable(["e", "\u{301}"]) == ["e", "\u{301}"])
        #expect(FontFallback.nonIgnorable(["\u{1F3F4}", "\u{E0067}", "\u{E0062}", "\u{E007F}"]) == ["\u{1F3F4}"])
    }

    @Test("emoji presentation picks the colour list; VS15 and text-default symbols do not")
    func presentation() {
        #expect(FontFallback.wantsColor(["\u{1F600}"]))
        #expect(FontFallback.wantsColor(["\u{1F1F8}", "\u{1F1EA}"]))
        #expect(FontFallback.wantsColor(["1", "\u{FE0F}", "\u{20E3}"]))
        #expect(FontFallback.wantsColor(["\u{2764}", "\u{FE0F}"]))
        #expect(!FontFallback.wantsColor(["\u{2733}"]))
        #expect(!FontFallback.wantsColor(["\u{1F600}", "\u{FE0E}"]))
        #expect(!FontFallback.wantsColor(["A"]))
        #expect(!FontFallback.wantsColor([]))
    }

    // MARK: System resolution

    @Test("'A' is the bundled JetBrainsMono-Regular, even with the JetBrainsMono Nerd Font installed")
    func bundledWinsOverNerdFont() throws {
        let faces = try TerminalFaces(pointSize: 14, scale: 2, fallback: TestFallbacks.system)
        let shaped = faces.shape("A")
        #expect(faces.name(of: shaped.face) == "JetBrainsMono-Regular")
        #expect(faces.fallbackFace(of: shaped.face) == nil)
        #expect(!shaped.isColor)
        // Where the Nerd Font is installed (Omarchy), fontconfig does know it: the bundled face
        // wins because it is opened directly, never looked up by family.
        let nerd = TestFallbacks.system.faces(in: .text(.regular)).first { $0.family.contains("Nerd Font") }
        if let nerd {
            #expect(nerd.family != "JetBrains Mono")
        }
    }

    @Test("你 resolves to Noto Sans CJK SC",
          .enabled(if: TestFallbacks.systemHas(family: "Noto Sans CJK SC"), "Noto Sans CJK SC is not installed"))
    func cjkOnTheSystem() throws {
        let faces = try TerminalFaces(pointSize: 14, scale: 2, fallback: TestFallbacks.system)
        let shaped = faces.shape("你")
        #expect(faces.fallbackFace(of: shaped.face)?.family == "Noto Sans CJK SC")
        #expect(shaped.cellSpan == 2)
        #expect(!shaped.isColor)
    }

    @Test("😀 resolves to Noto Color Emoji with isColor set",
          .enabled(if: TestFallbacks.systemHas(family: "Noto Color Emoji"), "Noto Color Emoji is not installed"))
    func emojiOnTheSystem() throws {
        let faces = try TerminalFaces(pointSize: 14, scale: 2, fallback: TestFallbacks.system)
        let shaped = faces.shape("😀")
        #expect(faces.name(of: shaped.face) == "NotoColorEmoji")
        #expect(shaped.isColor)
        #expect(shaped.glyphs.count == 1 && !shaped.isEmpty)
    }

    // MARK: Caches

    @Test("a cached lookup makes no fontconfig call")
    func cachedLookups() throws {
        let fallback = TestFallbacks.system
        let clusters: [[Unicode.Scalar]] = [["\u{2733}"], ["\u{4F60}"], ["\u{4F60}", "\u{301}"], ["\u{1F600}"]]
        for cluster in clusters {
            _ = fallback.face(covering: cluster, in: .text(.bold))
            _ = fallback.face(covering: cluster, in: .color)
        }
        let before = fallback.statistics.fontconfigCalls
        for cluster in clusters {
            _ = fallback.face(covering: cluster, in: .text(.bold))
            _ = fallback.face(covering: cluster, in: .color)
        }
        #expect(fallback.statistics.fontconfigCalls == before)

        // Through the shaper too: a shaped cluster comes from its cache.
        let faces = try TerminalFaces(pointSize: 14, scale: 2, fallback: fallback)
        _ = faces.shape(["\u{2733}"])
        _ = faces.shape(["\u{4F60}", "\u{301}"])
        let shaped = fallback.statistics.fontconfigCalls
        _ = faces.shape(["\u{2733}"])
        _ = faces.shape(["\u{4F60}", "\u{301}"])
        #expect(fallback.statistics.fontconfigCalls == shaped)
    }

    /// Marks the code standing in for the main thread (see
    /// `FontFallback.init(configuration:isMainThread:)`). A detached task does not inherit it, so
    /// a prewarm that ran inline on its caller would be counted.
    enum StandInMainThread {
        @TaskLocal static var isCurrent = false
    }

    @Test("prewarm runs detached from its caller, so the main thread never calls fontconfig")
    func noFontconfigOnTheMainThread() async throws {
        let fallback = FontFallback(
            configuration: .system(bundled: BundledFonts.fontDirectories, cacheDirectory: TestFallbacks.cacheDirectory),
            isMainThread: { StandInMainThread.isCurrent })
        try await StandInMainThread.$isCurrent.withValue(true) {
            try await prewarmThenShape(fallback)
        }
    }

    private func prewarmThenShape(_ fallback: FontFallback) async throws {
        // Creating the fallback and the faces touches no fontconfig.
        let faces = try TerminalFaces(pointSize: 14, scale: 2, fallback: fallback)
        #expect(fallback.statistics.fontconfigCalls == 0)

        await faces.prewarm()
        let warmed = fallback.statistics
        #expect(warmed.fontconfigCalls > 0)
        #expect(warmed.mainThreadCalls == 0)

        // The prewarmed agent glyphs then shape on the "main" thread without fontconfig.
        for scalar in FontFallback.prewarmScalars {
            _ = faces.shape([scalar])
        }
        #expect(fallback.statistics == warmed)

        // Control: a lookup prewarm did not cover does reach fontconfig, and is counted.
        _ = faces.shape(["\u{2603}"], style: .bold)
        #expect(fallback.statistics.mainThreadCalls > 0)
    }
}
