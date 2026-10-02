// The PNG container: chunk walk, IHDR validation, IDAT gathering, row unfiltering and expansion to
// RGBA. Inflate itself is in Inflate.swift.
//
// Chunk rules enforced (PNG spec §5.6): IHDR first; IDATs consecutive; PLTE (a suggested palette
// for truecolour) and tRNS before the first IDAT; IEND last. An unknown *critical* chunk (upper-case
// first letter) is an error, an unknown ancillary one is skipped. Every chunk's CRC is checked,
// ancillary ones included — a damaged `sRGB` is as much a sign of a damaged file as a damaged IDAT.

enum PNGDecoder {
    struct Header {
        var width: Int
        var height: Int
        var colorType: PNGColorType
    }

    static func decode(_ bytes: UnsafeRawBufferPointer, maxPixels: Int) throws -> PNGImage {
        guard bytes.count >= 8 else { throw bytes.elementsEqual(PNG.signature.prefix(bytes.count)) ? PNGError.truncated : PNGError.notPNG }
        guard bytes.prefix(8).elementsEqual(PNG.signature) else { throw PNGError.notPNG }

        var position = 8
        var header: Header?
        var transparent: [UInt16]?
        var compressed: [UInt8] = []
        var sawIDAT = false
        var idatEnded = false

        while true {
            guard bytes.count - position >= 8 else { throw PNGError.truncated }
            let length = Int(readUInt32(bytes, position))
            guard length <= 0x7FFF_FFFF else { throw PNGError.corruptData("chunk length over 2^31-1") }
            let typeStart = position + 4
            let dataStart = position + 8
            guard bytes.count - dataStart >= length, bytes.count - dataStart - length >= 4 else { throw PNGError.truncated }
            let type = readUInt32(bytes, typeStart)
            let data = UnsafeRawBufferPointer(rebasing: bytes[dataStart..<(dataStart + length)])
            let storedCRC = readUInt32(bytes, dataStart + length)
            let computedCRC = CRC32.checksum(UnsafeRawBufferPointer(rebasing: bytes[typeStart..<(dataStart + length)]))
            guard storedCRC == computedCRC else { throw PNGError.checksumMismatch("CRC-32 of chunk \(typeName(type))") }
            position = dataStart + length + 4

            guard header != nil || type == ChunkType.IHDR else { throw PNGError.corruptData("first chunk is not IHDR") }
            if sawIDAT, type != ChunkType.IDAT { idatEnded = true }

            switch type {
            case ChunkType.IHDR:
                guard header == nil else { throw PNGError.corruptData("second IHDR") }
                header = try parseHeader(data, maxPixels: maxPixels)
            case ChunkType.IDAT:
                guard !idatEnded else { throw PNGError.corruptData("IDAT chunks are not consecutive") }
                sawIDAT = true
                compressed.append(contentsOf: data)
            case ChunkType.IEND:
                guard let header else { throw PNGError.corruptData("IEND before IHDR") }
                guard sawIDAT else { throw PNGError.corruptData("no IDAT") }
                return try decodeImage(compressed, header: header, transparent: transparent)
            case ChunkType.PLTE:
                // Allowed (and ignorable) for truecolour; forbidden for greyscale.
                guard let header, header.colorType == .rgb || header.colorType == .rgba else {
                    throw PNGError.corruptData("PLTE in a greyscale image")
                }
                guard !sawIDAT else { throw PNGError.corruptData("PLTE after IDAT") }
            case ChunkType.tRNS:
                guard let header, !sawIDAT else { throw PNGError.corruptData("tRNS after IDAT") }
                transparent = try parseTransparency(data, colorType: header.colorType)
            default:
                // Bit 5 of the first type byte clear = critical.
                guard (type >> 24) & 0x20 != 0 else {
                    throw PNGError.unsupported("critical chunk \(typeName(type))")
                }
            }
        }
    }

    private enum ChunkType {
        static let IHDR: UInt32 = 0x4948_4452
        static let PLTE: UInt32 = 0x504C_5445
        static let IDAT: UInt32 = 0x4944_4154
        static let IEND: UInt32 = 0x4945_4E44
        static let tRNS: UInt32 = 0x7452_4E53
    }

