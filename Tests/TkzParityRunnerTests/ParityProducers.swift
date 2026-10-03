// The producer registry (WOR-322 S3): layer → the closures that produce its Linux artifacts and
// check them against the reference runner's.
//
// The issue that lands a layer's producer adds it here and switches the layer's rows in
// Tests/Parity/layers.json to `enforced` in the same PR (WOR-312: L1 and L4; WOR-313 S3: L3;
// WOR-316–WOR-319: L0-component and L5; WOR-318 S7: L0-window and L6). Registering is all it takes:
// the runner (ParityRunnerTests) runs every enforced row through its producer, and
// EnvironmentIsolationTests reruns every enforced producer under the isolation variables.
//
// A producer writes its artifacts from a child process that runs with exactly the environment it is
// given (ParityProcess), never in this process.

import Foundation
import TkzParity
import TkzRenderCore

struct ProducerContext: Sendable {
    let scale: Double
    /// The child's whole environment.
    let environment: [String: String]
    /// An empty directory for the artifacts.
    let output: URL
    /// Where the child's stdout and stderr go.
    let log: URL
}

struct ParityProducer: Sendable {
    let layer: String
    /// Why the references this layer compares with are not committed at `scale`, or nil when they
    /// are. A layer whose references are missing is skipped with this message.
    let missingReferences: @Sendable (_ scale: Double) -> String?
    /// Writes the artifacts into `context.output`. Returns problems that do not stop the check
    /// (a child that exited non-zero but still wrote its files); throws when nothing was produced.
    let produce: @Sendable (_ context: ProducerContext) throws -> [String]
    /// Compares the artifacts in `produced` with the references, writes its reports (JSON, and
    /// heatmaps for images) into `reports`, and returns the failures: empty when the layer passes.
    let check: @Sendable (_ scale: Double, _ produced: URL, _ reports: URL) throws -> (failures: [String], notes: [String])
}

enum ParityProducers {
    static let registry: [String: ParityProducer] = [
        "L2": L2Producer.producer,
    ]
}

// MARK: - L2: FrameBuilder buffers (WOR-322 S3)

/// ADR-0003 L2: from the reference's cell metrics and atlas glyph table, the shared FrameBuilder must
/// write the reference's instance buffers byte for byte (`ParityThresholds.l2Exact`).
///
/// The references are `Tests/Parity/References/framebuilder/<fixture>@<scale>.{json,bin}`, written by
/// `tkzmux-vtdump framedump` over the platform's font stack (FrameDump.swift). The producer replays
/// each fixture with `framedump --replay`, which opens no font: the glyphs come from the reference's
/// table. Missing references fail L2 rather than skip it: the layer is shared code and its references
/// can be made on any machine (see docs/linux/parity.md, "The L2 references").
enum L2Producer {
    static var referenceDirectory: URL {
        ParityPaths.references.appending(path: "framebuilder", directoryHint: .isDirectory)
    }

    /// The recordings L2 replays: the four terminal fixtures and the L2 feature sheet.
    static var recordings: [URL] {
        let fixtures = ParityPaths.repoRoot.appending(path: "Tests/TkzTerminalCoreTests/Fixtures", directoryHint: .isDirectory)
        return ["claude-boot", "claude-tool-run", "synthetic-basic", "zsh-ls-color"]
            .map { fixtures.appending(path: "\($0).tkzrec") } + [L2FeatureSheet.url]
    }

    static var fixtureNames: [String] { recordings.map { $0.deletingPathExtension().lastPathComponent } }

    /// WOR-312's CellMetrics dump, written on the reference runner (WOR-312 S1).
    static var fontMetricsURL: URL { ParityPaths.references.appending(path: "fonts/fontmetrics.json") }

    static let producer = ParityProducer(
        layer: "L2",
        missingReferences: { _ in nil },
        produce: { context in
            let arguments = ["framedump", "--replay", referenceDirectory.path, "--scale", "\(context.scale)",
                             "--out", context.output.path] + recordings.map(\.path)
            let outcome = try ParityProcess.run(try ParityPaths.vtdump(), arguments,
                                                environment: context.environment, log: context.log)
            switch outcome.status {
            case 0: return []
            case 1: return ["tkzmux-vtdump framedump --replay exited 1:\n\(outcome.tail)"]
            default: throw ParityRunnerError("tkzmux-vtdump framedump --replay exited \(outcome.status):\n\(outcome.tail)")
            }
        },
        check: { scale, produced, reports in try check(scale: scale, produced: produced, reports: reports) })

