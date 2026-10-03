#!/usr/bin/env python3
# make-symbol-subset.py — builds Tkzmux Symbols, the Linux-only OFL symbol subset (WOR-312 S7).
#
# JetBrains Mono (terminal, chrome mono) and Inter (chrome UI on Linux) lack symbols that agents
# print and that the chrome draws (⏺ ⎿ ✢ ✳ ⎇ ↵ ⚙ ...). On the Mac, CoreText's fallback supplies
# them; on Linux they would fall through to whatever fontconfig finds, which differs per distro and
# makes ✳ a colour emoji on Omarchy. Tkzmux Symbols bundles exactly those glyphs, picked one by one
# from OFL sources to resemble the Mac, and TkzFontsFT tries it before fontconfig.
#
# Recipe: scripts/symbol-subset.json (sources pinned by URL and SHA-256, the glyph inventory and
# which source draws each glyph). Steps:
#   1. download each source into the cache and refuse a file whose SHA-256 differs from the recipe;
#   2. subset each source to its glyphs with HarfBuzz's hb-subset (libharfbuzz-subset through
#      ctypes, the library behind the `hb-subset` tool): hinting and layout tables dropped;
#   3. merge: composites are flattened to simple outlines, so every glyph stands alone; a glyph
#      with an `advance` override is re-centred in it (＋, a fullwidth plus, is Noto Sans Math's
#      '+' centred in one em); hmtx lsb is always the outline's xMin;
#   4. write one TrueType font (head, hhea, maxp, OS/2, hmtx, cmap, loca, glyf, name, post) named
#      Tkzmux Symbols, and OFL.txt carrying every source's copyright line. Renaming is what the OFL
#      asks of a modified version; none of the sources declares a Reserved Font Name, and the
#      script refuses a recipe whose new name contains one.
#
# Output depends only on the sources' outlines, not on the HarfBuzz version: glyphs are decoded
# and re-encoded here, and head's dates are fixed. Running it twice gives byte-identical files.
#
# Dev time only: the output is committed, and neither the build nor the tests run this script.
# Standard library plus libharfbuzz-subset (Arch: harfbuzz; Ubuntu: libharfbuzz-subset0).
#
#   scripts/make-symbol-subset.py [--check] [--cache DIR] [--recipe FILE] [--mac-advances FILE]
#
#   --check              build in memory, write nothing, and fail unless the result matches the
#                        committed files and the recipe's output.sha256
#   --cache DIR          where sources are downloaded (default: $XDG_CACHE_HOME/tkzmux/symbol-sources)
#   --recipe FILE        another recipe (default: scripts/symbol-subset.json)
#   --mac-advances FILE  TODO(WOR-312 S1/S2): the Mac's advances, {"<scalar hex>": <points>, ...,
#                        "pointSize": <points>}; each listed glyph gets advance = points/size em
#
# Exit status: 0 = written (or --check matched), 1 = a hash mismatch or --check difference,
#              2 = usage, recipe or tool error.

import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
import struct
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RECIPE = ROOT / "scripts" / "symbol-subset.json"
UNITS_PER_EM = 1000
# head.created/modified: fixed, so the output is byte-identical across runs (2026-01-01T00:00Z,
# seconds since 1904-01-01).
FIXED_DATE = 3850070400


def die(message, status=2):
    print(f"make-symbol-subset: {message}", file=sys.stderr)
    sys.exit(status)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# MARK: - Sources

def fetch(url, expected, cache, name):
    """The file at `url`, from the cache when its hash matches, else downloaded and verified."""
    path = cache / name
    if path.exists() and sha256(path.read_bytes()) == expected:
        return path.read_bytes()
    print(f"downloading {url}", file=sys.stderr)
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    actual = sha256(data)
    if actual != expected:
        die(f"{name}: SHA-256 {actual} differs from the recipe's {expected}", 1)
    cache.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_bytes(data)
    temporary.replace(path)
    return data


# MARK: - hb-subset

