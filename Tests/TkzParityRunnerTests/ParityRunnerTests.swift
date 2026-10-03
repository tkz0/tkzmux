// The Linux parity runner (WOR-322 S3; ADR-0003 §3): one test case per row of Tests/Parity/layers.json.
//
//   pending    reported with its owner issue; never fails.
//   enforced   its producer (ParityProducers.registry) writes the Linux artifacts from a child
//              process with no display, and its check compares them with the references. A
//              threshold breach fails. A row whose references are not committed yet is skipped with
//              the producer's message, unless TKZMUX_REQUIRE_PARITY_REFERENCES=1; an enforced row
//              with no registered producer fails.
//
// Everything lands in `.build/parity/<layer>@<scale>/` (or $TKZMUX_PARITY_OUT): `produced/` (the
// artifacts), `reports/` (JSON, heatmaps and, on a failure, a copy of the reference), the
// producer's log and `result.json`. The `parity` job in ci-linux.yml uploads the directory when it
// fails. Run it with `swift test --build-system native --filter TkzParityRunnerTests`.

import Foundation
import Testing
import TkzParity
import TkzPNG
import TkzRenderCore

/// One row's outcome, as `result.json` records it.
struct RowResult: Codable {
    var layer: String
    var scale: Double
    var state: String
    var owner: String
    /// `pending`, `skipped`, `passed` or `failed`.
    var outcome: String
    var failures: [String] = []
    var notes: [String] = []
}

enum ParityRunner {
    static func manifest() throws -> LayerManifest {
        try LayerManifest.decode(Data(contentsOf: ParityPaths.layerManifest))
    }

    /// The manifest's rows, for the parameterized tests; empty when it does not decode, which
    /// `theManifestLoads` reports.
    static let rows: [LayerManifest.Row] = (try? manifest().rows) ?? []
    static let enforcedRows: [LayerManifest.Row] = rows.filter { $0.state == .enforced }

    static var requiresReferences: Bool {
        ProcessInfo.processInfo.environment["TKZMUX_REQUIRE_PARITY_REFERENCES"] == "1"
    }

    /// Runs one row and writes its `result.json`.
    static func run(_ row: LayerManifest.Row) throws -> RowResult {
        let name = ParityPaths.rowName(row.layer, row.scale)
        let directory = try ParityPaths.freshDirectory(name)
        var result = RowResult(layer: row.layer, scale: row.scale, state: row.state.rawValue, owner: row.owner, outcome: "")
        defer {
            try? ParityReports.writeJSON(result, to: directory.appending(path: "result.json"))
            var line = "parity \(name): \(result.outcome.uppercased())"
            line += row.state == .pending ? ", owner \(row.owner)" : ""
            for failure in result.failures { line += "\n  ✗ \(failure)" }
            for note in result.notes { line += "\n  · \(note)" }
            print(line)
        }

        guard row.state == .enforced else {
            result.outcome = "pending"
            return result
        }
        guard let producer = ParityProducers.registry[row.layer] else {
            result.outcome = "failed"
            result.failures = ["enforced, but no producer is registered for \(row.layer) (ParityProducers.registry)"]
            return result
        }
        if let missing = producer.missingReferences(row.scale) {
            if requiresReferences {
                result.outcome = "failed"
                result.failures.append("references missing (TKZMUX_REQUIRE_PARITY_REFERENCES=1): \(missing)")
            } else {
                result.outcome = "skipped"
                result.notes.append("references missing: \(missing)")
            }
            return result
        }

        let produced = directory.appending(path: "produced", directoryHint: .isDirectory)
        let reports = directory.appending(path: "reports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: produced, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        do {
            result.failures += try producer.produce(ProducerContext(
                scale: row.scale, environment: ParityEnvironment.base, output: produced,
                log: directory.appending(path: "producer.log")))
            let (failures, notes) = try producer.check(row.scale, produced, reports)
            result.failures += failures
            result.notes += notes
        } catch {
            result.failures.append("\(error)")
        }
        result.outcome = result.failures.isEmpty ? "passed" : "failed"
        return result
    }
}

extension LayerManifest.Row: CustomTestStringConvertible {
    public var testDescription: String { "\(layer)@\(scale) \(state.rawValue)" }
}

@Suite struct ParityRunnerTests {
    @Test func theManifestLoads() throws {
        let manifest = try ParityRunner.manifest()
        #expect(manifest.problems() == [])
        #expect(ParityRunner.rows.count == manifest.rows.count)
    }

