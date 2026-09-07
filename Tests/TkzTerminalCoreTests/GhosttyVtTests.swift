import Foundation
import Testing
@testable import TkzTerminalCore

/// Repo root, derived from this file: Tests/TkzTerminalCoreTests/GhosttyVtTests.swift.
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Re-serialised with sorted keys so formatting differences never matter.
private func canonicalJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func lines(_ screen: String) -> [String] {
    screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

@Suite struct GhosttyVtTests {
    /// `ghostty_build_info` reports the *library* version (0.1.0-dev at the pinned commit), not Ghostty's app version.
    @Test func versionLinks() {
        let version = GhosttyVtInfo.versionString
        #expect(!version.isEmpty)
        #expect(version.split(separator: ".").count >= 3)
        #expect(GhosttyVtInfo.optimizeName == "ReleaseFast")
    }

    /// TKZ-7 acceptance: 80×24, write "hello", PLAIN format → first line starts with hello.
    @Test func smokeHello() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        terminal.write("hello")
        let screen = try terminal.formatted()
        #expect(lines(screen).first?.hasPrefix("hello") == true)
    }

    @Test func styledTextRoundTrip() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        terminal.write("a\u{1b}[1mb\u{1b}[0mc\r\nd")
        let rows = lines(try terminal.formatted()).filter { !$0.isEmpty }
        #expect(rows == ["abc", "d"])
    }

    @Test func resizeKeepsContent() throws {
        let terminal = try GhosttyTerminalHandle(cols: 80, rows: 24)
        terminal.write("hello")
        try terminal.resize(cols: 40, rows: 10)
        #expect(lines(try terminal.formatted()).first?.hasPrefix("hello") == true)
    }

    @Test func encoderAndRenderStateHandlesAllocate() throws {
        _ = try GhosttyRenderStateHandle()
        _ = try GhosttyKeyEncoderHandle()
        _ = try GhosttyMouseEncoderHandle()
    }

    /// The committed manifest must describe the binary we link: drift here means `make vendor` was skipped.
    @Test func abiManifestMatchesVendoredFile() throws {
        let file = repoRoot.appending(path: "vendor/ghostty-vt/abi-types.json")
        let vendored = try canonicalJSON(Data(contentsOf: file))
        let live = try canonicalJSON(Data(GhosttyVtInfo.abiManifestJSON.utf8))
        #expect(!vendored.isEmpty)
        #expect(vendored == live)
    }

    @Test func terminfoVendored() {
        let path = repoRoot.appending(path: "Resources/terminfo/78/xterm-ghostty").path
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
