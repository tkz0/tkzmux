import Foundation
import Testing
@testable import TkzTerminalCore

/// Repo root, derived from this file: Tests/TkzTerminalCoreTests/GhosttyVtTests.swift.
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Re-serialised with sorted keys so formatting differences never matter: corelibs
/// `JSONSerialization` on Linux pretty-prints differently from Darwin's.
private func canonicalJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// The ABI manifests `make vendor` (macOS) and `make vendor-linux` commit, one per OS.
private let macManifest = "vendor/ghostty-vt/abi-types.aarch64-macos.json"
private let linuxManifest = "vendor/ghostty-vt/abi-types.x86_64-linux-gnu.json"
private let linuxBundle = "vendor/ghostty-vt/ghostty-vt-linux.artifactbundle"

private func jsonObject(_ path: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: repoRoot.appending(path: path)))
    return try #require(object as? [String: Any], "\(path) is not a JSON object")
}

/// One manifest value as canonical JSON (wrapped in an array, so scalars and null serialise too).
private func canonical(_ value: Any?) throws -> Data {
    try JSONSerialization.data(withJSONObject: [value ?? NSNull()], options: [.sortedKeys])
}

/// Every regular file under `directory`, keyed by its path relative to it.
private func fileTree(_ directory: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    for path in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
        var isDirectory: ObjCBool = false
        let url = directory.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
        files[path] = try Data(contentsOf: url)
    }
    return files
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

    /// M1.1 acceptance: 80×24, write "hello", PLAIN format → first line starts with hello.
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

    /// The committed manifest must describe the binary we link: drift here means `make vendor`
    /// (or `make vendor-linux`) was skipped.
    @Test func abiManifestMatchesVendoredFile() throws {
        #if os(Linux) && arch(x86_64)
        let file = repoRoot.appending(path: linuxManifest)
        #else
        let file = repoRoot.appending(path: macManifest)
        #endif
        let vendored = try canonicalJSON(Data(contentsOf: file))
        let live = try canonicalJSON(Data(GhosttyVtInfo.abiManifestJSON.utf8))
        #expect(!vendored.isEmpty)
        #expect(vendored == live)
    }

    /// The two OS builds of one commit: identical types, library version and schema. Only `abi`
    /// (target, os, environment) may differ, so a layout change on either side fails here even
    /// on the OS that does not link it.
    @Test func abiManifestsAgreeAcrossOSes() throws {
        let mac = try jsonObject(macManifest)
        let linux = try jsonObject(linuxManifest)
        #expect(Set(mac.keys) == Set(linux.keys))
        #expect(mac["library_version"] != nil && mac["schema"] != nil)
        for key in Set(mac.keys).union(linux.keys).subtracting(["abi", "types"]).sorted() {
            #expect(try canonical(mac[key]) == canonical(linux[key]), "\(key) differs")
        }
        // Per type, so a failure names the struct or enum that drifted.
        let macTypes = try #require(mac["types"] as? [String: Any])
        let linuxTypes = try #require(linux["types"] as? [String: Any])
        #expect(!macTypes.isEmpty)
        #expect(macTypes.keys.sorted() == linuxTypes.keys.sorted())
        for name in macTypes.keys.sorted() where linuxTypes[name] != nil {
            #expect(try canonical(macTypes[name]) == canonical(linuxTypes[name]), "types.\(name) differs")
        }
        let macABI = try #require(mac["abi"] as? [String: Any])
        let linuxABI = try #require(linux["abi"] as? [String: Any])
        #expect(macABI["target"] as? String == "aarch64")
        #expect(macABI["os"] as? String == "macos")
        #expect(linuxABI["target"] as? String == "x86_64")
        #expect(linuxABI["os"] as? String == "linux")
        #expect(linuxABI["environment"] as? String == "gnu")
    }

    /// The Linux bundle is built at the pinned commit too; the two variants must never drift apart.
    @Test func linuxBundleBuiltAtVendoredCommit() throws {
        let commit = try String(contentsOf: repoRoot.appending(path: "vendor/ghostty-vt/COMMIT"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let buildInfo = try String(contentsOf: repoRoot.appending(path: "\(linuxBundle)/BUILDINFO"), encoding: .utf8)
        let recorded = buildInfo.split(separator: "\n").first { $0.hasPrefix("commit=") }?.dropFirst("commit=".count)
        #expect(commit.count == 40)
        #expect(recorded.map(String.init) == commit)
    }

    /// Both variants compile against the same C API: the xcframework's and the bundle's headers
    /// (module map included) are byte-identical.
    @Test func headerTreesByteIdentical() throws {
        let xcframework = try fileTree(repoRoot.appending(path: "vendor/ghostty-vt/ghostty-vt.xcframework/macos-arm64/Headers"))
        let bundle = try fileTree(repoRoot.appending(path: "\(linuxBundle)/include"))
        #expect(xcframework["module.modulemap"] != nil)
        #expect(xcframework["ghostty/vt.h"] != nil)
        #expect(xcframework.keys.sorted() == bundle.keys.sorted())
        for (path, bytes) in xcframework {
            #expect(bundle[path] == bytes, "\(path) differs")
        }
    }

    /// Both directory layouts: hex for macOS ncurses, letter for Linux ncurses.
    @Test(arguments: ["78/xterm-ghostty", "67/ghostty", "x/xterm-ghostty", "g/ghostty"])
    func terminfoVendored(entry: String) {
        let path = repoRoot.appending(path: "Resources/terminfo/\(entry)").path
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// The letter layout is a copy of the hex one (scripts/build-ghostty-vt.sh mirrors whichever
    /// layout the host tic wrote), so the two can never describe different terminals.
    @Test(arguments: [("78/xterm-ghostty", "x/xterm-ghostty"), ("67/ghostty", "g/ghostty")])
    func terminfoLayoutsByteIdentical(hex: String, letter: String) throws {
        let terminfo = repoRoot.appending(path: "Resources/terminfo")
        let hexBytes = try Data(contentsOf: terminfo.appending(path: hex))
        let letterBytes = try Data(contentsOf: terminfo.appending(path: letter))
        #expect(!hexBytes.isEmpty)
        #expect(hexBytes == letterBytes)
    }
}