    @Test("every row of layers.json", arguments: ParityRunner.rows)
    func row(_ row: LayerManifest.Row) throws {
        let result = try ParityRunner.run(row)
        #expect(result.outcome != "failed",
                "\(row.layer)@\(row.scale): \(result.failures.joined(separator: "; ")) (see .build/parity/\(row.layer)@\(row.scale)/)")
    }

    /// Every registered producer belongs to a layer the manifest knows, and every layer with a
    /// producer is enforced at both scales: registering a producer is what switches a layer on.
    @Test func registeredProducersAreEnforced() throws {
        let manifest = try ParityRunner.manifest()
        for (layer, producer) in ParityProducers.registry {
            #expect(producer.layer == layer)
            #expect(LayerManifest.layers.contains(layer), "\(layer) is not a layer of ADR-0003")
            for scale in LayerManifest.scales {
                #expect(manifest.row(layer, scale: scale)?.state == .enforced, "\(layer)@\(scale) has a producer but is not enforced")
            }
        }
    }

    /// WOR-322 enforces L2 itself (ADR-0003 §3).
    @Test func l2IsEnforcedAtBothScales() throws {
        let manifest = try ParityRunner.manifest()
        for scale in LayerManifest.scales {
            #expect(manifest.row("L2", scale: scale)?.state == .enforced)
        }
        #expect(ParityThresholds.l2Exact)
    }

    /// A flipped byte in an L2 reference fails the check, names the field it hit and leaves the
    /// diff and the reference in the reports: what CI shows when a FrameBuilder change moves one
    /// instance. The committed references are not touched; a copy of one is replayed, then flipped.
    @Test func aFlippedReferenceByteFailsL2WithItsDiff() throws {
        let scale = 1.6
        let fixture = "synthetic-basic"
        let stem = FrameDump.stem(fixture: fixture, scale: scale)
        let references = try ParityPaths.freshDirectory("selftest", "flipped", "references")
        for suffix in ["json", "bin"] {
            try FileManager.default.copyItem(at: L2Producer.referenceDirectory.appending(path: "\(stem).\(suffix)"),
                                             to: references.appending(path: "\(stem).\(suffix)"))
        }
        let produced = try ParityPaths.freshDirectory("selftest", "flipped", "produced")
        let recording = try #require(L2Producer.recordings.first { $0.lastPathComponent == "\(fixture).tkzrec" })
        let outcome = try ParityProcess.run(
            try ParityPaths.vtdump(),
            ["framedump", "--replay", references.path, "--scale", "\(scale)", "--out", produced.path, recording.path],
            environment: ParityEnvironment.base, log: produced.appending(path: "producer.log"))
        #expect(outcome.status == 0, "\(outcome.tail)")

        let clean = try ParityPaths.freshDirectory("selftest", "flipped", "reports-clean")
        let passing = try L2Producer.check(scale: scale, produced: produced, reports: clean,
                                           references: references, fixtures: [fixture])
        #expect(passing.failures.isEmpty, "\(passing.failures)")

        // Flip one bit of the first glyph instance's atlas position.
        let binary = references.appending(path: "\(stem).bin")
        let dump = try FrameDump.decode(Data(contentsOf: references.appending(path: "\(stem).json")))
        let offset = dump.buffers[0].stride * dump.buffers[0].count + 12
        var bytes = try [UInt8](Data(contentsOf: binary))
        bytes[offset] ^= 0x01
        try Data(bytes).write(to: binary)

        let reports = try ParityPaths.freshDirectory("selftest", "flipped", "reports")
        let failing = try L2Producer.check(scale: scale, produced: produced, reports: reports,
                                           references: references, fixtures: [fixture])
        #expect(failing.failures.count == 1)
        #expect(failing.failures.first?.contains("glyphs[0].atlasPos.x (bytes \(offset)..<\(offset + 2))") == true,
                "\(failing.failures)")
        let report = try String(contentsOf: reports.appending(path: "\(stem).bin.json"), encoding: .utf8)
        #expect(report.contains("\"firstDifference\":\(offset)"))
        #expect(FileManager.default.fileExists(atPath: reports.appending(path: "reference/\(stem).bin").path))
    }

    /// The image helper the image layers' producers report through: a JSON report and a heatmap.
    @Test func imageReportsWriteJSONAndAHeatmap() throws {
        let directory = try ParityPaths.freshDirectory("selftest", "image-report")
        func png(_ grey: UInt8) throws -> URL {
            let url = directory.appending(path: "grey-\(grey).png")
            let pixels = [UInt8](repeating: grey, count: 16 * 16 * 3)
            try Data(PNG.encode(pixels, width: 16, height: 16, colorType: .rgb)).write(to: url)
            return url
        }
        let report = try ParityReports.compareImages(reference: try png(100), produced: try png(110), gate: .golden,
                                                     name: "pair", into: directory.appending(path: "reports"))
        #expect(!report.pass)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "reports/pair.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "reports/pair.heatmap.png").path))
    }
}
