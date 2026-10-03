// FontFallback — which face draws a cluster the bundled faces cannot, through the private FcConfig
// (WOR-312 S4).
//
// Lists. One `FcFontSort` per list, cached for the process: a text list per style and one colour
// list. The pattern is the pinned family list — Noto Sans Mono, DejaVu Sans Mono, Noto Sans CJK SC
// (the closest to the Mac's PingFang SC) — plus the style's weight and slant, and `color=false`;
// the colour list adds Noto Color Emoji, asks for `color=true` and uses the regular weight and
// slant. Fontconfig ranks colour above family, so `color=false` keeps Noto Color Emoji out of the
// way of a text-presentation ✳ (Omarchy resolves it there otherwise), and `color=true` puts it
// first for 😀. The sort is untrimmed: every font the config knows follows the pinned families,
// ranked by fontconfig, so a scalar no pinned family has still finds a face.
//
// Lookup. A cluster's face must cover every non-ignorable scalar in it (ZWJ, variation selectors
// and tags are default-ignorable; HarfBuzz hides them when the face lacks them). The first
// covering entry per scalar is cached, and so is the face per multi-scalar cluster: a cached
// lookup makes no fontconfig call, which `statistics` counts. When no single face covers a whole
// cluster, the face of its first scalar draws it, as the Mac's first-run font does.
//
// Threads. Building the config scans the font directories (about 0.2 s for 800 system fonts with
// a cold cache on the reference machine), so it must not run on the main thread: `prewarm()`
// builds it and every list on a detached task, and the app calls it once, early. A lookup runs on
// its caller's thread, so a cache miss there (a scalar prewarm did not cover: charset probes, or
// everything if prewarm has not finished) calls fontconfig on that thread; the renderer that calls
// `TerminalFaces.shape` owns keeping that off the main thread (WOR-313). Every fontconfig call
// goes through `State.fc`, which counts it and counts it again if it ran on the main thread
// (`statistics.mainThreadCalls`). The FcConfig and the sorted sets live in a non-Sendable owner
// behind a `Mutex`.

import CFontconfig
import Foundation
import Synchronization
import TkzRenderCore

/// One font fontconfig knows: everything needed to open it and to name it.
public struct FallbackFace: Sendable, Hashable, CustomStringConvertible {
    /// The font file.
    public let path: String
    /// `FC_INDEX`: the face index in a collection, with a named instance in the high 16 bits.
    public let index: Int
    public let postScriptName: String
    /// The first `FC_FAMILY` value.
    public let family: String
    /// `FC_COLOR`: CBDT/sbix/COLR colour glyphs, drawn into the BGRA atlas.
    public let isColor: Bool

    public init(path: String, index: Int, postScriptName: String, family: String, isColor: Bool) {
        self.path = path
        self.index = index
        self.postScriptName = postScriptName
        self.family = family
        self.isColor = isColor
    }

    public var description: String { "\(postScriptName) (\((path as NSString).lastPathComponent)#\(index))" }
}

public final class FontFallback: Sendable {
    /// The text fallback families, in order. Noto Sans CJK SC stands in for PingFang SC.
    public static let pinnedFamilies = ["Noto Sans Mono", "DejaVu Sans Mono", "Noto Sans CJK SC"]
    /// Appended to `pinnedFamilies` for the colour list.
    public static let colorFamily = "Noto Color Emoji"

    /// The symbols agents print that JetBrains Mono lacks, looked up by `prewarm()` so the first
    /// tool run does not wait on fontconfig.
    public static let prewarmScalars: [Unicode.Scalar] = [
        "\u{23FA}", "\u{23BF}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}",
        "\u{21AF}", "\u{2714}", "\u{25D0}", "\u{23F5}",
    ]

    /// A sorted fallback list: text for one style, or colour.
    public enum List: Sendable, Hashable {
        case text(FontStyle)
        case color
    }

    /// Fontconfig calls made so far.
    public struct Statistics: Sendable, Equatable {
        public let fontconfigCalls: Int
        /// The calls that ran on the main thread. Always 0 in a correct program.
        public let mainThreadCalls: Int
    }

    public let configuration: FontconfigConfiguration
    private let state: Mutex<State>

