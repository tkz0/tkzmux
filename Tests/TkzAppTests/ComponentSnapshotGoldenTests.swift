// ComponentSnapshotGoldenTests — the committed goldens (WOR-307 S2) and ADR-0003's worked
// examples checked against what the Mac actually lays out.
//
// Three suites:
//
//   * `ComponentSnapshotGoldenTests` holds every `ComponentCatalog` entry to its golden, for the
//     3 presets at 2.0 and 1.6. On the manifest's macOS build the PNG and the JSON must match byte
//     for byte. On any other build the layout must match (frames, flags, strings and facts
//     exactly; measured text within ±0.5 pt) and a PNG that differs is written, with a diff, to
//     `$TKZMUX_TEST_ARTIFACTS/component-snapshots/diff/` instead of failing: CoreText drifts
//     between macOS builds (ADR-0003, "references drift with the runner image").
//     Skipped, with a message, while no goldens are committed.
//   * With `TKZMUX_UPDATE_SNAPSHOTS=1` the same suite renders each case twice, refuses to write
//     a render that is not reproducible, and writes the PNG, the JSON and the manifest into
//     `Tests/TkzAppTests/ComponentSnapshots/`. Run it on the reference runner only
//     (ADR-0003 §5; docs/linux/parity.md, "Updating the goldens").
//   * `ComponentSnapshotADRTests` needs no goldens: it renders the components ADR-0003 §2's
//     worked examples are about, applies the snapping rules to the dumped frames, and requires
//     the ADR's numbers. A mismatch is an ADR fix (WOR-299), never a Mac change.
//
// Serialised and main-actor, like the other rendering suites: they share the process font
// registry, the `CATransaction` stack and `LayerContentsScale`, and the update writes one manifest.

import AppKit
import Testing
import TkzCore
import TkzPNG

@testable import TkzApp

// MARK: - The host

/// The facts about this machine the manifest records (ADR-0003 §5).
enum ComponentHostInfo {
    /// `sysctl kern.osversion`: the build byte equality is promised on.
    static let macOSBuild: String = sysctlString("kern.osversion") ?? "unknown"

    @MainActor private static var cached: ComponentHost?

    @MainActor
    static func current() -> ComponentHost {
        if let cached { return cached }
        let environment = ProcessInfo.processInfo.environment
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let defaults = UserDefaults.standard
        let host = ComponentHost(
            macOSBuild: macOSBuild,
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            xcode: xcodeVersion() ?? "unknown",
            imageOS: environment["ImageOS"] ?? "unset",
            imageVersion: environment["ImageVersion"] ?? "unset",
            appleFontSmoothing: defaults.object(forKey: "AppleFontSmoothing").map { "\($0)" } ?? "unset",
            fontSmoothingDisabled: defaults.object(forKey: "CGFontRenderingFontSmoothingDisabled").map { "\($0)" } ?? "unset",
            displayProfile: NSScreen.screens.isEmpty
                ? "none, headless" : (NSScreen.main?.colorSpace?.localizedName ?? "unknown"))
        cached = host
        return host
    }