class HarfBuzzSubset:
    NO_HINTING = 0x1
    SETS_DROP_TABLE_TAG = 3
    # Layout and math tables carry no glyphs we draw; dropping them also stops hb-subset pulling
    # GSUB alternates into the closure.
    DROPPED = [b"GSUB", b"GPOS", b"GDEF", b"MATH", b"BASE", b"JSTF", b"kern", b"vhea", b"vmtx", b"DSIG"]

    def __init__(self):
        names = [ctypes.util.find_library("harfbuzz-subset"), "libharfbuzz-subset.so.0"]
        self.lib = None
        for name in names:
            if not name:
                continue
            try:
                self.lib = ctypes.CDLL(name)
                break
            except OSError:
                continue
        if self.lib is None:
            die("libharfbuzz-subset not found (Arch: harfbuzz; Ubuntu: libharfbuzz-subset0)")
        lib = self.lib
        vp = ctypes.c_void_p
        lib.hb_blob_create.restype = vp
        lib.hb_blob_create.argtypes = [ctypes.c_char_p, ctypes.c_uint, ctypes.c_int, vp, vp]
        lib.hb_face_create.restype = vp
        lib.hb_face_create.argtypes = [vp, ctypes.c_uint]
        lib.hb_subset_input_create_or_fail.restype = vp
        lib.hb_subset_input_unicode_set.restype = vp
        lib.hb_subset_input_unicode_set.argtypes = [vp]
        lib.hb_subset_input_set.restype = vp
        lib.hb_subset_input_set.argtypes = [vp, ctypes.c_int]
        lib.hb_subset_input_set_flags.argtypes = [vp, ctypes.c_uint]
        lib.hb_set_add.argtypes = [vp, ctypes.c_uint32]
        lib.hb_subset_or_fail.restype = vp
        lib.hb_subset_or_fail.argtypes = [vp, vp]
        lib.hb_face_reference_blob.restype = vp
        lib.hb_face_reference_blob.argtypes = [vp]
        lib.hb_blob_get_data.restype = ctypes.POINTER(ctypes.c_char)
        lib.hb_blob_get_data.argtypes = [vp, ctypes.POINTER(ctypes.c_uint)]
        for name in ["hb_blob_destroy", "hb_face_destroy", "hb_subset_input_destroy"]:
            getattr(lib, name).argtypes = [vp]
        lib.hb_version_string.restype = ctypes.c_char_p

    @property
    def version(self):
        return self.lib.hb_version_string().decode()

    def subset(self, data, unicodes):
        lib = self.lib
        buffer = ctypes.create_string_buffer(data, len(data))
        blob = lib.hb_blob_create(buffer, len(data), 1, None, None)  # HB_MEMORY_MODE_READONLY
        face = lib.hb_face_create(blob, 0)
        subset_input = lib.hb_subset_input_create_or_fail()
        if not subset_input:
            die("hb_subset_input_create_or_fail failed")
        unicode_set = lib.hb_subset_input_unicode_set(subset_input)
        for codepoint in unicodes:
            lib.hb_set_add(unicode_set, codepoint)
        drop = lib.hb_subset_input_set(subset_input, self.SETS_DROP_TABLE_TAG)
        for tag in self.DROPPED:
            lib.hb_set_add(drop, struct.unpack(">I", tag)[0])
        lib.hb_subset_input_set_flags(subset_input, self.NO_HINTING)
        result = lib.hb_subset_or_fail(face, subset_input)
        if not result:
            die("hb_subset_or_fail failed")
        out_blob = lib.hb_face_reference_blob(result)
        length = ctypes.c_uint(0)
        pointer = lib.hb_blob_get_data(out_blob, ctypes.byref(length))
        out = ctypes.string_at(pointer, length.value)
        lib.hb_blob_destroy(out_blob)
        lib.hb_face_destroy(result)
        lib.hb_subset_input_destroy(subset_input)
        lib.hb_face_destroy(face)
        lib.hb_blob_destroy(blob)
        del buffer
        return out


# MARK: - Reading sfnt

