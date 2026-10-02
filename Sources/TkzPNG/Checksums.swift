// The two checksums a PNG carries: CRC-32 over every chunk's type and data (ISO 3309 / ITU-T V.42,
// the reflected 0xEDB88320 polynomial) and Adler-32 over the inflated image data (RFC 1950 §8).
//
// Both are written for the byte counts a terminal frame produces (tens of megabytes at 8K): CRC-32
// uses slicing-by-8 tables, and Adler-32 defers the modulo for as many bytes as cannot overflow.

/// CRC-32 as PNG uses it. `update` continues a running value, so a chunk's type and data can be fed
/// separately without concatenating them.
public enum CRC32 {
    /// `tables[k][b]` is the CRC of byte `b` followed by `k` zero bytes — the slicing-by-8 tables.
    private static let tables: [[UInt32]] = {
        var tables = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 8)
        for byte in 0..<256 {
            var crc = UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
            tables[0][byte] = crc
        }
        for byte in 0..<256 {
            for k in 1..<8 {
                let previous = tables[k - 1][byte]
                tables[k][byte] = (previous >> 8) ^ tables[0][Int(previous & 0xFF)]
            }
        }
        return tables
    }()

    /// The CRC of `bytes`.
    public static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        update(0, bytes)
    }

    /// The CRC of `bytes`.
    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { checksum($0) }
    }

    /// `crc` (a finished CRC of earlier bytes, 0 for none) extended over `bytes`.
    public static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        let count = bytes.count
        var index = 0
        tables.withUnsafeBufferPointer { t in
            let t0 = t[0], t1 = t[1], t2 = t[2], t3 = t[3]
            let t4 = t[4], t5 = t[5], t6 = t[6], t7 = t[7]
            while count - index >= 8 {
                let lo = c ^ (UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
                    | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24)
                let hi = UInt32(bytes[index + 4]) | UInt32(bytes[index + 5]) << 8
                    | UInt32(bytes[index + 6]) << 16 | UInt32(bytes[index + 7]) << 24
                c = t7[Int(lo & 0xFF)] ^ t6[Int((lo >> 8) & 0xFF)]
                    ^ t5[Int((lo >> 16) & 0xFF)] ^ t4[Int(lo >> 24)]
                    ^ t3[Int(hi & 0xFF)] ^ t2[Int((hi >> 8) & 0xFF)]
                    ^ t1[Int((hi >> 16) & 0xFF)] ^ t0[Int(hi >> 24)]
                index += 8
            }
            while index < count {
                c = (c >> 8) ^ t0[Int((c ^ UInt32(bytes[index])) & 0xFF)]
                index += 1
            }
        }
        return ~c
    }

    /// `crc` extended over `bytes`.
    public static func update(_ crc: UInt32, _ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { update(crc, $0) }
    }
}

/// Adler-32 as zlib uses it (RFC 1950). The initial value is 1, not 0.
public enum Adler32 {
    private static let modulus: UInt32 = 65521
    /// The most bytes that can be summed before `b` can overflow a `UInt32` (zlib's NMAX).
    private static let maxRun = 5552

    /// The Adler-32 of `bytes`.
    public static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        update(1, bytes)
    }

    /// The Adler-32 of `bytes`.
    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { checksum($0) }
    }

    /// `adler` (a finished Adler-32 of earlier bytes, 1 for none) extended over `bytes`.
    public static func update(_ adler: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var a = adler & 0xFFFF
        var b = adler >> 16
        var index = 0
        let count = bytes.count
        while index < count {
            let end = min(count, index + maxRun)
            while index < end {
                a &+= UInt32(bytes[index])
                b &+= a
                index += 1
            }
            a %= modulus
            b %= modulus
        }
        return b << 16 | a
    }
}