    static var provenance: ComponentManifest.Provenance {
        let environment = ProcessInfo.processInfo.environment
        return .init(commit: environment["GITHUB_SHA"] ?? "unset", runID: environment["GITHUB_RUN_ID"] ?? "unset")
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `Xcode 26.1 Build version 17B55`, from the selected toolchain.
    static func xcodeVersion() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild", "-version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

// MARK: - Checking one render

@MainActor
enum ComponentGoldenCheck {
    /// Holds `snapshot` to its committed golden, recording an issue per failure.
    static func check(_ snapshot: ComponentCase.Snapshot, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let stem = ComponentSnapshot.fileStem(snapshot.layout)
        let directory = ComponentGoldens.directory()
        let pngURL = directory.appendingPathComponent(ComponentGoldens.pngName(stem))
        let jsonURL = directory.appendingPathComponent(ComponentGoldens.jsonName(stem))
        guard FileManager.default.fileExists(atPath: pngURL.path),
              FileManager.default.fileExists(atPath: jsonURL.path) else {
            Issue.record(
                "no golden for \(stem): regenerate the set on the reference runner (\(ComponentGoldens.regenerateCommand))",
                sourceLocation: sourceLocation)
            return
        }
        let goldenPNG = try Data(contentsOf: pngURL)
        let goldenJSON = try Data(contentsOf: jsonURL)
        let json = try snapshot.layout.jsonData()
        let reference = try ComponentGoldens.readManifest()?.reference.macOSBuild
        let onReference = reference == ComponentHostInfo.macOSBuild

        if json != goldenJSON {
            let golden = try JSONDecoder().decode(LayoutDump.self, from: goldenJSON)
            let differences = LayoutComparison.differences(golden: golden, actual: snapshot.layout)
            if onReference || !differences.isEmpty {
                let detail = differences.isEmpty ? ["same structure, different bytes"] : Array(differences.prefix(20))
                Issue.record(
                    "\(stem): the layout differs from its golden\n  \(detail.joined(separator: "\n  "))",
                    sourceLocation: sourceLocation)
            }
        }
        if snapshot.png != goldenPNG {
            let summary = try writeDiff(stem: stem, rendered: snapshot.png, golden: goldenPNG)
            if onReference {
                Issue.record("\(stem): the pixels differ from its golden (\(summary))", sourceLocation: sourceLocation)
            } else {
                print("component snapshot \(stem): pixels differ on build \(ComponentHostInfo.macOSBuild) "
                    + "(goldens are from \(reference ?? "unknown")): \(summary); not a failure off the reference build")
            }
        }
    }

    /// Writes the rendered PNG, the golden and a diff image under
    /// `$TKZMUX_TEST_ARTIFACTS/component-snapshots/diff/` when that is set. Returns a one-line summary.
    static func writeDiff(stem: String, rendered: Data, golden: Data) throws -> String {
        let renderedImage = try PNG.decode([UInt8](rendered))
        let goldenImage = try PNG.decode([UInt8](golden))
        let diff = PixelDiff.between(golden: goldenImage, rendered: renderedImage)
        let summary = diff.map {
            "\($0.differing) of \($0.total) pixels, worst channel delta \($0.maxChannelDelta)"
        } ?? "golden \(goldenImage.width)×\(goldenImage.height), rendered \(renderedImage.width)×\(renderedImage.height)"
        guard let root = ProcessInfo.processInfo.environment["TKZMUX_TEST_ARTIFACTS"] else { return summary }
        let folder = URL(fileURLWithPath: root).appendingPathComponent("component-snapshots/diff", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try rendered.write(to: folder.appendingPathComponent(stem + ".rendered.png"))
        try golden.write(to: folder.appendingPathComponent(stem + ".golden.png"))
        if let diff {
            let png = try PNG.encode(diff.image, width: goldenImage.width, height: goldenImage.height, colorType: .rgba)
            try Data(png).write(to: folder.appendingPathComponent(stem + ".diff.png"))
        }
        return summary
    }

    /// Set once the update has said the set is over budget, so it says it once.
    private static var reportedOverBudget = false

    /// Update mode: render again, and write only a render that came out the same twice.
    static func update(_ entry: ComponentCase, theme: Theme, scale: Double, first: ComponentCase.Snapshot) throws {
        let stem = ComponentSnapshot.fileStem(first.layout)
        let again = try entry.render(theme, scale)
        let json = try first.layout.jsonData()
        guard again.png == first.png, try again.layout.jsonData() == json else {
            Issue.record("\(stem): two renders in one process differ; not written. The component is not deterministic.")
            return
        }
        let offGrid: (component: String, edges: [String])? =
            stem == ComponentGoldens.offGridStem(entry.name) ? (entry.name, OffGridEdges.list(first.layout)) : nil
        let total = try ComponentGoldens.record(
            stem: stem, png: first.png, json: json, offGrid: offGrid,
            host: ComponentHostInfo.current(), provenance: ComponentHostInfo.provenance)
        if total > ComponentGoldens.budgetBytes, !reportedOverBudget {
            reportedOverBudget = true
            Issue.record("""
                the component goldens are \(total) bytes, over WOR-307's \(ComponentGoldens.budgetBytes)-byte \
                share (ADR-0003 §5). Renegotiate the split in ADR-0003 rather than dropping coverage; \
                manifest.json lists every file's size.
                """)
        }
    }
}

// MARK: - Goldens

@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ComponentGoldens.isAvailable,
        "No component goldens are committed yet. Generate them on the reference runner: TKZMUX_UPDATE_SNAPSHOTS=1 swift test --no-parallel --filter ComponentSnapshot (docs/linux/parity.md)"))
struct ComponentSnapshotGoldenTests {
    @Test("Every component matches its golden at 2.0 and 1.6", arguments: ComponentCatalog.all, Theme.allPresets)
    func matchesGolden(entry: ComponentCase, theme: Theme) throws {
        for scale in ComponentSnapshot.scales {
            let snapshot = try entry.render(theme, scale)
            #expect(snapshot.layout.component == entry.name)
            try ComponentSnapshot.writeArtifacts(snapshot)
            if ComponentGoldens.isUpdating {
                try ComponentGoldenCheck.update(entry, theme: theme, scale: scale, first: snapshot)
            } else {
                try ComponentGoldenCheck.check(snapshot)
            }
        }
    }

