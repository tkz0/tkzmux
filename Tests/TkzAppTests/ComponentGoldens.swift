// ComponentGoldens — the committed half of the component snapshots (WOR-307 S2): where the goldens
// live, the manifest that describes them, and the comparisons a render is held to.
//
// Foundation, TkzPNG and TkzPlatform only: no AppKit, so the manifest, the layout comparison, the
// off-grid edge scan and the ADR-0003 snapping reference compile and are exercised outside the Mac
// app too. The AppKit side (rendering, host facts, `Issue.record`) is in
// `ComponentSnapshotGoldenTests.swift`.
//
// Layout of `Tests/TkzAppTests/ComponentSnapshots/` (excluded from the target in Package.swift and
// read through `#filePath`, like the terminal goldens):
//
//   <component>@<preset>@<scale>.png    the sRGB render (RGB when opaque, else RGBA)
//   <component>@<preset>@<scale>.json   its `LayoutDump`, canonical compact JSON
//   manifest.json                       the reference machine, every file's size and sha256, the
//                                       total against WOR-307's 4.25 MiB share, the off-grid edges
//   README.md                           how to regenerate
//
// Regenerate on the reference runner (ADR-0003 §5), never by hand:
//
//   TKZMUX_UPDATE_SNAPSHOTS=1 swift test --no-parallel --filter ComponentSnapshot

import Foundation
import TkzPNG
import TkzPlatform

// MARK: - Manifest

/// The machine a golden set was rendered on. Byte equality is only promised on its `macOSBuild`
/// (ADR-0003 §5: references are valid for one runner image). No user or host names (ADR-0003 §5,
/// `scripts/scan-personal-data.sh`).
struct ComponentHost: Codable, Equatable, Sendable {
    /// `sysctl kern.osversion`, e.g. `25A354`. The gate for byte comparison.
    var macOSBuild: String
    var macOSVersion: String
    /// `sysctl hw.model`.
    var hardwareModel: String
    /// `xcodebuild -version`, one line.
    var xcode: String
    /// The GitHub runner image (`ImageOS`, `ImageVersion`), or `unset` off a hosted runner.
    var imageOS: String
    var imageVersion: String
    /// `AppleFontSmoothing` and `CGFontRenderingFontSmoothingDisabled` as the test process reads
    /// them (global domain included), or `unset`.
    var appleFontSmoothing: String
    var fontSmoothingDisabled: String
    /// The main screen's colour profile, or `none, headless`. Informational: the renders go to an
    /// sRGB bitmap and never through a screen.
    var displayProfile: String
}

struct ComponentManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    struct File: Codable, Equatable, Sendable {
        var bytes: Int
        var sha256: String
    }

    /// Where the set came from. Ignored when two generations are compared (ADR-0003 §5).
    struct Provenance: Codable, Equatable, Sendable {
        var commit: String
        var runID: String
    }

    var schema: Int = Self.schemaVersion
    var layoutSchema: Int = LayoutDump.schemaVersion
    var reference: ComponentHost
    /// WOR-307's share of ADR-0003's combined 9 MiB (`componentSnapshotShareBytes`).
    var budgetBytes: Int = ComponentGoldens.budgetBytes
    /// The PNG and JSON files listed below, summed.
    var totalBytes: Int = 0
    /// File name → size and sha256, PNG and JSON alike.
    var files: [String: File] = [:]
    /// ADR-0003 §2: every dumped edge off the 0.5 pt grid at 2.0, per component, from the
    /// `midnightIndigo` dump (frames do not depend on the preset). Each one is an exception to "the
    /// Mac is snap-exact at 2.0" and belongs in ADR-0003's exception table.
    var offGridEdges: [String: [String]] = [:]
    var provenance: Provenance

    /// Pretty, sorted, trailing newline: the manifest is the file a reviewer reads.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

// MARK: - The golden folder

enum ComponentGoldens {
    /// ADR-0003 §5 `componentSnapshotShareBytes`: 4.25 MiB of the combined 9 MiB.
    static let budgetBytes = 4_456_448
    static let updateVariable = "TKZMUX_UPDATE_SNAPSHOTS"
    static let regenerateCommand = "TKZMUX_UPDATE_SNAPSHOTS=1 swift test --no-parallel --filter ComponentSnapshot"
    static let manifestName = "manifest.json"
    static let readmeName = "README.md"

    /// This file's path, captured here: a `#filePath` default argument would be the caller's.
    static let sourceFile: String = #filePath