    private static func parseHeader(_ data: UnsafeRawBufferPointer, maxPixels: Int) throws -> Header {
        guard data.count == 13 else { throw PNGError.corruptData("IHDR is \(data.count) bytes, not 13") }
        let width = Int(readUInt32(data, 0)), height = Int(readUInt32(data, 4))
        let bitDepth = data[8], rawColorType = data[9]
        let compression = data[10], filter = data[11], interlace = data[12]
        guard width > 0, height > 0, width <= 0x7FFF_FFFF, height <= 0x7FFF_FFFF else {
            throw PNGError.corruptData("image dimensions \(width)×\(height)")
        }
        guard compression == 0, filter == 0, interlace <= 1 else { throw PNGError.corruptData("IHDR method field") }
        guard [0, 2, 3, 4, 6].contains(rawColorType) else { throw PNGError.corruptData("colour type \(rawColorType)") }
        guard let colorType = PNGColorType(rawValue: rawColorType) else { throw PNGError.unsupported("palette images") }
        guard bitDepth == 8 else { throw PNGError.unsupported("bit depth \(bitDepth)") }
        guard interlace == 0 else { throw PNGError.unsupported("interlaced images") }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxPixels else { throw PNGError.tooLarge(width: width, height: height) }
        // Every size derived from the header must fit an `Int` whatever `maxPixels` the caller
        // allowed: the RGBA output, and the filtered stream (a filter byte per row on top of the
        // samples). `rowBytes` itself is at most (2^31 - 1) · 4.
        let rowBytes = width * colorType.channels
        let (_, rgbaOverflow) = pixels.multipliedReportingOverflow(by: 4)
        let (_, filteredOverflow) = height.multipliedReportingOverflow(by: rowBytes + 1)
        guard !rgbaOverflow, !filteredOverflow else { throw PNGError.tooLarge(width: width, height: height) }
        return Header(width: width, height: height, colorType: colorType)
    }

    /// The tRNS key colour, one 16-bit sample per channel (only its low byte matters at depth 8).
    private static func parseTransparency(_ data: UnsafeRawBufferPointer, colorType: PNGColorType) throws -> [UInt16] {
        switch colorType {
        case .gray:
            guard data.count == 2 else { throw PNGError.corruptData("tRNS length") }
            return [readUInt16(data, 0)]
        case .rgb:
            guard data.count == 6 else { throw PNGError.corruptData("tRNS length") }
            return [readUInt16(data, 0), readUInt16(data, 2), readUInt16(data, 4)]
        case .grayAlpha, .rgba:
            throw PNGError.corruptData("tRNS in an image with an alpha channel")
        }
    }

    private static func decodeImage(
        _ compressed: [UInt8], header: Header, transparent: [UInt16]?
    ) throws -> PNGImage {
        let channels = header.colorType.channels
        let rowBytes = header.width * channels
        let filteredSize = header.height * (rowBytes + 1)  // parseHeader checked it fits an Int
        // Deflate cannot expand by more than 1032:1 (a 258-byte match in 2 bits). A header that
        // claims more than its data could possibly hold is rejected before anything is allocated.
        guard filteredSize / 1032 <= compressed.count else { throw PNGError.truncated }

        var filtered = try compressed.withUnsafeBytes { raw in
            try Inflate.zlibDecompress(raw, outputSize: filteredSize)
        }
        try filtered.withUnsafeMutableBufferPointer { buffer in
            try unfilter(buffer, rowBytes: rowBytes, height: header.height, bytesPerPixel: channels)
        }
        let pixels = filtered.withUnsafeBufferPointer { buffer in
            expand(buffer, header: header, transparent: transparent)
        }
        return PNGImage(width: header.width, height: header.height, pixels: pixels)
    }