class Font:
    """The few tables of a TrueType (glyf) font the merge reads."""

    def __init__(self, data):
        self.data = data
        (version, count) = struct.unpack(">IH", data[:6])
        if version != 0x00010000:
            die("not a TrueType (glyf) font")
        self.tables = {}
        for i in range(count):
            tag, _, offset, length = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
            self.tables[tag.decode("latin-1")] = data[offset:offset + length]
        head = self.tables["head"]
        self.units_per_em = struct.unpack(">H", head[18:20])[0]
        if self.units_per_em != UNITS_PER_EM:
            die(f"unitsPerEm {self.units_per_em}, expected {UNITS_PER_EM}")
        self.long_loca = struct.unpack(">h", head[50:52])[0] == 1
        self.num_glyphs = struct.unpack(">H", self.tables["maxp"][4:6])[0]
        self.cmap = self._cmap()

    def table(self, tag):
        return self.tables[tag]

    def _cmap(self):
        cmap = self.tables["cmap"]
        count = struct.unpack(">H", cmap[2:4])[0]
        mapping = {}
        for i in range(count):
            platform, encoding, offset = struct.unpack(">HHI", cmap[4 + 8 * i:12 + 8 * i])
            if (platform, encoding) not in [(3, 1), (3, 10), (0, 3), (0, 4)]:
                continue
            fmt = struct.unpack(">H", cmap[offset:offset + 2])[0]
            if fmt == 4:
                segments = struct.unpack(">H", cmap[offset + 6:offset + 8])[0] // 2
                base = offset + 14
                ends = struct.unpack(f">{segments}H", cmap[base:base + 2 * segments])
                base += 2 * segments + 2
                starts = struct.unpack(f">{segments}H", cmap[base:base + 2 * segments])
                base += 2 * segments
                deltas = struct.unpack(f">{segments}h", cmap[base:base + 2 * segments])
                range_base = base + 2 * segments
                offsets = struct.unpack(f">{segments}H", cmap[range_base:range_base + 2 * segments])
                for s in range(segments):
                    for code in range(starts[s], ends[s] + 1):
                        if code == 0xFFFF:
                            continue
                        if offsets[s] == 0:
                            glyph = (code + deltas[s]) & 0xFFFF
                        else:
                            at = range_base + 2 * s + offsets[s] + 2 * (code - starts[s])
                            glyph = struct.unpack(">H", cmap[at:at + 2])[0]
                            if glyph:
                                glyph = (glyph + deltas[s]) & 0xFFFF
                        if glyph:
                            mapping.setdefault(code, glyph)
            elif fmt == 12:
                groups = struct.unpack(">I", cmap[offset + 12:offset + 16])[0]
                for g in range(groups):
                    start, end, glyph = struct.unpack(">III", cmap[offset + 16 + 12 * g:offset + 28 + 12 * g])
                    for code in range(start, end + 1):
                        mapping.setdefault(code, glyph + code - start)
        return mapping

    def glyph_data(self, glyph):
        loca = self.tables["loca"]
        if self.long_loca:
            start, end = struct.unpack(">II", loca[4 * glyph:4 * glyph + 8])
        else:
            start, end = (2 * v for v in struct.unpack(">HH", loca[2 * glyph:2 * glyph + 4]))
        return self.tables["glyf"][start:end]

    def advance(self, glyph):
        metrics = struct.unpack(">H", self.tables["hhea"][34:36])[0]
        index = min(glyph, metrics - 1)
        return struct.unpack(">H", self.tables["hmtx"][4 * index:4 * index + 2])[0]

    def contours(self, glyph, depth=0):
        """The glyph's outline as [[(x, y, on_curve), ...], ...], composites flattened."""
        data = self.glyph_data(glyph)
        if not data:
            return []
        count = struct.unpack(">h", data[:2])[0]
        if count >= 0:
            return decode_simple(data, count)
        if depth > 8:
            die("composite glyphs nest too deep")
        contours = []
        at = 10
        while True:
            flags, component = struct.unpack(">HH", data[at:at + 4])
            at += 4
            if flags & 0x0001:  # ARG_1_AND_2_ARE_WORDS
                dx, dy = struct.unpack(">hh", data[at:at + 4])
                at += 4
            else:
                dx, dy = struct.unpack(">bb", data[at:at + 2])
                at += 2
            if not flags & 0x0002:  # ARGS_ARE_XY_VALUES: point matching is not supported
                die("composite glyph uses point matching")
            a, b, c, d = 1.0, 0.0, 0.0, 1.0
            if flags & 0x0008:  # WE_HAVE_A_SCALE
                a = d = struct.unpack(">h", data[at:at + 2])[0] / 16384
                at += 2
            elif flags & 0x0040:  # WE_HAVE_AN_X_AND_Y_SCALE
                a, d = (v / 16384 for v in struct.unpack(">hh", data[at:at + 4]))
                at += 4
            elif flags & 0x0080:  # WE_HAVE_A_TWO_BY_TWO
                a, b, c, d = (v / 16384 for v in struct.unpack(">hhhh", data[at:at + 8]))
                at += 8
            for contour in self.contours(component, depth + 1):
                contours.append([(round(a * x + c * y + dx), round(b * x + d * y + dy), on)
                                 for x, y, on in contour])
            if not flags & 0x0020:  # MORE_COMPONENTS
                break
        return contours


