// CompareCommand — `tkzmux-vtdump compare <a> <b> [--mask m.json] [--json out] [--heatmap out.png]
// [--layer golden|exact|L3|L4|L5|L6]` (WOR-322 S1).
//
// The one comparison tool ADR-0003 §3 names, on both OSes. Two PNGs are compared as images:
// channel rule, SSIM (global and per 64 px tile), masks and ΔE2000, judged by the gate `--layer`
// picks (default `golden`, the golden comparator's channel 2 / 0.002). Anything else is compared
// byte for byte; a pair where either side ends in `.json` is equal when it is equal after canonical
// key order (L0). There are no flags that set a threshold: the gates are ADR-0003's constants.
//
// Prints a summary on stdout. Exit 0 when the gate passes, 1 when it fails (a size mismatch
// included), 2 for a usage or input error (an unknown option is one).

import Foundation
import TkzParity

enum CompareCommand {
    static func run(_ argv: [String]) throws {
        let valueFlags: Set<String> = ["mask", "json", "heatmap", "layer"]
        let arguments = Arguments(argv, valueFlags: valueFlags)
        // A gate tool must not ignore a flag it does not know: a mistyped option would silently
        // compare under the default gate.
        if let unknown = arguments.flags.keys.sorted().first(where: { !valueFlags.contains($0) }) {
            fail("tkzmux-vtdump compare: unknown option --\(unknown)", code: 2)
        }
        guard arguments.positionals.count == 2 else {
            fail("tkzmux-vtdump compare: expected <a> <b>\n\n\(usage)", code: 2)
        }
        let pathA = arguments.positionals[0], pathB = arguments.positionals[1]
        guard let dataA = FileManager.default.contents(atPath: pathA) else {
            fail("tkzmux-vtdump compare: cannot read \(pathA)", code: 2)
        }
        guard let dataB = FileManager.default.contents(atPath: pathB) else {
            fail("tkzmux-vtdump compare: cannot read \(pathB)", code: 2)
        }
        let bytesA = [UInt8](dataA), bytesB = [UInt8](dataB)

        let isImage = isPNG(bytesA) && isPNG(bytesB)
        if !isImage {
            for flag in ["mask", "heatmap", "layer"] where arguments.has(flag) {
                fail("tkzmux-vtdump compare: --\(flag) applies to two PNGs only", code: 2)
            }
            let json = [pathA, pathB].contains { $0.lowercased().hasSuffix(".json") }
            var report = ByteComparison.compare(bytesA, bytesB, json: json)
            report.a = pathA
            report.b = pathB
            printSummary(report)
            try writeJSON(report, to: arguments.value("json"))
            if !report.pass { exit(1) }
            return
        }

        var gate = ParityGate.golden
        if let name = arguments.value("layer") {
            guard let named = ParityGate.named(name) else {
                fail("tkzmux-vtdump compare: unknown --layer \(name) "
                     + "(one of \(ParityGate.all.map(\.name).joined(separator: ", ")))", code: 2)
            }
            gate = named
        }
        var masks: ParityMaskSet?
        if let maskPath = arguments.value("mask") {
            guard let data = FileManager.default.contents(atPath: maskPath) else {
                fail("tkzmux-vtdump compare: cannot read \(maskPath)", code: 2)
            }
            do {
                masks = try ParityMaskSet.decode(data)
            } catch {
                fail("tkzmux-vtdump compare: \(maskPath): \(error)", code: 2)
            }
        }
        let imageA: ParityImage, imageB: ParityImage
        do {
            imageA = try ParityImage(pngBytes: bytesA)
            imageB = try ParityImage(pngBytes: bytesB)
        } catch {
            fail("tkzmux-vtdump compare: cannot decode the PNGs: \(error)", code: 2)
        }

        var result = ImageComparison.compare(imageA, imageB, masks: masks, gate: gate)
        result.report.a = pathA
        result.report.b = pathB
        if let heatmapPath = arguments.value("heatmap"), let png = try ImageComparison.heatmapPNG(result) {
            try Data(png).write(to: URL(fileURLWithPath: heatmapPath), options: .atomic)
            result.report.heatmap = heatmapPath
        }
        printSummary(result.report)
        try writeJSON(result.report, to: arguments.value("json"))
        if !result.report.pass { exit(1) }
    }

    static func isPNG(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// The report as compact JSON with sorted keys and a trailing newline, so two runs diff cleanly.
    static func writeJSON(_ report: some Encodable, to path: String?) throws {
        guard let path else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(report)
        data.append(0x0A)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func printSummary(_ report: ImageComparisonReport) {
        var lines = ["\(report.pass ? "PASS" : "FAIL")  gate \(report.gate.name)  "
                     + "\(report.sizeA.width)×\(report.sizeA.height)"]
        if let channel = report.channel {
            lines.append("  channel   \(channel.differingPixels) of \(channel.comparedPixels) px differ by more than "
                         + "\(channel.tolerance) (\(percent(channel.fraction))), worst delta \(channel.worstDelta)")
        }
        if let ssim = report.ssim {
            let global = ssim.global.map { String(format: "%.6f", $0) } ?? "n/a (all masked)"
            let worst = ssim.worstTile.map { String(format: "%.6f", $0.ssim) + " at (\($0.x), \($0.y))" } ?? "n/a"
            lines.append("  ssim      \(global); worst \(ssim.tileSize) px tile \(worst)")
        }
        if report.maskedPixels > 0 {
            let kinds = report.maskedByKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            lines.append("  masked    \(report.maskedPixels) px (\(percent(report.maskedFraction))): "
                         + kinds.joined(separator: ", "))
        }
        if let deltaE = report.deltaE2000 {
            lines.append(String(format: "  ΔE2000    mean %.4f, p99 %.4f (diagnostic)", deltaE.mean, deltaE.p99))
        }
        if let heatmap = report.heatmap { lines.append("  heatmap   \(heatmap)") }
        lines += report.failures.map { "  ✗ \($0)" }
        print(lines.joined(separator: "\n"))
    }

    static func printSummary(_ report: ByteComparisonReport) {
        var lines: [String] = []
        if report.identical {
            lines.append("PASS  identical (\(report.sizeA) bytes)")
        } else if report.canonicalJSONEqual == true {
            lines.append("PASS  equal after canonical key order (\(report.sizeA) and \(report.sizeB) bytes)")
        } else {
            lines.append("FAIL  \(report.sizeA) and \(report.sizeB) bytes")
            if let offset = report.firstDifference {
                var at = "  first difference at byte \(offset)"
                if let line = report.firstDifferenceLine, let column = report.firstDifferenceColumn {
                    at += " (line \(line), column \(column))"
                }
                lines.append(at)
            }
            lines += (report.differingPaths ?? []).map { "  differs   \($0)" }
            lines += report.failures.map { "  ✗ \($0)" }
        }
        print(lines.joined(separator: "\n"))
    }

    static func percent(_ fraction: Double) -> String { String(format: "%.4f%%", fraction * 100) }
}
