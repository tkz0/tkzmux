#!/usr/bin/env python3
# make-colrv1-fixture.py — writes Tests/TkzFontsFTTests/Fixtures/colrv1-only.ttf (WOR-312 S5).
#
# A tiny, original TrueType font that covers U+1F600 only through COLR version 1: the base glyph
# has no outline, no COLRv0 layers and no bitmap strike, and its one paint is a PaintGlyph of a
# square filled with a PaintSolid. FreeType can report that paint but not draw it, which is the
# case TkzFontsFT's colour fallback must detect and skip (ClusterShaper). fontconfig marks the font
# colour (COLR + CPAL), so it competes for the colour fallback list like a real COLRv1 emoji font.
#
# Dev time only: the output is committed and the tests never run this. Standard library only, so it
# needs no font tooling; every byte is written here and the output is byte-identical across runs.
#
#   scripts/make-colrv1-fixture.py [output.ttf]

import struct
import sys
from pathlib import Path

FAMILY = "Tkzmux COLRv1 Fixture"
POSTSCRIPT = "TkzmuxCOLRv1Fixture-Regular"
UNITS_PER_EM = 1000
SMILE = 0x1F600

# Glyphs: 0 .notdef (empty), 1 the U+1F600 base glyph (empty: colour only), 2 the painted square.
SQUARE = [(100, 0), (100, 800), (900, 800), (900, 0)]  # clockwise: a TrueType outer contour
ADVANCES = [500, 1000, 1000]


def glyph_square():
    xs = [x for x, _ in SQUARE]
    ys = [y for _, y in SQUARE]
    data = struct.pack(">hhhhh", 1, min(xs), min(ys), max(xs), max(ys))
    data += struct.pack(">H", len(SQUARE) - 1)  # endPtsOfContours
    data += struct.pack(">H", 0)  # instructionLength
    data += bytes([0x01] * len(SQUARE))  # on-curve, both coordinates as int16 deltas
    previous = 0
    for x in xs:
        data += struct.pack(">h", x - previous)
        previous = x
    previous = 0
    for y in ys:
        data += struct.pack(">h", y - previous)
        previous = y
    return data + b"\0" * (-len(data) % 4)


