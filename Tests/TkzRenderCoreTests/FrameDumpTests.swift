// FrameDumpTests — the L2 parity dump and its replay (WOR-322 S3), over the synthetic
// `BlockGlyphSource`, so they run on both OSes. The real fixtures and references are exercised by
// the Linux runner (Tests/TkzParityRunnerTests).

import Foundation
import Testing
import TkzShaderTypes
import TkzTerminalCore
@testable import TkzRenderCore

@Suite("FrameDump")
struct FrameDumpTests {
    static let origin = FrameDump.Source(platform: "test", glyphSource: "Block")

    /// A recording of `text` on a 20×4 grid.
    static func recording(_ text: String) throws -> RecordingReader {
        let writer = RecordingWriter(header: RecordingHeader(cols: 20, rows: 4, startedAt: 0))
        var data = try writer.headerLine()
        data.append(writer.encode(.output(elapsedNanos: 0, bytes: Data(text.utf8))))
        return try RecordingReader(data: data)
    }

    static let text = "ab \u{1b}[1mb\u{1b}[0m ┌─┐ 😀 e\u{301}\r\n\u{1b}[4mline\u{1b}[0m \u{1b}[9mx\u{1b}[0m\r\n"

    static func referenceDump() throws -> FrameDumper.Output {
        let source = BlockGlyphSource(metrics: SurfaceFixture.metrics, drawsSprites: true, colorScalars: ["😀"])
        return try FrameDumper.dump(recording: recording(text), fixture: "sample", source: source,
                                    pointSize: 12.5, scale: 2, origin: origin)
    }

    @Test("the glyph table lists every request in order, with its slot")
    func tableAndBuffers() throws {
        let output = try Self.referenceDump()
        let dump = output.dump
        #expect(dump.columns == 20 && dump.rows == 4 && dump.padding == 1)
        #expect(dump.metrics == AtlasDump.Metrics(SurfaceFixture.metrics))
        #expect(dump.instances == "sample@2.0.bin")
        #expect(dump.buffers.map(\.name) == FrameDump.bufferNames)
        #expect(output.instances.count == dump.buffers.reduce(0) { $0 + $1.stride * $1.count })
        #expect(dump.buffers[0].count == 80)

        let kinds = Set(dump.glyphs.map(\.kind))
        #expect(kinds.isSuperset(of: [.glyph, .sprite]))
        let sprites = dump.glyphs.filter { $0.kind == .sprite }
        #expect(sprites.map(\.scalars) == "┌─┐".unicodeScalars.map { [$0.value] })
        #expect(sprites.allSatisfy { $0.face == nil && $0.style == "regular" && $0.cellSpan == 1 })
        let emoji = try #require(dump.glyphs.first { $0.scalars == [0x1F600] })
        #expect(emoji.page == "color" && emoji.cellSpan == 2)
        #expect(dump.glyphs.contains { $0.scalars == [0x65, 0x301] }, "the combining sequence is one cluster")
        #expect(dump.glyphs.contains { $0.scalars == [0x62] && $0.style == "bold" })
        // Packed entries carry their slot; the first grayscale glyph sits at the atlas origin.
        #expect(dump.glyphs.filter { $0.kind == .glyph || $0.kind == .sprite }.allSatisfy { $0.x != nil && $0.y != nil })
        let first = try #require(dump.glyphs.first { $0.page == "grayscale" })
        #expect(first.x == 0 && first.y == 0)
    }

    @Test("replaying the table writes the same buffers and the same dump, opening no font")
    func replayIsByteIdentical() throws {
        let reference = try Self.referenceDump()
        let table = try GlyphTableSource(reference.dump)
        let replay = try FrameDumper.dump(recording: Self.recording(Self.text), fixture: "sample", source: table,
                                          pointSize: 12.5, scale: 2, origin: reference.dump.source)
        #expect(table.misses.isEmpty, "\(table.misses)")
        #expect(replay.instances == reference.instances)
        #expect(replay.dump == reference.dump)
        #expect(try replay.dump.encoded() == reference.dump.encoded())
        #expect(try FrameDump.decode(reference.dump.encoded()) == reference.dump)
    }

    @Test("a request the table cannot answer is a miss, and the buffers differ")
    func missingEntryIsReported() throws {
        let reference = try Self.referenceDump()
        var trimmed = reference.dump
        trimmed.glyphs.removeAll { $0.scalars == [0x61] }
        let table = try GlyphTableSource(trimmed)
        let replay = try FrameDumper.dump(recording: Self.recording(Self.text), fixture: "sample", source: table,
                                          pointSize: 12.5, scale: 2, origin: trimmed.source)
        #expect(table.misses == ["no table entry for U+0061 regular span 1"])
        #expect(replay.instances != reference.instances)
    }

    @Test("a byte offset names its buffer, instance and field")
    func locate() throws {
        let dump = try Self.referenceDump().dump
        let glyphs = dump.buffers[0].count * 4
        #expect(dump.locate(offset: 5)?.description == "background[1].color (bytes 4..<8)")
        #expect(dump.locate(offset: glyphs + 32 + 13)?.description
                == "glyphs[1].atlasPos.x (bytes \(glyphs + 44)..<\(glyphs + 46))")
        let rects = glyphs + dump.buffers[1].count * 32
        #expect(dump.locate(offset: rects + 20)?.description == "rectsBelow[0].style (bytes \(rects + 20)..<\(rects + 24))")
        #expect(dump.locate(offset: dump.buffers.reduce(0) { $0 + $1.stride * $1.count }) == nil)
    }

    @Test("dumped metrics come back as the same CellMetrics")
    func metricsRoundTrip() {
        let metrics = SurfaceFixture.metrics
        #expect(AtlasDump.Metrics(metrics).cellMetrics(scale: 2) == metrics)
    }

    @Test("instances are written field by field, little-endian")
    func encoding() {
        var glyph = TkzGlyphInstance()
        glyph.gridPos = SIMD2(0x0102, 3)
        glyph.offsetPx = SIMD2(-1, 2)
        glyph.color = 0xAABB_CCDD
        var rect = TkzRectInstance()
        rect.originPx = SIMD2(1, 0)
        let bytes = FrameDump.encode(background: [TkzBgCell(color: 0x0403_0201)], glyphs: [glyph], below: [], above: [rect])
        #expect(bytes.count == 4 + 32 + 32)
        #expect(Array(bytes[0..<4]) == [1, 2, 3, 4])
        #expect(Array(bytes[4..<10]) == [0x02, 0x01, 3, 0, 0xFF, 0xFF])
        #expect(Array(bytes[20..<24]) == [0xDD, 0xCC, 0xBB, 0xAA])
        #expect(Array(bytes[36..<40]) == [0x00, 0x00, 0x80, 0x3F], "1.0 as an IEEE 754 single")
    }
}
