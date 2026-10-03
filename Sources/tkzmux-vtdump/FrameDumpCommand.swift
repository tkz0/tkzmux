// FrameDumpCommand — `tkzmux-vtdump framedump`, the L2 parity producer (WOR-322 S3; ADR-0003 §3).
//
//   tkzmux-vtdump framedump --out <dir> [--scale s] [--fonts system|parity] <file.tkzrec> …
//       Replays each recording, builds one frame through FrameBuilder over the platform's font
//       stack (CoreText on the Mac, FreeType on Linux) at the theme's terminal size and backing
//       scale `s` (default 2), and writes `<dir>/<name>@<s>.json` (cell metrics and atlas glyph
//       table) and `<dir>/<name>@<s>.bin` (the instance buffers). This is the L2 reference.
//       `--fonts` is Linux only, as for `render`.
//
//   tkzmux-vtdump framedump --out <dir> --replay <refdir> [--scale s] <file.tkzrec> …
//       The same frame over `GlyphTableSource`: the metrics and glyph table come from
//       `<refdir>/<name>@<s>.json` and no font is opened. A FrameBuilder that matches the
//       reference's writes the reference's `.bin` again; the parity runner compares the two
//       (Tests/TkzParityRunnerTests). Exit 1 when the table could not answer every request.
//
// The dump itself (FrameDump.swift, TkzRenderCore) is shared code, so the Mac and Linux write one
// format; only the font stack behind it differs (`fontGlyphSource`, per OS).

import Foundation
import TkzCore
import TkzRenderCore
import TkzTerminalCore

enum FrameDumpCommand {
    static func run(_ argv: [String]) throws {
        let valueFlags: Set<String> = ["out", "scale", "fonts", "replay"]
        let arguments = Arguments(argv, valueFlags: valueFlags)
        if let unknown = arguments.flags.keys.sorted().first(where: { !valueFlags.contains($0) }) {
            fail("tkzmux-vtdump framedump: unknown option --\(unknown)", code: 2)
        }
        guard let out = arguments.value("out") else { fail("tkzmux-vtdump framedump: --out is required", code: 2) }
        guard !arguments.positionals.isEmpty else { fail("tkzmux-vtdump framedump: missing <file.tkzrec>", code: 2) }
        var scale = 2.0
        if let text = arguments.value("scale") {
            guard let value = Double(text), value.isFinite, value > 0 else {
                fail("tkzmux-vtdump framedump: --scale must be a positive number", code: 2)
            }
            scale = value
        }
        let replay = arguments.value("replay").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if replay != nil, arguments.has("fonts") {
            fail("tkzmux-vtdump framedump: --fonts and --replay exclude each other (a replay opens no font)", code: 2)
        }

        let output = URL(fileURLWithPath: out, isDirectory: true)
        let pointSize = Theme.default.fontMono.terminal
        var missed = false
        for path in arguments.positionals {
            let recordingURL = URL(fileURLWithPath: path)
            let fixture = recordingURL.deletingPathExtension().lastPathComponent
            let recording = try RecordingReader(contentsOf: recordingURL)

            let source: any GlyphSource
            let origin: FrameDump.Source
            var table: GlyphTableSource?
            if let replay {
                let referenceURL = replay.appendingPathComponent("\(FrameDump.stem(fixture: fixture, scale: scale)).json")
                guard let data = FileManager.default.contents(atPath: referenceURL.path) else {
                    fail("tkzmux-vtdump framedump: no reference \(referenceURL.path)", code: 2)
                }
                let reference = try FrameDump.decode(data)
                guard reference.scale == scale, reference.fixture == fixture else {
                    fail("tkzmux-vtdump framedump: \(referenceURL.path) is \(reference.fixture) at \(reference.scale)", code: 2)
                }
                let tableSource = try GlyphTableSource(reference)
                table = tableSource
                source = tableSource
                origin = reference.source
            } else {
                let built = try fontGlyphSource(scale: scale, fonts: arguments.value("fonts"))
                source = built.source
                origin = built.origin
            }

            let result = try FrameDumper.dump(recording: recording, fixture: fixture, source: source,
                                              pointSize: pointSize, scale: scale, origin: origin)
            try result.write(to: output)
            let counts = result.dump.buffers.map { "\($0.count) \($0.name)" }.joined(separator: ", ")
            FileHandle.standardError.write(Data("""
                \(FrameDump.stem(fixture: fixture, scale: scale)): \(result.dump.columns)×\(result.dump.rows) cells, \
                \(result.dump.glyphs.count) table entries, \(counts), \(result.instances.count) bytes \
                (\(replay == nil ? origin.glyphSource : "replay")) → \(output.path)\n
                """.utf8))
            for miss in table?.misses ?? [] {
                FileHandle.standardError.write(Data("  \(miss)\n".utf8))
                missed = true
            }
        }
        if missed { fail("tkzmux-vtdump framedump: the glyph table could not answer every request", code: 1) }
    }
}