def tables():
    glyphs = [b"", b"", glyph_square()]
    glyf = b"".join(glyphs)
    offsets = [0]
    for glyph in glyphs:
        offsets.append(offsets[-1] + len(glyph))
    loca = b"".join(struct.pack(">H", offset // 2) for offset in offsets)  # short format

    head = struct.pack(
        ">IIIIHHqqhhhhHHhhh",
        0x00010000, 0x00010000, 0, 0x5F0F3CF5,  # version, revision, checkSumAdjustment, magic
        0x000B, UNITS_PER_EM,  # flags: baseline at y=0, lsb at x=0, integer ppem
        0, 0,  # created, modified: fixed, for byte-identical output
        100, 0, 900, 800,  # font bbox
        0, 8, 2,  # macStyle, lowestRecPPEM, fontDirectionHint
        0, 0)  # indexToLocFormat (short), glyphDataFormat

    hhea = struct.pack(
        ">IhhhHhhhhhhhhhhhH",
        0x00010000, 800, -200, 0, max(ADVANCES),
        0, 100, 900,  # minLeftSideBearing, minRightSideBearing, xMaxExtent
        1, 0, 0,  # caret slope rise/run, offset
        0, 0, 0, 0, 0,  # reserved, metricDataFormat
        len(ADVANCES))

    maxp = struct.pack(">IHHHHHHHHHHHHHH", 0x00010000, len(glyphs), len(SQUARE), 1,
                       0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0)

    os2 = struct.pack(">HhHHH", 4, 833, 400, 5, 0)  # version, xAvgCharWidth, weight, width, fsType
    os2 += struct.pack(">hhhhhhhh", 650, 600, 0, 75, 650, 600, 0, 350)  # sub/superscript
    os2 += struct.pack(">hhh", 50, 300, 0)  # strikeout size/position, sFamilyClass
    os2 += bytes(10)  # panose
    os2 += struct.pack(">IIII", 0, 1 << 25, 0, 0)  # ulUnicodeRange: bit 57 (non-plane 0)
    os2 += b"NONE"  # achVendID
    os2 += struct.pack(">HHH", 0x40, 0xFFFF, 0xFFFF)  # fsSelection REGULAR, first/last char
    os2 += struct.pack(">hhhHH", 800, -200, 0, 800, 200)  # typo and win metrics
    os2 += struct.pack(">II", 1, 0)  # code page ranges: Latin 1
    os2 += struct.pack(">hhHHH", 500, 700, 0, 0x20, 1)  # x-height, cap height, default/break, context

    hmtx = b"".join(struct.pack(">Hh", advance, 0 if i < 2 else 100) for i, advance in enumerate(ADVANCES))

    # cmap: an empty format 4 subtable (the mandatory 0xFFFF segment) and a format 12 with U+1F600.
    format4 = struct.pack(">HHHHHHH", 4, 24, 0, 2, 2, 0, 0)
    format4 += struct.pack(">HHHhH", 0xFFFF, 0, 0xFFFF, 1, 0)
    format12 = struct.pack(">HHIII", 12, 0, 28, 0, 1) + struct.pack(">III", SMILE, SMILE, 1)
    cmap = struct.pack(">HH", 0, 2)
    cmap += struct.pack(">HHI", 3, 1, 4 + 2 * 8)
    cmap += struct.pack(">HHI", 3, 10, 4 + 2 * 8 + len(format4))
    cmap += format4 + format12

    names = [(1, FAMILY), (2, "Regular"), (3, POSTSCRIPT), (4, FAMILY + " Regular"), (6, POSTSCRIPT)]
    strings = b""
    records = b""
    for name_id, text in names:
        encoded = text.encode("utf-16-be")
        records += struct.pack(">HHHHHH", 3, 1, 0x409, name_id, len(encoded), len(strings))
        strings += encoded
    name = struct.pack(">HHH", 0, len(names), 6 + 12 * len(names)) + records + strings

    post = struct.pack(">IIhhIIIII", 0x00030000, 0, -100, 50, 0, 0, 0, 0, 0)

    # COLR version 1: no v0 records, one BaseGlyphPaintRecord for glyph 1.
    paint_solid = struct.pack(">BHh", 2, 0, 0x4000)  # PaintSolid: palette entry 0, alpha 1.0
    paint_glyph = struct.pack(">B", 10) + (6).to_bytes(3, "big") + struct.pack(">H", 2)  # PaintGlyph
    base_glyph_list = struct.pack(">I", 1) + struct.pack(">HI", 1, 4 + 6) + paint_glyph + paint_solid
    colr_header_size = 34
    colr = struct.pack(">HHIIH", 1, 0, 0, 0, 0)
    colr += struct.pack(">IIIII", colr_header_size, 0, 0, 0, 0)  # BaseGlyphList, then none
    colr += base_glyph_list

    cpal = struct.pack(">HHHHIH", 0, 1, 1, 1, 14, 0) + bytes([0x00, 0xCC, 0xFF, 0xFF])  # BGRA

    return {
        b"COLR": colr, b"CPAL": cpal, b"OS/2": os2, b"cmap": cmap, b"glyf": glyf,
        b"head": head, b"hhea": hhea, b"hmtx": hmtx, b"loca": loca, b"maxp": maxp,
        b"name": name, b"post": post,
    }


def checksum(data):
    padded = data + b"\0" * (-len(data) % 4)
    return sum(struct.unpack(">%dI" % (len(padded) // 4), padded)) & 0xFFFFFFFF


def font():
    entries = sorted(tables().items())
    count = len(entries)
    power = 1
    while power * 2 <= count:
        power *= 2
    search_range = power * 16
    entry_selector = power.bit_length() - 1
    header = struct.pack(">IHHHH", 0x00010000, count, search_range, entry_selector,
                         count * 16 - search_range)
    offset = len(header) + 16 * count
    directory = b""
    body = b""
    head_offset = 0
    for tag, data in entries:
        if tag == b"head":
            head_offset = offset
        directory += tag + struct.pack(">III", checksum(data), offset, len(data))
        padded = data + b"\0" * (-len(data) % 4)
        body += padded
        offset += len(padded)
    out = bytearray(header + directory + body)
    adjustment = (0xB1B0AFBA - checksum(bytes(out))) & 0xFFFFFFFF
    out[head_offset + 8:head_offset + 12] = struct.pack(">I", adjustment)
    return bytes(out)


def main():
    default = Path(__file__).resolve().parent.parent / "Tests/TkzFontsFTTests/Fixtures/colrv1-only.ttf"
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else default
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(font())
    print(f"wrote {output} ({output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