    /// The process-wide fallback over the bundled fonts and the user's system fonts. Creating it
    /// makes no fontconfig call; the first lookup or `prewarm()` does.
    public static let system = FontFallback(configuration: .system(bundled: BundledFonts.fontDirectories))

    public convenience init(configuration: FontconfigConfiguration) {
        self.init(configuration: configuration, isMainThread: { Thread.isMainThread })
    }

    /// `isMainThread` decides which calls `statistics.mainThreadCalls` counts. Tests pass their
    /// own stand-in: under `swift test` on Linux, main-actor code does not run on the process's
    /// main thread, so the real one cannot be reached from a test. `colorFamilies` replaces
    /// `[colorFamily]` at the end of the colour list's pattern; tests use it to rank a fixture
    /// colour font first.
    init(configuration: FontconfigConfiguration,
         colorFamilies: [String] = [FontFallback.colorFamily],
         isMainThread: @escaping @Sendable () -> Bool) {
        self.configuration = configuration
        self.state = Mutex(State(configuration: configuration, colorFamilies: colorFamilies, isMainThread: isMainThread))
    }

    // MARK: - Lookup

    /// The face for `scalars` from `list`: the first entry covering every non-ignorable scalar,
    /// or, when none does, the first scalar's face. `nil` when nothing covers even that, the
    /// cluster is only ignorables, or the configuration failed to load.
    public func face(covering scalars: [Unicode.Scalar], in list: List) -> FallbackFace? {
        let needed = Self.nonIgnorable(scalars)
        guard !needed.isEmpty else { return nil }
        return state.withLock { $0.face(covering: needed, in: list) }
    }

    /// The same lookup with some faces ruled out: the ones the shaper found it cannot draw the
    /// cluster with (a COLRv1-only colour font, a file FreeType cannot open). Not cached here; the
    /// shaper caches the cluster it settles on.
    public func face(covering scalars: [Unicode.Scalar], in list: List, excluding excluded: Set<FallbackFace>) -> FallbackFace? {
        guard !excluded.isEmpty else { return face(covering: scalars, in: list) }
        let needed = Self.nonIgnorable(scalars)
        guard !needed.isEmpty else { return nil }
        return state.withLock { $0.face(covering: needed, in: list, excluding: excluded) }
    }

    /// The whole sorted list, best first.
    public func faces(in list: List) -> [FallbackFace] {
        state.withLock { $0.sorted(list)?.entries.map(\.face) ?? [] }
    }

    /// Why the configuration could not be loaded, or `nil` (also before the first lookup).
    public var loadFailure: String? {
        state.withLock { $0.failure }
    }

    public var statistics: Statistics {
        state.withLock { Statistics(fontconfigCalls: $0.calls, mainThreadCalls: $0.mainThreadCalls) }
    }

    /// Builds the config and every list, and resolves `scalars` in the regular text list, on a
    /// detached task — never on the caller's thread, so never on the main thread.
    public func prewarm(_ scalars: [Unicode.Scalar] = FontFallback.prewarmScalars) async {
        await Task.detached(priority: .utility) { [self] in
            self.state.withLock { state in
                for list in [List.color] + FontStyle.allCases.map(List.text) { _ = state.sorted(list) }
                for scalar in Self.nonIgnorable(scalars) { _ = state.face(covering: [scalar], in: .text(.regular)) }
            }
        }.value
    }

    // MARK: - Cluster rules

    /// The scalars a face must cover: everything but the default-ignorable code points (ZWJ,
    /// variation selectors, tags), which HarfBuzz hides when the face lacks them.
    static func nonIgnorable(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        scalars.filter { !$0.properties.isDefaultIgnorableCodePoint }
    }

    /// True when the cluster asks for emoji presentation, so the colour list resolves it: VS16, or
    /// an Emoji_Presentation first scalar (emoji, regional indicators, ZWJ sequences starting with
    /// one), unless VS15 asks for text.
    public static func wantsColor(_ scalars: [Unicode.Scalar]) -> Bool {
        if scalars.contains(where: { $0.value == 0xFE0E }) { return false }
        if scalars.contains(where: { $0.value == 0xFE0F }) { return true }
        return scalars.first?.properties.isEmojiPresentation ?? false
    }
}

// MARK: - The owner of the fontconfig objects