def decode_simple(data, count):
    ends = struct.unpack(f">{count}H", data[10:10 + 2 * count])
    points = ends[-1] + 1 if count else 0
    at = 10 + 2 * count
    instructions = struct.unpack(">H", data[at:at + 2])[0]
    at += 2 + instructions
    flags = []
    while len(flags) < points:
        flag = data[at]
        at += 1
        flags.append(flag)
        if flag & 0x08:  # REPEAT
            repeat = data[at]
            at += 1
            flags.extend([flag] * repeat)
    flags = flags[:points]

    def coordinates(short_bit, same_bit):
        nonlocal at
        values, value = [], 0
        for flag in flags:
            if flag & short_bit:
                delta = data[at]
                at += 1
                value += delta if flag & same_bit else -delta
            elif not flag & same_bit:
                value += struct.unpack(">h", data[at:at + 2])[0]
                at += 2
            values.append(value)
        return values

    xs = coordinates(0x02, 0x10)
    ys = coordinates(0x04, 0x20)
    contours, start = [], 0
    for end in ends:
        contours.append([(xs[i], ys[i], bool(flags[i] & 0x01)) for i in range(start, end + 1)])
        start = end + 1
    return contours


# MARK: - Writing

def encode_simple(contours):
    """A simple glyph, no instructions; b"" for an empty outline."""
    points = [p for contour in contours for p in contour]
    if not points:
        return b""
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    out = struct.pack(">hhhhh", len(contours), min(xs), min(ys), max(xs), max(ys))
    end = -1
    for contour in contours:
        end += len(contour)
        out += struct.pack(">H", end)
    out += struct.pack(">H", 0)
    flags, x_bytes, y_bytes = [], b"", b""
    previous_x = previous_y = 0
    for x, y, on in points:
        flag = 0x01 if on else 0x00
        dx, dy = x - previous_x, y - previous_y
        previous_x, previous_y = x, y
        if dx == 0:
            flag |= 0x10
        elif -255 <= dx <= 255:
            flag |= 0x02 | (0x10 if dx > 0 else 0)
            x_bytes += bytes([abs(dx)])
        else:
            x_bytes += struct.pack(">h", dx)
        if dy == 0:
            flag |= 0x20
        elif -255 <= dy <= 255:
            flag |= 0x04 | (0x20 if dy > 0 else 0)
            y_bytes += bytes([abs(dy)])
        else:
            y_bytes += struct.pack(">h", dy)
        flags.append(flag)
    out += bytes(flags) + x_bytes + y_bytes
    return out + b"\0" * (-len(out) % 4)


def bounds(contours):
    points = [p for contour in contours for p in contour]
    if not points:
        return (0, 0, 0, 0)
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return (min(xs), min(ys), max(xs), max(ys))


def checksum(data):
    data = data + b"\0" * (-len(data) % 4)
    return sum(struct.unpack(f">{len(data) // 4}I", data)) & 0xFFFFFFFF