    /// `Tests/TkzAppTests/ComponentSnapshots/`, next to this file: regenerated goldens are written
    /// into the source tree, never into the build directory.
    static func directory(file: String = ComponentGoldens.sourceFile) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent()
            .appendingPathComponent("ComponentSnapshots", isDirectory: true)
    }

    static var manifestURL: URL { directory().appendingPathComponent(manifestName) }

    /// `TKZMUX_UPDATE_SNAPSHOTS=1`: render, check the render is reproducible, and write.
    static var isUpdating: Bool {
        ProcessInfo.processInfo.environment[updateVariable] == "1"
    }

    /// A set has been committed: there is a manifest.
    static var hasGoldens: Bool { FileManager.default.fileExists(atPath: manifestURL.path) }

    /// What the golden suite's `.enabled(if:)` reads: without goldens and outside an update there
    /// is nothing to compare against, and the suite is skipped rather than failed.
    static var isAvailable: Bool { isUpdating || hasGoldens }

    static func pngName(_ stem: String) -> String { stem + ".png" }
    static func jsonName(_ stem: String) -> String { stem + ".json" }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).description }

    static func readManifest(in directory: URL = directory()) throws -> ComponentManifest? {
        let url = directory.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ComponentManifest.self, from: Data(contentsOf: url))
    }

    /// The files in the folder that are goldens (everything but the manifest and the README).
    static func goldenFileNames(in directory: URL = directory()) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".png") || $0.hasSuffix(".json") }
            .filter { $0 != manifestName }
            .sorted()
    }

    /// Writes one render's PNG and JSON and folds them into the manifest, which is rewritten
    /// whole: `host` replaces the reference, entries whose file is gone are dropped, the total is
    /// recomputed. Returns the new total. Cases run one at a time (the suite is serialised), so
    /// the read-modify-write never races.
    @discardableResult
    static func record(
        stem: String, png: Data, json: Data, offGrid: (component: String, edges: [String])?,
        host: ComponentHost, provenance: ComponentManifest.Provenance,
        in directory: URL = directory()
    ) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pngFile = pngName(stem), jsonFile = jsonName(stem)
        try png.write(to: directory.appendingPathComponent(pngFile), options: .atomic)
        try json.write(to: directory.appendingPathComponent(jsonFile), options: .atomic)

        var manifest = try readManifest(in: directory)
            ?? ComponentManifest(reference: host, provenance: provenance)
        manifest.schema = ComponentManifest.schemaVersion
        manifest.layoutSchema = LayoutDump.schemaVersion
        manifest.reference = host
        manifest.provenance = provenance
        manifest.budgetBytes = budgetBytes
        manifest.files[pngFile] = .init(bytes: png.count, sha256: sha256(png))
        manifest.files[jsonFile] = .init(bytes: json.count, sha256: sha256(json))
        if let offGrid { manifest.offGridEdges[offGrid.component] = offGrid.edges }
        let present = Set(try goldenFileNames(in: directory))
        manifest.files = manifest.files.filter { present.contains($0.key) }
        manifest.totalBytes = manifest.files.values.reduce(0) { $0 + $1.bytes }
        try manifest.jsonData().write(to: directory.appendingPathComponent(manifestName), options: .atomic)
        return manifest.totalBytes
    }

    /// What is wrong with a committed set: files the manifest does not list, entries with no file,
    /// sizes or hashes that do not match, a total that is not the sum or is over budget, and
    /// off-grid lists that do not follow from the committed JSON. Empty when the set is sound.
    static func audit(in directory: URL = directory()) throws -> [String] {
        guard let manifest = try readManifest(in: directory) else { return ["no \(manifestName)"] }
        var problems: [String] = []
        let names = try goldenFileNames(in: directory)
        for name in names where manifest.files[name] == nil {
            problems.append("\(name) is not in the manifest")
        }
        var sum = 0
        for (name, entry) in manifest.files.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else {
                problems.append("\(name) is in the manifest but not on disk")
                continue
            }
            sum += data.count
            if data.count != entry.bytes { problems.append("\(name): \(data.count) bytes, manifest says \(entry.bytes)") }
            if sha256(data) != entry.sha256 { problems.append("\(name): sha256 differs from the manifest") }
        }
        if sum != manifest.totalBytes { problems.append("total is \(sum) bytes, manifest says \(manifest.totalBytes)") }
        if sum > budgetBytes {
            problems.append("\(sum) bytes is over WOR-307's \(budgetBytes)-byte share (ADR-0003 §5): renegotiate the split there, do not trim silently")
        }
        for (component, recorded) in manifest.offGridEdges.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(jsonName(offGridStem(component)))
            guard let data = try? Data(contentsOf: url) else {
                problems.append("offGridEdges[\(component)]: no \(url.lastPathComponent)")
                continue
            }
            let dump = try JSONDecoder().decode(LayoutDump.self, from: data)
            if OffGridEdges.list(dump) != recorded {
                problems.append("offGridEdges[\(component)] does not match \(url.lastPathComponent)")
            }
        }
        return problems
    }

    /// The dump the off-grid list is read from: the default preset at 2.0.
    static func offGridStem(_ component: String) -> String { "\(component)@midnightIndigo@2.0" }

    /// The manifest's per-component byte counts, largest first: what to shrink, or to bring to the
    /// ADR-0003 renegotiation, when the set is over budget.
    static func sizesByComponent(_ manifest: ComponentManifest) -> [(component: String, bytes: Int)] {
        var sizes: [String: Int] = [:]
        for (name, entry) in manifest.files {
            let component = name.split(separator: "@").first.map(String.init) ?? name
            sizes[component, default: 0] += entry.bytes
        }
        return sizes.map { (component: $0.key, bytes: $0.value) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.component < $1.component }
    }
}

