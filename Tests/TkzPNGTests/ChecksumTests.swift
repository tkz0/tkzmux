import Testing
@testable import TkzPNG

@Suite("CRC-32 and Adler-32")
struct ChecksumTests {
    private let check = Array("123456789".utf8)

    @Test("CRC-32 matches the published check value and the PNG IEND CRC")
    func crcKnownValues() {
        #expect(CRC32.checksum([]) == 0)
        #expect(CRC32.checksum(check) == 0xCBF4_3926)
        #expect(CRC32.checksum(Array("IEND".utf8)) == 0xAE42_6082)
    }

    @Test("CRC-32 slicing agrees with the bytewise definition at every length and split")
    func crcSlicing() {
        var generator = SeededGenerator(seed: 7)
        let bytes = (0..<300).map { _ in UInt8.random(in: 0...255, using: &generator) }
        func bitwise(_ bytes: ArraySlice<UInt8>) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            return ~crc
        }
        for length in 0...bytes.count {
            #expect(CRC32.checksum(Array(bytes[..<length])) == bitwise(bytes[..<length]))
        }
        let whole = CRC32.checksum(bytes)
        for split in [0, 1, 7, 8, 9, 150, 299, 300] {
            #expect(CRC32.update(CRC32.checksum(Array(bytes[..<split])), Array(bytes[split...])) == whole)
        }
    }

    @Test("Adler-32 matches known values, including past the deferred-modulo run")
    func adler() {
        #expect(Adler32.checksum([]) == 1)
        #expect(Adler32.checksum(Array("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(Adler32.checksum(check) == 0x091E_01DE)

        // 100 000 × 0xFF crosses many 5552-byte runs; compare with the textbook per-byte modulo.
        let ones = [UInt8](repeating: 0xFF, count: 100_000)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in ones {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        #expect(Adler32.checksum(ones) == b << 16 | a)
    }
}