    /// Reverses the per-row filters in place. Row `y` occupies `[y·(rowBytes+1)]` (filter byte)
    /// followed by `rowBytes` bytes; each row is unfiltered against the already-unfiltered row above.
    private static func unfilter(
        _ data: UnsafeMutableBufferPointer<UInt8>, rowBytes: Int, height: Int, bytesPerPixel bpp: Int
    ) throws {
        let stride = rowBytes + 1
        for y in 0..<height {
            let row = y * stride + 1
            let filter = data[row - 1]
            let up = row - stride  // only read when y > 0
            switch filter {
            case 0:
                break
            case 1:  // Sub
                for i in bpp..<max(bpp, rowBytes) { data[row + i] &+= data[row + i - bpp] }
            case 2:  // Up
                guard y > 0 else { break }
                for i in 0..<rowBytes { data[row + i] &+= data[up + i] }
            case 3:  // Average
                if y == 0 {
                    for i in bpp..<max(bpp, rowBytes) { data[row + i] &+= data[row + i - bpp] >> 1 }
                } else {
                    for i in 0..<min(bpp, rowBytes) { data[row + i] &+= data[up + i] >> 1 }
                    for i in bpp..<max(bpp, rowBytes) {
                        data[row + i] &+= UInt8((UInt16(data[row + i - bpp]) + UInt16(data[up + i])) >> 1)
                    }
                }
            case 4:  // Paeth
                if y == 0 {
                    // Above and upper-left are zero, so Paeth picks the left neighbour: Sub.
                    for i in bpp..<max(bpp, rowBytes) { data[row + i] &+= data[row + i - bpp] }
                } else {
                    for i in 0..<min(bpp, rowBytes) { data[row + i] &+= data[up + i] }
                    for i in bpp..<max(bpp, rowBytes) {
                        data[row + i] &+= paeth(data[row + i - bpp], data[up + i], data[up + i - bpp])
                    }
                }
            default:
                throw PNGError.corruptData("row filter \(filter)")
            }
        }
    }

    @inline(__always)
    static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
        if pa <= pb, pa <= pc { return a }
        return pb <= pc ? b : c
    }

    /// Unfiltered rows → tightly packed straight RGBA.
    private static func expand(
        _ data: UnsafeBufferPointer<UInt8>, header: Header, transparent: [UInt16]?
    ) -> [UInt8] {
        let width = header.width, height = header.height
        let stride = width * header.colorType.channels + 1
        var out = [UInt8](repeating: 255, count: width * height * 4)
        out.withUnsafeMutableBufferPointer { out in
            var o = 0
            for y in 0..<height {
                var s = y * stride + 1
                switch header.colorType {
                case .rgba:
                    (out.baseAddress! + o).update(from: data.baseAddress! + s, count: width * 4)
                    o += width * 4
                case .rgb:
                    for _ in 0..<width {
                        out[o] = data[s]; out[o + 1] = data[s + 1]; out[o + 2] = data[s + 2]
                        o += 4; s += 3
                    }
                case .grayAlpha:
                    for _ in 0..<width {
                        out[o] = data[s]; out[o + 1] = data[s]; out[o + 2] = data[s]; out[o + 3] = data[s + 1]
                        o += 4; s += 2
                    }
                case .gray:
                    for _ in 0..<width {
                        out[o] = data[s]; out[o + 1] = data[s]; out[o + 2] = data[s]
                        o += 4; s += 1
                    }
                }
            }
            // tRNS: pixels equal to the key colour become fully transparent. Samples are 16-bit in
            // the chunk; at depth 8 a key above 255 matches nothing.
            guard let key = transparent else { return }
            let r = key[0], g = key.count == 3 ? key[1] : key[0], b = key.count == 3 ? key[2] : key[0]
            guard r <= 255, g <= 255, b <= 255 else { return }
            var p = 0
            while p < out.count {
                if UInt16(out[p]) == r, UInt16(out[p + 1]) == g, UInt16(out[p + 2]) == b { out[p + 3] = 0 }
                p += 4
            }
        }
        return out
    }

    @inline(__always)
    static func readUInt32(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    @inline(__always)
    static func readUInt16(_ bytes: UnsafeRawBufferPointer, _ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    /// A chunk type as text for error messages, with anything non-printable escaped.
    private static func typeName(_ type: UInt32) -> String {
        var name = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8(truncatingIfNeeded: type >> UInt32(shift))
            name += (0x20..<0x7F).contains(byte) ? String(UnicodeScalar(byte)) : "\\x\(String(byte, radix: 16))"
        }
        return name
    }
}