// MARK: - Layout comparison off the reference build

/// L0 off the manifest's build (WOR-307 S2): every frame, flag, string and fact must match
/// exactly; only the text measurements CoreText makes may drift, by at most ±0.5 pt
/// (ADR-0003 `l0TextWidthTolerancePt`).
enum LayoutComparison {
    static let textWidthTolerance = 0.5

    /// Each difference as `path: what`, in tree order. Empty when the dumps agree.
    static func differences(golden: LayoutDump, actual: LayoutDump) -> [String] {
        var out: [String] = []
        func check<T: Equatable>(_ path: String, _ a: T, _ b: T) {
            if a != b { out.append("\(path): golden \(a), rendered \(b)") }
        }
        check("schema", golden.schema, actual.schema)
        check("component", golden.component, actual.component)
        check("theme", golden.theme, actual.theme)
        check("appearance", golden.appearance, actual.appearance)
        check("scale", golden.scale, actual.scale)
        check("size", golden.size, actual.size)
        check("pixels", golden.pixels, actual.pixels)
        for key in Set(golden.facts.keys).union(actual.facts.keys).sorted() {
            check("facts.\(key)", golden.facts[key] ?? "<none>", actual.facts[key] ?? "<none>")
        }
        check("masks.count", golden.masks.count, actual.masks.count)
        for (index, (a, b)) in zip(golden.masks, actual.masks).enumerated() {
            check("masks[\(index)]", a, b)
        }
        compare(golden.root, actual.root, path: "root", into: &out)
        return out
    }

    private static func compare(_ a: LayoutDump.Node, _ b: LayoutDump.Node, path: String, into out: inout [String]) {
        func check<T: Equatable>(_ field: String, _ x: T, _ y: T) {
            if x != y { out.append("\(path).\(field): golden \(x), rendered \(y)") }
        }
        func near(_ field: String, _ x: Double?, _ y: Double?) {
            switch (x, y) {
            case (nil, nil): return
            case let (x?, y?) where abs(x - y) <= textWidthTolerance: return
            default: out.append("\(path).\(field): golden \(x.map { "\($0)" } ?? "nil"), rendered \(y.map { "\($0)" } ?? "nil") (±\(textWidthTolerance) pt)")
            }
        }
        check("kind", a.kind, b.kind)
        check("type", a.type, b.type)
        check("name", a.name, b.name)
        check("frame", a.frame, b.frame)
        check("hidden", a.hidden, b.hidden)
        check("alpha", a.alpha, b.alpha)
        check("flipped", a.flipped, b.flipped)
        check("animations", a.animations, b.animations)
        switch (a.text, b.text) {
        case (nil, nil):
            break
        case let (x?, y?):
            check("text.string", x.string, y.string)
            check("text.font", x.font, y.font)
            check("text.size", x.size, y.size)
            check("text.availableWidth", x.availableWidth, y.availableWidth)
            check("text.wraps", x.wraps, y.wraps)
            check("text.truncated", x.truncated, y.truncated)
            near("text.measuredWidth", x.measuredWidth, y.measuredWidth)
            near("text.fittingHeight", x.fittingHeight, y.fittingHeight)
        default:
            out.append("\(path).text: golden \(a.text == nil ? "none" : "a run"), rendered \(b.text == nil ? "none" : "a run")")
        }
        let left = a.children ?? [], right = b.children ?? []
        check("children.count", left.count, right.count)
        for (index, (x, y)) in zip(left, right).enumerated() {
            compare(x, y, path: "\(path)/\(index):\(y.type)", into: &out)
        }
    }
}