    @Test(
        "The manifest lists exactly the files on disk, hashes them right and stays within budget",
        .disabled(if: ComponentGoldens.isUpdating, "the update is still writing the set"))
    func manifestIsSound() throws {
        let problems = try ComponentGoldens.audit()
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        if let manifest = try ComponentGoldens.readManifest() {
            let largest = ComponentGoldens.sizesByComponent(manifest).prefix(5)
                .map { "\($0.component) \($0.bytes)" }.joined(separator: ", ")
            print("component goldens: \(manifest.totalBytes) of \(manifest.budgetBytes) bytes; largest: \(largest)")
        }
    }

    @Test(
        "There is a golden for every catalog entry, preset and scale, and nothing else",
        .disabled(if: ComponentGoldens.isUpdating, "the update is still writing the set"))
    func goldensMatchTheCatalog() throws {
        var expected: Set<String> = []
        for entry in ComponentCatalog.all {
            for theme in Theme.allPresets {
                for scale in ComponentSnapshot.scales {
                    let stem = "\(entry.name)@\(theme.preset.rawValue)@\(scale)"
                    expected.insert(ComponentGoldens.pngName(stem))
                    expected.insert(ComponentGoldens.jsonName(stem))
                }
            }
        }
        let present = Set(try ComponentGoldens.goldenFileNames())
        let missing = expected.subtracting(present).sorted()
        let extra = present.subtracting(expected).sorted()
        #expect(missing.isEmpty, "no golden for: \(missing.joined(separator: ", "))")
        #expect(extra.isEmpty, "goldens no catalog entry renders (delete them): \(extra.joined(separator: ", "))")
    }
}

// MARK: - ADR-0003 worked examples

@MainActor
@Suite(.serialized)
struct ComponentSnapshotADRTests {
    static func entry(_ name: String) throws -> ComponentCase {
        try #require(ComponentCatalog.all.first { $0.name == name }, "no catalog entry \(name)")
    }

    static func dump(_ name: String, scale: Double) throws -> LayoutDump {
        try entry(name).render(.default, scale).layout
    }

    @Test("Catalog names are unique, dotted and file-safe")
    func catalogNames() {
        let names = ComponentCatalog.names
        #expect(Set(names).count == names.count, "duplicate catalog names")
        for name in names {
            #expect(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." }, "\(name)")
            #expect(!name.contains("@"), "\(name)")
        }
    }

    @Test("Example 1: a glass sheet's 1 pt border is 2 px at 1.6 and at 2.0", arguments: ComponentSnapshot.scales)
    func borderStroke(scale: Double) throws {
        let dump = try Self.dump("sheets.rebase", scale: scale)
        let width = try #require(dump.facts["borderWidth"].flatMap(Double.init))
        #expect(width == 1)
        #expect(SnapReference.stroke(width, scale: scale) == 2)
    }

    @Test("Example 2: the 1.5 pt focus ring is 2 px at 1.6 and 3 px at 2.0", arguments: ComponentSnapshot.scales)
    func focusRing(scale: Double) throws {
        let dump = try Self.dump("panes.chrome.focused", scale: scale)
        let width = try #require(dump.facts["focusRingWidth"].flatMap(Double.init))
        #expect(width == 1.5)
        #expect(SnapReference.stroke(width, scale: scale) == (scale == 2 ? 3 : 2))
        let unfocused = try Self.dump("panes.chrome.unfocused", scale: scale)
        #expect(unfocused.facts["focusRingWidth"] == "0.0")
    }

    @Test("Example 3: the 7 pt dot of a 44 pt row is a mark, 11×11 px at 1.6 on every row, 14×14 at 2.0", arguments: ComponentSnapshot.scales)
    func statusDot(scale: Double) throws {
        let dump = try Self.dump("sidebar.sessionRow.plain", scale: scale)
        #expect(dump.root.frame.height == 44)
        let dot = try #require(dump.nodes(ofType: "StatusDotLayer").first).frame
        #expect(dot == LayoutDump.Rect(x: 30, y: 18, width: 7, height: 7))
        let rowHeight = dump.root.frame.height

        func dotPixels(row k: Int) -> (x: Range<Int>, y: Range<Int>) {
            let top = Double(k) * rowHeight + dot.y
            return (SnapReference.mark(origin: dot.x, extent: dot.width, scale: scale),
                    SnapReference.mark(origin: top, extent: dot.height, scale: scale))
        }
        if scale == 1.6 {
            #expect(dotPixels(row: 0).x == 48..<59)
            #expect(dotPixels(row: 0).y == 29..<40)
            #expect(dotPixels(row: 4).y == 310..<321)
            // What `.mark` exists to prevent: per-edge rounding makes row 4's dot 12 px tall.
            let top = 4 * rowHeight + dot.y
            #expect(SnapReference.span(top, top + dot.height, scale: scale) == 310..<322)
        } else {
            for k in 0..<10 {
                #expect(dotPixels(row: k).x == 60..<74)
                #expect(dotPixels(row: k).y == (88 * k + 36)..<(88 * k + 50))
            }
        }
    }

