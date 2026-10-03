// ParityLock — Tests/Parity/Fonts/fonts.lock.json as the tests read it (WOR-312 S4). The fetch
// script reads the same file with sed, one font per line.

import Foundation

/// The pinned parity fonts: file name, SHA-256, size and source of each.
struct ParityLock: Decodable {
    struct Font: Decodable {
        let file: String
        let sha256: String
        let size: Int
        let postScriptName: String
        let upstream: String
        let license: String
        let url: String
    }
    let fonts: [Font]

    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Parity/Fonts/fonts.lock.json")

    static func load() throws -> ParityLock {
        try JSONDecoder().decode(ParityLock.self, from: Data(contentsOf: url))
    }
}