// MARK: - Off-grid edges

/// ADR-0003 §2: "at 2.0 the test also lists every dumped edge that is off the 0.5 pt grid".
enum OffGridEdges {
    static let grid = 0.5

    /// `path type edge=value` for every node edge (left, top, right, bottom, in the component's
    /// top-left space) that is not a multiple of `grid`, in tree order.
    static func list(_ dump: LayoutDump) -> [String] {
        var out: [String] = []
        visit(dump.root, path: "root", into: &out)
        return out
    }

    static func isOnGrid(_ value: Double) -> Bool {
        let steps = value / grid
        return abs(steps - steps.rounded()) < 1e-9
    }

    private static func visit(_ node: LayoutDump.Node, path: String, into out: inout [String]) {
        let frame = node.frame
        for (edge, value) in [("left", frame.x), ("top", frame.y), ("right", frame.maxX), ("bottom", frame.maxY)]
        where !isOnGrid(value) {
            out.append("\(path) \(node.type) \(edge)=\(value)")
        }
        for (index, child) in (node.children ?? []).enumerated() {
            visit(child, path: "\(path)/\(index)", into: &out)
        }
    }
}

// MARK: - ADR-0003 snapping, as a reference

/// The snapping rules of ADR-0003 §2, written down once so the dumped Mac frames can be held to
/// the ADR's worked examples. Not the Linux implementation (`Snapper`, WOR-316 S1): a check that
/// the rules, applied to what the Mac actually lays out, give the numbers the ADR promises.
/// Rounding is Swift `.rounded()` (half away from zero), never banker's.
enum SnapReference {
    /// `.points`: one edge, converted on its own.
    static func edge(_ points: Double, scale: Double) -> Int {
        Int((points * scale).rounded())
    }

    /// `.points`: a span, each edge snapped on its own — never origin plus rounded size.
    static func span(_ start: Double, _ end: Double, scale: Double) -> Range<Int> {
        edge(start, scale: scale)..<edge(end, scale: scale)
    }

    /// `.mark(d)`: the origin snaps as an edge, the extent is `max(1, round(d × s))` wherever it
    /// lands, so a 7 pt dot is the same size on every row.
    static func mark(origin: Double, extent: Double, scale: Double) -> Range<Int> {
        let start = edge(origin, scale: scale)
        return start..<(start + max(1, Int((extent * scale).rounded())))
    }

    /// Strokes: `max(1, round(w × s))` device pixels, drawn inside the snapped rect.
    static func stroke(_ width: Double, scale: Double) -> Int {
        max(1, Int((width * scale).rounded()))
    }

    /// `.hairline`: exactly one device pixel at the snapped edge, at every scale.
    static func hairline(at points: Double, scale: Double) -> Range<Int> {
        let start = edge(points, scale: scale)
        return start..<(start + 1)
    }
}

// MARK: - Pixel diff, for the artifacts

/// How two same-sized renders differ, and a picture of it: differing pixels red, the rest the
/// golden at a third of its brightness. Diagnostic only — L5's thresholds are WOR-322's.
struct PixelDiff: Sendable {
    var differing: Int
    var total: Int
    var maxChannelDelta: Int
    /// RGBA, the size of both inputs.
    var image: [UInt8]

    /// `nil` when the two are not the same size: the layout comparison already says why.
    static func between(golden: PNGImage, rendered: PNGImage) -> PixelDiff? {
        guard golden.width == rendered.width, golden.height == rendered.height else { return nil }
        let count = golden.width * golden.height
        var image = [UInt8](repeating: 255, count: count * 4)
        var differing = 0
        var worst = 0
        for pixel in 0..<count {
            let offset = pixel * 4
            var delta = 0
            for channel in 0..<4 {
                delta = max(delta, abs(Int(golden.pixels[offset + channel]) - Int(rendered.pixels[offset + channel])))
            }
            worst = max(worst, delta)
            if delta > 0 {
                differing += 1
                image[offset] = 255
                image[offset + 1] = 0
                image[offset + 2] = 0
            } else {
                for channel in 0..<3 { image[offset + channel] = golden.pixels[offset + channel] / 3 }
            }
        }
        return PixelDiff(differing: differing, total: count, maxChannelDelta: worst, image: image)
    }
}