    @Test("Example 4: ten 44 pt rows snap edge by edge, 704 px at 1.6 and 880 at 2.0", arguments: ComponentSnapshot.scales)
    func rowEdges(scale: Double) throws {
        let dump = try Self.dump("sidebar.sessionRow.plain", scale: scale)
        let height = dump.root.frame.height
        let edges = (0...10).map { SnapReference.edge(Double($0) * height, scale: scale) }
        if scale == 1.6 {
            #expect(edges == [0, 70, 141, 211, 282, 352, 422, 493, 563, 634, 704])
            #expect(zip(edges, edges.dropFirst()).map { $1 - $0 } == [70, 71, 70, 71, 70, 70, 71, 70, 71, 70])
        } else {
            #expect(edges == (0...10).map { 88 * $0 })
        }
    }

    @Test("Example 5: the 300 pt sidebar is [0, 480) at 1.6 and [0, 600) at 2.0, its bounds 240 and 520 pt", arguments: ComponentSnapshot.scales)
    func sidebarWidth(scale: Double) throws {
        let row = try Self.dump("sidebar.sessionRow.plain", scale: scale)
        let narrow = try Self.dump("sidebar.sessionRow.wrapped", scale: scale)
        #expect(row.root.frame.width == 300)
        #expect(narrow.root.frame.width == 240)
        #expect(narrow.root.frame.height == SidebarMetrics.sessionRowWrappedHeight)
        // The maximum is a literal in `MainWindowController` (`sidebarItem.maximumThickness = 520`).
        let maximum = 520.0
        let expected: (sidebar: Range<Int>, min: Int, max: Int, dragged: Int) =
            scale == 1.6 ? (0..<480, 384, 832, 481) : (0..<600, 480, 1_040, 601)
        #expect(SnapReference.span(0, row.root.frame.width, scale: scale) == expected.sidebar)
        #expect(SnapReference.edge(narrow.root.frame.width, scale: scale) == expected.min)
        #expect(SnapReference.edge(maximum, scale: scale) == expected.max)
        #expect(SnapReference.edge(300.5, scale: scale) == expected.dragged)
    }

    @Test("Example 6: the 36 pt status bar at the foot of an 820 pt window, and its one-pixel top line", arguments: ComponentSnapshot.scales)
    func statusBar(scale: Double) throws {
        let dump = try Self.dump("statusBar.wide", scale: scale)
        #expect(dump.root.frame.height == 36)
        let window = Double(MainWindowController.defaultWindowSize.height)
        #expect(window == 820)
        let top = window - dump.root.frame.height
        let bar = SnapReference.span(top, window, scale: scale)
        let line = SnapReference.hairline(at: top, scale: scale)
        if scale == 1.6 {
            #expect(bar == 1_254..<1_312)
            #expect(line == 1_254..<1_255)
            #expect(dump.pixels.height.pixels == 58)
            #expect(dump.pixels.height.roundedUp)
        } else {
            #expect(bar == 1_568..<1_640)
            #expect(line == 1_568..<1_569)
            #expect(dump.pixels.height.pixels == 72)
        }
    }

    @Test("At 2.0 every dumped edge off the 0.5 pt grid is listed, for ADR-0003's exception table")
    func offGridEdges() throws {
        var lines: [String] = []
        for entry in ComponentCatalog.all {
            let dump = try entry.render(.default, 2.0).layout
            lines += OffGridEdges.list(dump).map { "\(entry.name): \($0)" }
        }
        print("component snapshots: \(lines.count) dumped edge(s) off the 0.5 pt grid at 2.0"
            + (lines.isEmpty ? "" : "\n  " + lines.joined(separator: "\n  ")))
        if let root = ProcessInfo.processInfo.environment["TKZMUX_TEST_ARTIFACTS"] {
            let folder = URL(fileURLWithPath: root).appendingPathComponent("component-snapshots", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8)
                .write(to: folder.appendingPathComponent("offgrid-edges-2.0.txt"))
        }
        // Once goldens exist the manifest carries the same lists (`ComponentGoldens.audit`), and
        // on the reference build they must be what this run found. Not while an update is still
        // writing the manifest.
        if !ComponentGoldens.isUpdating, let manifest = try ComponentGoldens.readManifest(),
           manifest.reference.macOSBuild == ComponentHostInfo.macOSBuild {
            let recorded = manifest.offGridEdges.sorted { $0.key < $1.key }
                .flatMap { component, edges in edges.map { "\(component): \($0)" } }
            #expect(recorded.sorted() == lines.sorted())
        }
    }
}