/// The FcConfig, the sorted sets and the caches. Not Sendable: only ever used inside
/// `FontFallback.state.withLock`.
private final class State {
    struct Entry {
        let face: FallbackFace
        /// Owned by the sorted set's pattern; valid while the set is.
        let charset: OpaquePointer?
    }

    struct SortedList {
        let set: UnsafeMutablePointer<FcFontSet>
        let entries: [Entry]
    }

    private struct ScalarKey: Hashable {
        let scalar: UInt32
        let list: FontFallback.List
    }

    private struct ClusterKey: Hashable {
        let scalars: [UInt32]
        let list: FontFallback.List
    }

    let configuration: FontconfigConfiguration
    private let colorFamilies: [String]
    private let isMainThread: @Sendable () -> Bool
    private var config: OpaquePointer?
    private var loaded = false
    private(set) var failure: String?
    private var lists: [FontFallback.List: SortedList] = [:]
    /// Index of the first covering entry, or -1 when none covers.
    private var firstCovering: [ScalarKey: Int] = [:]
    private var clusterFaces: [ClusterKey: Int] = [:]
    private(set) var calls = 0
    private(set) var mainThreadCalls = 0

    init(configuration: FontconfigConfiguration, colorFamilies: [String], isMainThread: @escaping @Sendable () -> Bool) {
        self.configuration = configuration
        self.colorFamilies = colorFamilies
        self.isMainThread = isMainThread
    }

    deinit {
        for list in lists.values { FcFontSetDestroy(list.set) }
        if let config { FcConfigDestroy(config) }
    }

    /// Every fontconfig call goes through here, so tests can count them.
    private func fc<T>(_ body: () -> T) -> T {
        calls += 1
        if isMainThread() { mainThreadCalls += 1 }
        return body()
    }

    // MARK: Config

