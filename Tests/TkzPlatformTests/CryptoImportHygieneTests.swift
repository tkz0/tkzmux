// Guards the hashing migration (WOR-304 S4): Linux has no CryptoKit, and `SHA256` comes from
// TkzPlatform on both OSes, so `import CryptoKit` may appear only under
// Sources/TkzPlatform/Darwin/ (today, nowhere). Reuses the source scan of LoggingImportHygieneTests.

import Foundation
import Testing

@Suite struct CryptoImportHygieneTests {
    static let cryptoImport = #"^\s*(@_exported\s+)?import\s+(CryptoKit|CommonCrypto)\b"#

    @Test func cryptoKitIsImportedOnlyByTheDarwinFacade() throws {
        let offences = try LoggingImportHygieneTests.offences(matching: Self.cryptoImport)
        #expect(offences.isEmpty, "use TkzPlatform's SHA256, which also exists on Linux: \(offences)")
    }

    @Test func thePatternWouldCatchAnOffender() throws {
        let regex = try NSRegularExpression(pattern: Self.cryptoImport)
        func matches(_ line: String) -> Bool {
            regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        for line in ["import CryptoKit", "  import CryptoKit", "@_exported import CryptoKit", "import CommonCrypto"] {
            #expect(matches(line), "\(line)")
        }
        for line in ["import CryptoKitty", "import TkzPlatform", "import Foundation"] {
            #expect(!matches(line), "\(line)")
        }
    }
}
