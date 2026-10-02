// PNG writing: per-row filter choice, then Deflate.swift, then the chunk stream
// (IHDR, IDAT×n, IEND). No ancillary chunks are written — in particular no `sRGB`/`iCCP`, so a
// reader applies no colour management and the bytes round-trip exactly.

enum PNGEncoder {
    /// Largest IDAT payload written; the zlib stream is split across as many IDATs as it needs.
    static let maxIDATLength = 1 << 16

    static func encode(
        _ pixels: [UInt8], width: Int, height: Int, colorType: PNGColorType
    ) throws -> [UInt8] {
        guard width > 0, height > 0, width <= 0x7FFF_FFFF, height <= 0x7FFF_FFFF else {
            throw PNGError.invalidArgument("dimensions \(width)×\(height)")
        }
        let channels = colorType.channels
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: channels)
        let (expected, overflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !overflow, pixels.count == expected else {
            throw PNGError.invalidArgument("\(pixels.count) bytes for \(width)×\(height)×\(channels)")
        }

        let filtered = pixels.withUnsafeBufferPointer {
            filterRows($0, rowBytes: rowBytes, height: height, bytesPerPixel: channels)
        }
        let compressed = filtered.withUnsafeBytes { Deflate.zlibCompress($0) }

        var out = PNG.signature
        out.reserveCapacity(compressed.count + compressed.count / maxIDATLength * 12 + 64)
        var header = [UInt8]()
        appendUInt32(&header, UInt32(width))
        appendUInt32(&header, UInt32(height))
        header += [8, colorType.rawValue, 0, 0, 0]  // depth, colour type, deflate, adaptive, no interlace
        appendChunk(&out, type: [0x49, 0x48, 0x44, 0x52], data: header[...])
        var start = 0
        repeat {
            let end = min(compressed.count, start + maxIDATLength)
            appendChunk(&out, type: [0x49, 0x44, 0x41, 0x54], data: compressed[start..<end])
            start = end
        } while start < compressed.count
        appendChunk(&out, type: [0x49, 0x45, 0x4E, 0x44], data: [][...])
        return out
    }

    /// Filters every row with whichever of the five filters gives the smallest sum of absolute
    /// values (bytes read as signed) — the libpng heuristic: it favours rows of small residuals,
    /// which LZ77 and Huffman coding both reward.
    static func filterRows(
        _ pixels: UnsafeBufferPointer<UInt8>, rowBytes: Int, height: Int, bytesPerPixel bpp: Int
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: height * (rowBytes + 1))
        var candidates = [UInt8](repeating: 0, count: 5 * rowBytes)
        out.withUnsafeMutableBufferPointer { out in
            candidates.withUnsafeMutableBufferPointer { candidates in
                for y in 0..<height {
                    let row = y * rowBytes
                    let up = row - rowBytes  // only read when y > 0
                    var bestFilter = 0
                    var bestScore = Int.max
                    for filter in 0..<5 {
                        let base = filter * rowBytes
                        var score = 0
                        for i in 0..<rowBytes {
                            let x = pixels[row + i]
                            let a = i >= bpp ? pixels[row + i - bpp] : 0
                            let b = y > 0 ? pixels[up + i] : 0
                            let predicted: UInt8 = switch filter {
                            case 0: 0
                            case 1: a
                            case 2: b
                            case 3: UInt8((UInt16(a) + UInt16(b)) >> 1)
                            default: PNGDecoder.paeth(a, b, i >= bpp && y > 0 ? pixels[up + i - bpp] : 0)
                            }
                            let residual = x &- predicted
                            candidates[base + i] = residual
                            score += Int(Int8(bitPattern: residual).magnitude)
                        }
                        if score < bestScore {
                            bestScore = score
                            bestFilter = filter
                        }
                    }
                    let target = y * (rowBytes + 1)
                    out[target] = UInt8(bestFilter)
                    (out.baseAddress! + target + 1)
                        .update(from: candidates.baseAddress! + bestFilter * rowBytes, count: rowBytes)
                }
            }
        }
        return out
    }

    private static func appendUInt32(_ out: inout [UInt8], _ value: UInt32) {
        out += [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func appendChunk(_ out: inout [UInt8], type: [UInt8], data: ArraySlice<UInt8>) {
        appendUInt32(&out, UInt32(data.count))
        out += type
        out += data
        let crc = data.withUnsafeBytes { CRC32.update(CRC32.checksum(type), $0) }
        appendUInt32(&out, crc)
    }
}