    private func loadedConfig() -> OpaquePointer? {
        if loaded { return config }
        loaded = true
        do {
            try FileManager.default.createDirectory(at: configuration.cacheDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            // Not fatal: fontconfig scans without a cache, only slower.
            failure = "cache directory \(configuration.cacheDirectory.path): \(error)"
        }
        guard let created = fc({ FcConfigCreate() }) else {
            failure = "FcConfigCreate failed"
            return nil
        }
        // FcConfigCreate takes FONTCONFIG_SYSROOT from the environment; the config is ours alone.
        fc { FcConfigSetSysRoot(created, nil) }
        let parsed = configuration.xml.withCString { text in
            text.withMemoryRebound(to: FcChar8.self, capacity: configuration.xml.utf8.count + 1) { bytes in
                fc { FcConfigParseAndLoadFromMemory(created, bytes, FcBool(FcTrue)) }
            }
        }
        guard parsed != 0, fc({ FcConfigBuildFonts(created) }) != 0 else {
            fc { FcConfigDestroy(created) }
            failure = "the private fontconfig configuration did not load"
            return nil
        }
        config = created
        return created
    }

    // MARK: Lists

    func sorted(_ list: FontFallback.List) -> SortedList? {
        if let sorted = lists[list] { return sorted }
        guard let config = loadedConfig(), let pattern = fc({ FcPatternCreate() }) else { return nil }
        defer { fc { FcPatternDestroy(pattern) } }

        // Weight and slant are in every pattern, the colour one too (as regular): fontconfig's sort
        // leaves fonts with equal scores in qsort's order, so without them Noto Sans Mono Regular
        // and Bold would tie in the colour list and their order would be the C library's choice.
        var families = FontFallback.pinnedFamilies
        let style: FontStyle
        switch list {
        case .text(let textStyle):
            style = textStyle
            fc { _ = FcPatternAddBool(pattern, FC_COLOR, FcBool(FcFalse)) }
        case .color:
            style = .regular
            families += colorFamilies
            fc { _ = FcPatternAddBool(pattern, FC_COLOR, FcBool(FcTrue)) }
        }
        fc { _ = FcPatternAddInteger(pattern, FC_WEIGHT, style.isBold ? FC_WEIGHT_BOLD : FC_WEIGHT_REGULAR) }
        fc { _ = FcPatternAddInteger(pattern, FC_SLANT, style.isItalic ? FC_SLANT_ITALIC : FC_SLANT_ROMAN) }
        for family in families {
            family.withCString { name in
                name.withMemoryRebound(to: FcChar8.self, capacity: family.utf8.count + 1) { bytes in
                    fc { _ = FcPatternAddString(pattern, FC_FAMILY, bytes) }
                }
            }
        }

        var result = FcResultNoMatch
        guard let set = fc({ FcFontSort(config, pattern, FcBool(FcFalse), nil, &result) }) else { return nil }
        var entries: [Entry] = []
        let count = Int(set.pointee.nfont)
        entries.reserveCapacity(count)
        for i in 0..<count {
            guard let font = set.pointee.fonts[i], let face = fallbackFace(font) else { continue }
            var charset: OpaquePointer?
            if fc({ FcPatternGetCharSet(font, FC_CHARSET, 0, &charset) }) != FcResultMatch { charset = nil }
            entries.append(Entry(face: face, charset: charset))
        }
        let sorted = SortedList(set: set, entries: entries)
        lists[list] = sorted
        return sorted
    }

    private func fallbackFace(_ font: OpaquePointer) -> FallbackFace? {
        func string(_ object: String) -> String? {
            var value: UnsafeMutablePointer<FcChar8>?
            guard fc({ FcPatternGetString(font, object, 0, &value) }) == FcResultMatch, let value else { return nil }
            return String(cString: value)
        }
        guard let path = string(FC_FILE) else { return nil }
        var index: Int32 = 0
        if fc({ FcPatternGetInteger(font, FC_INDEX, 0, &index) }) != FcResultMatch { index = 0 }
        var color: FcBool = FcBool(FcFalse)
        if fc({ FcPatternGetBool(font, FC_COLOR, 0, &color) }) != FcResultMatch { color = FcBool(FcFalse) }
        return FallbackFace(path: path, index: Int(index),
                            postScriptName: string(FC_POSTSCRIPT_NAME) ?? "",
                            family: string(FC_FAMILY) ?? "",
                            isColor: color != 0)
    }

    // MARK: Coverage

    private func covers(_ entry: Entry, _ scalar: Unicode.Scalar) -> Bool {
        guard let charset = entry.charset else { return false }
        return fc { FcCharSetHasChar(charset, scalar.value) } != 0
    }

    /// The index of the first entry covering `scalar`, or `nil`.
    private func firstCovering(_ scalar: Unicode.Scalar, in list: FontFallback.List, _ sorted: SortedList) -> Int? {
        let key = ScalarKey(scalar: scalar.value, list: list)
        if let cached = firstCovering[key] { return cached < 0 ? nil : cached }
        let index = sorted.entries.firstIndex { covers($0, scalar) }
        firstCovering[key] = index ?? -1
        return index
    }

    /// `needed` holds non-ignorable scalars only, at least one.
    func face(covering needed: [Unicode.Scalar], in list: FontFallback.List) -> FallbackFace? {
        guard let sorted = sorted(list) else { return nil }
        guard needed.count > 1 else {
            return firstCovering(needed[0], in: list, sorted).map { sorted.entries[$0].face }
        }
        let key = ClusterKey(scalars: needed.map(\.value), list: list)
        if let cached = clusterFaces[key] { return cached < 0 ? nil : sorted.entries[cached].face }

        // No entry before the latest of the scalars' first coverers covers them all.
        var start: Int? = 0
        for scalar in needed {
            guard let first = firstCovering(scalar, in: list, sorted) else { start = nil; break }
            start = max(start ?? 0, first)
        }
        var found: Int?
        if let start {
            found = sorted.entries[start...].firstIndex { entry in needed.allSatisfy { covers(entry, $0) } }
        }
        // Nothing covers the whole cluster: the first scalar's face draws what it can.
        let index = found ?? firstCovering(needed[0], in: list, sorted)
        clusterFaces[key] = index ?? -1
        return index.map { sorted.entries[$0].face }
    }

    /// `face(covering:in:)` over the entries not in `excluded`, uncached.
    func face(covering needed: [Unicode.Scalar], in list: FontFallback.List, excluding excluded: Set<FallbackFace>) -> FallbackFace? {
        guard let sorted = sorted(list) else { return nil }
        let candidates = sorted.entries.filter { !excluded.contains($0.face) }
        let whole = candidates.first { entry in needed.allSatisfy { covers(entry, $0) } }
        return (whole ?? candidates.first { covers($0, needed[0]) })?.face
    }
}