    /// - Parameters:
    ///   - references, fixtures: the committed set by default; the self-tests pass a copy.
    static func check(scale: Double, produced: URL, reports: URL, references: URL = referenceDirectory,
                      fixtures: [String] = fixtureNames) throws -> (failures: [String], notes: [String]) {
        var failures: [String] = []
        var notes: [String] = []
        var platforms: Set<String> = []
        for fixture in fixtures {
            let stem = FrameDump.stem(fixture: fixture, scale: scale)
            let referenceJSON = references.appending(path: "\(stem).json")
            let referenceBinary = references.appending(path: "\(stem).bin")
            guard let referenceData = FileManager.default.contents(atPath: referenceJSON.path),
                  let referenceBytes = FileManager.default.contents(atPath: referenceBinary.path) else {
                failures.append("\(stem): no reference in Tests/Parity/References/framebuilder "
                                + "(scripts/parity-framebuilder-references.sh writes it; docs/linux/parity.md)")
                continue
            }
            let reference = try FrameDump.decode(referenceData)
            platforms.insert(reference.source.platform)
            guard let producedData = FileManager.default.contents(atPath: produced.appending(path: "\(stem).json").path),
                  let producedBytes = FileManager.default.contents(atPath: produced.appending(path: "\(stem).bin").path) else {
                failures.append("\(stem): the replay wrote no dump")
                continue
            }

            // The buffers: byte for byte, and on a difference, which fields of which instances.
            var binary = ByteComparison.compare([UInt8](referenceBytes), [UInt8](producedBytes), json: false)
            binary.a = referenceBinary.path
            binary.b = produced.appending(path: "\(stem).bin").path
            if !binary.identical {
                let fields = differingFields(reference: reference, [UInt8](referenceBytes), [UInt8](producedBytes))
                try ParityReports.writeJSON(BinaryDifference(comparison: binary, differingFields: fields),
                                            to: reports.appending(path: "\(stem).bin.json"))
                try copyReference(referenceJSON, referenceBinary, into: reports)
                failures.append("\(stem).bin differs from the reference (sizes \(binary.sizeA) and \(binary.sizeB)); first: "
                                + (fields.first ?? "byte \(binary.firstDifference ?? 0)"))
            }

            // The glyph table the replay packed: the same slots, in the same order, after canonical
            // key order (the two JSON encoders may print a number differently).
            var table = ByteComparison.compare([UInt8](referenceData), [UInt8](producedData), json: true)
            table.a = referenceJSON.path
            table.b = produced.appending(path: "\(stem).json").path
            if !table.pass {
                try ParityReports.writeJSON(table, to: reports.appending(path: "\(stem).json.json"))
                try copyReference(referenceJSON, referenceBinary, into: reports)
                failures.append("\(stem).json: the replayed glyph table differs, first at "
                                + (table.differingPaths?.first ?? "byte \(table.firstDifference ?? 0)"))
            }

            if let problem = try metricsAgainstFontMetricsDump(reference) { failures.append("\(stem): \(problem)") }
        }

        if FileManager.default.fileExists(atPath: fontMetricsURL.path) {
            notes.append("metrics checked against WOR-312's fonts/fontmetrics.json")
        } else {
            notes.append("fonts/fontmetrics.json (WOR-312 S1) is not committed: the replay uses the metrics the L2 references recorded")
        }
        if platforms != ["macos"] && !platforms.isEmpty {
            notes.append("the L2 references come from \(platforms.sorted().joined(separator: ", ")), not the reference runner: "
                         + "a Linux bootstrap until WOR-322 S2 commits the Mac set (docs/linux/parity.md)")
        }
        return (failures, notes)
    }

    /// Up to 20 differing fields, named by buffer, instance and field, with both values in hex.
    static func differingFields(reference: FrameDump, _ a: [UInt8], _ b: [UInt8]) -> [String] {
        var found: [String] = []
        var offset = 0
        while offset < max(a.count, b.count), found.count < 20 {
            let differs = offset >= a.count || offset >= b.count || a[offset] != b[offset]
            guard differs else { offset += 1; continue }
            guard let (description, range) = reference.locate(offset: offset) else {
                found.append("byte \(offset): past the reference's buffers (sizes \(a.count) and \(b.count))")
                break
            }
            func hex(_ bytes: [UInt8]) -> String {
                range.map { $0 < bytes.count ? String(format: "%02x", bytes[$0]) : "--" }.joined()
            }
            found.append("\(description): reference \(hex(a)), replay \(hex(b)) (little-endian)")
            offset = range.upperBound
        }
        return found
    }

    /// When WOR-312's fontmetrics.json is committed, the metrics an L2 reference was built on must
    /// be the ones it records for the terminal font at that size and scale.
    static func metricsAgainstFontMetricsDump(_ reference: FrameDump) throws -> String? {
        guard let data = FileManager.default.contents(atPath: fontMetricsURL.path) else { return nil }
        let dump = try JSONDecoder().decode(FontMetricsDump.self, from: data)
        guard let configuration = dump.configurations.first(where: {
            $0.font.hasPrefix("JetBrainsMono") && $0.pointSize == reference.pointSize && $0.scale == reference.scale
        }) else {
            return "fonts/fontmetrics.json has no JetBrains Mono \(reference.pointSize) pt at \(reference.scale) to check the metrics against"
        }
        return configuration.metrics == reference.metrics ? nil
            : "the reference's metrics are not fonts/fontmetrics.json's for \(reference.pointSize) pt at \(reference.scale)"
    }

    static func copyReference(_ urls: URL..., into directory: URL) throws {
        let target = directory.appending(path: "reference", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for url in urls {
            let destination = target.appending(path: url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: url, to: destination)
            }
        }
    }

    struct BinaryDifference: Encodable {
        let comparison: ByteComparisonReport
        let differingFields: [String]
    }

    /// The part of WOR-312's `vtdump fontmetrics --json` this check reads (FaceMetricsTests reads
    /// the same shape). TODO(WOR-312 S1): align with the schema the exporter commits.
    struct FontMetricsDump: Decodable {
        struct Configuration: Decodable {
            let font: String
            let pointSize: Double
            let scale: Double
            let metrics: AtlasDump.Metrics
        }
        let configurations: [Configuration]
    }
}