def cmap_table(mapping):
    """Format 4 (every scalar is in the BMP), one segment per scalar, shared by 0/3 and 3/1."""
    codes = sorted(mapping)
    ends = codes + [0xFFFF]
    starts = codes + [0xFFFF]
    deltas = [(mapping[c] - c) & 0xFFFF for c in codes] + [1]
    segments = len(ends)
    search = 2 * (1 << (segments.bit_length() - 1))
    selector = (segments.bit_length() - 1)
    body = struct.pack(">HHHH", 2 * segments, search, selector, 2 * segments - search)
    body += struct.pack(f">{segments}H", *ends) + b"\0\0"
    body += struct.pack(f">{segments}H", *starts)
    body += struct.pack(f">{segments}H", *deltas)
    body += struct.pack(f">{segments}H", *([0] * segments))
    subtable = struct.pack(">HHH", 4, 6 + len(body), 0) + body
    header = struct.pack(">HH", 0, 2)
    header += struct.pack(">HHI", 0, 3, 4 + 8 * 2)
    header += struct.pack(">HHI", 3, 1, 4 + 8 * 2)
    return header + subtable


def name_table(records):
    """Format 0, Windows Unicode English (3/1/0x409) records only."""
    strings = b""
    entries = []
    for name_id, text in sorted(records.items()):
        encoded = text.encode("utf-16-be")
        entries.append(struct.pack(">HHHHHH", 3, 1, 0x409, name_id, len(encoded), len(strings)))
        strings += encoded
    header = struct.pack(">HHH", 0, len(entries), 6 + 12 * len(entries))
    return header + b"".join(entries) + strings


def sfnt(tables):
    tags = sorted(tables)
    count = len(tags)
    power = 1 << (count.bit_length() - 1)
    header = struct.pack(">IHHHH", 0x00010000, count, power * 16, power.bit_length() - 1, count * 16 - power * 16)
    offset = 12 + 16 * count
    directory, body = b"", b""
    for tag in tags:
        data = tables[tag]
        directory += struct.pack(">4sIII", tag.encode("latin-1"), checksum(data), offset + len(body), len(data))
        body += data + b"\0" * (-len(data) % 4)
    return header + directory + body


def build(recipe, sources, mac_advances):
    subsetter = HarfBuzzSubset()
    glyph_specs = [g for g in recipe["glyphs"] if g["source"] != "primary"]
    for spec in recipe["glyphs"]:
        if spec["source"] not in sources and spec["source"] != "primary":
            die(f"U+{spec['scalar']}: unknown source '{spec['source']}'")

    # Subset each source to the scalars it draws (plus a construction's base glyph).
    fonts = {}
    for source in sorted({g["source"] for g in glyph_specs}):
        unicodes = set()
        for spec in glyph_specs:
            if spec["source"] == source:
                unicodes.add(int(spec.get("from", spec["scalar"]), 16))
        fonts[source] = Font(subsetter.subset(sources[source], sorted(unicodes)))

    # Glyph 0 is an empty .notdef: a missing glyph draws nothing, as on the Mac's fallback.
    outlines = [[]]
    advances = [UNITS_PER_EM // 2]
    mapping = {}
    for spec in sorted(glyph_specs, key=lambda g: int(g["scalar"], 16)):
        scalar = int(spec["scalar"], 16)
        font = fonts[spec["source"]]
        base = int(spec.get("from", spec["scalar"]), 16)
        glyph = font.cmap.get(base)
        if not glyph:
            die(f"U+{spec['scalar']}: {spec['source']} has no glyph for U+{base:04X}")
        contours = font.contours(glyph)
        advance = font.advance(glyph)
        target = spec.get("advance")
        if f"{scalar:04X}" in mac_advances:
            target = mac_advances[f"{scalar:04X}"]
        if target is not None and target != advance:
            # Keep the ink where it sat in proportion: centred in the new advance.
            shift = round((target - advance) / 2)
            contours = [[(x + shift, y, on) for x, y, on in contour] for contour in contours]
            advance = target
        mapping[scalar] = len(outlines)
        outlines.append(contours)
        advances.append(advance)

    glyphs = [encode_simple(c) for c in outlines]
    boxes = [bounds(c) for c in outlines]
    inked = [b for b, c in zip(boxes, outlines) if c]
    x_min = min(b[0] for b in inked)
    y_min = min(b[1] for b in inked)
    x_max = max(b[2] for b in inked)
    y_max = max(b[3] for b in inked)

    glyf = b"".join(glyphs)
    offsets = [0]
    for data in glyphs:
        offsets.append(offsets[-1] + len(data))
    loca = struct.pack(f">{len(offsets)}I", *offsets)
    hmtx = b"".join(struct.pack(">Hh", advance, box[0]) for advance, box in zip(advances, boxes))

    primary = fonts["symbols2"]
    head_source = primary.table("head")
    head = struct.pack(">IIIIHH", 0x00010000, int(float(recipe["version"]) * 65536), 0, 0x5F0F3CF5,
                       struct.unpack(">H", head_source[16:18])[0], UNITS_PER_EM)
    head += struct.pack(">qq", FIXED_DATE, FIXED_DATE)
    head += struct.pack(">hhhhHHhhh", x_min, y_min, x_max, y_max, 0, 8, 2, 1, 0)

    hhea_source = primary.table("hhea")
    ascender, descender, line_gap = struct.unpack(">hhh", hhea_source[4:10])
    right_bearings = [a - b[2] for a, b, c in zip(advances, boxes, outlines) if c]
    hhea = struct.pack(">IhhhH", 0x00010000, ascender, descender, line_gap, max(advances))
    hhea += struct.pack(">hhh", min(b[0] for b in inked), min(right_bearings), max(b[2] for b in inked))
    # Caret slope and offset, then the reserved words, from the source; metricDataFormat 0.
    hhea += hhea_source[18:32] + struct.pack(">hH", 0, len(glyphs))

    max_points = max((sum(len(c) for c in o) for o in outlines), default=0)
    max_contours = max((len(o) for o in outlines), default=0)
    maxp = struct.pack(">IHHHHHHHHHHHHHH", 0x00010000, len(glyphs), max_points, max_contours,
                       0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0)

    os2 = bytearray(primary.table("OS/2"))
    widths = [a for a, c in zip(advances, outlines) if c]
    struct.pack_into(">h", os2, 2, round(sum(widths) / len(widths)))  # xAvgCharWidth
    struct.pack_into(">H", os2, 8, 0)  # fsType: installable
    os2[58:62] = b"UKWN"  # achVendID: not Google's
    struct.pack_into(">HH", os2, 64, min(mapping), max(mapping))  # usFirst/LastCharIndex
    struct.pack_into(">HH", os2, 74, max(struct.unpack(">H", os2[74:76])[0], y_max),
                     max(struct.unpack(">H", os2[76:78])[0], -y_min))  # usWinAscent/Descent

    post_source = primary.table("post")
    post = struct.pack(">I", 0x00030000) + post_source[4:12] + struct.pack(">I", 0) + b"\0" * 16

    copyrights = []
    for source in sorted(fonts):
        line = recipe["sources"][source]["copyright"]
        if line not in copyrights:
            copyrights.append(line)
    family, postscript, version = recipe["family"], recipe["postScriptName"], recipe["version"]
    upstreams = "; ".join(recipe["sources"][s]["upstream"] for s in sorted(fonts))
    names = {
        0: " ".join(copyrights),
        1: family,
        2: "Regular",
        3: f"{version};UKWN;{postscript}",
        4: family,
        5: f"Version {version}",
        6: postscript,
        10: f"{family} is a modified subset of {upstreams}, made for tkzmux.",
        13: "This Font Software is licensed under the SIL Open Font License, Version 1.1. "
            "This license is available with a FAQ at: https://openfontlicense.org",
        14: "https://openfontlicense.org",
    }

    tables = {
        "head": head, "hhea": hhea, "maxp": maxp, "OS/2": bytes(os2), "hmtx": hmtx,
        "cmap": cmap_table(mapping), "loca": loca, "glyf": glyf, "name": name_table(names), "post": post,
    }
    font = bytearray(sfnt(tables))
    # checkSumAdjustment: the whole font's checksum subtracted from 0xB1B0AFBA, written into head.
    count = struct.unpack(">H", font[4:6])[0]
    for i in range(count):
        tag, _, offset, _ = struct.unpack(">4sIII", font[12 + 16 * i:28 + 16 * i])
        if tag == b"head":
            struct.pack_into(">I", font, offset + 8, (0xB1B0AFBA - checksum(bytes(font))) & 0xFFFFFFFF)
    return bytes(font), subsetter.version


def license_text(recipe, licenses, used):
    """Every source's copyright line, then the OFL text (identical in every source after line 1)."""
    lines, body = [], None
    for source in sorted(used):
        text = licenses[source].decode("utf-8")
        first, rest = text.split("\n", 1)
        if first not in lines:
            lines.append(first)
        if body is None:
            body = rest
        elif rest != body:
            die(f"{source}: its licence text differs from the other sources' beyond the copyright line")
    return "\n".join(lines) + "\n" + body


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--cache")
    parser.add_argument("--recipe", default=str(RECIPE))
    parser.add_argument("--mac-advances")
    args = parser.parse_args()

    recipe = json.loads(Path(args.recipe).read_text(encoding="utf-8"))
    family = recipe["family"].lower()
    for key, source in recipe["sources"].items():
        for reserved in source.get("reservedFontNames", []):
            if reserved.lower() in family:
                die(f"'{recipe['family']}' contains {key}'s Reserved Font Name '{reserved}'")

    cache_home = os.environ.get("XDG_CACHE_HOME", "")
    if not cache_home.startswith("/"):
        cache_home = str(Path.home() / ".cache")
    cache = Path(args.cache) if args.cache else Path(cache_home) / "tkzmux" / "symbol-sources"

    mac_advances = {}
    if args.mac_advances:
        reference = json.loads(Path(args.mac_advances).read_text(encoding="utf-8"))
        size = float(reference["pointSize"])
        mac_advances = {k.upper(): round(float(v) / size * UNITS_PER_EM)
                        for k, v in reference.items() if k != "pointSize"}

    used = {g["source"] for g in recipe["glyphs"] if g["source"] != "primary"}
    sources, licenses = {}, {}
    for key in sorted(used):
        source = recipe["sources"][key]
        sources[key] = fetch(source["url"], source["sha256"], cache, source["file"])
        licenses[key] = fetch(source["licenseUrl"], source["licenseSha256"], cache, f"{key}-OFL.txt")
        source["copyright"] = licenses[key].decode("utf-8").split("\n", 1)[0]

    font, harfbuzz = build(recipe, sources, mac_advances)
    text = license_text(recipe, licenses, used).encode("utf-8")
    font_path = ROOT / recipe["output"]["font"]
    license_path = ROOT / recipe["output"]["license"]
    digest = sha256(font)

    if args.check:
        problems = []
        if not font_path.exists() or font_path.read_bytes() != font:
            problems.append(f"{recipe['output']['font']} differs from a fresh build ({digest})")
        if not license_path.exists() or license_path.read_bytes() != text:
            problems.append(f"{recipe['output']['license']} differs from a fresh build")
        if recipe["output"]["sha256"] != digest:
            problems.append(f"the recipe's output.sha256 is {recipe['output']['sha256']}, a fresh build is {digest}")
        for problem in problems:
            print(f"make-symbol-subset: {problem}", file=sys.stderr)
        if problems:
            sys.exit(1)
        print(f"ok: {digest} (HarfBuzz {harfbuzz})")
        return

    font_path.parent.mkdir(parents=True, exist_ok=True)
    font_path.write_bytes(font)
    license_path.write_bytes(text)
    print(f"wrote {recipe['output']['font']} ({len(font)} bytes, {digest}) with HarfBuzz {harfbuzz}")
    if recipe["output"]["sha256"] != digest:
        print(f"update scripts/symbol-subset.json output.sha256 to {digest}", file=sys.stderr)


if __name__ == "__main__":
    main()
