// Guards the tkzmux-hook rule CLAUDE.md states directly: "Keep tkzmux-hook free of Foundation."
// The ticket further restricts it to libc only: `Darwin`, `Glibc` or `Musl` (WOR-305). Mirrors the
// pattern in Tests/TkzCoreTests/SourceHygieneTests.swift (locate the module by #filePath, not the
// cwd). Imports nothing from AgentBridge, so it also runs on Linux (Package.swift).
import Foundation
import Testing

@Suite struct HookHygieneTests {
    static var moduleDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/AgentBridgeTests/HookHygieneTests.swift
            .deletingLastPathComponent()          // Tests/AgentBridgeTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // <repo>
            .appendingPathComponent("Sources/tkzmux-hook")
    }

    static func swiftSources() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: moduleDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func findsTheModuleSources() throws {
        let names = try Self.swiftSources().map(\.lastPathComponent)
        #expect(names.contains("main.swift"))
        #expect(names.count >= 4)
    }

    /// The C library module of each OS the hook builds on; musl is the fully static Linux build.
    static let allowedModules: Set<String> = ["Darwin", "Glibc", "Musl"]

    /// Every import statement in Sources/tkzmux-hook must import the C library — no Foundation
    /// (nor FoundationEssentials), no anything else. `tkzmux-hook` must stay tiny and fast (< 20 ms)
    /// and never pull in Foundation's startup cost.
    @Test func onlyImportsLibc() throws {
        let pattern = try NSRegularExpression(pattern: #"^\s*(@_exported\s+)?import\s+(\S+)"#)
        var offences: [String] = []
        for url in try Self.swiftSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, substring) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // A String, not a Substring: corelibs Foundation has no `Range(_:in:)` for Substring.
                let line = String(substring)
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = pattern.firstMatch(in: line, range: range) else { continue }
                guard let moduleRange = Range(match.range(at: 2), in: line) else { continue }
                let module = String(line[moduleRange])
                if !Self.allowedModules.contains(module) {
                    offences.append("\(url.lastPathComponent):\(number + 1): import \(module)")
                }
            }
        }
        #expect(offences.isEmpty, "Sources/tkzmux-hook must only import Darwin, Glibc or Musl: \(offences)")
    }

    /// The regex is only worth something if it can actually see an offending line.
    @Test func theImportCheckWouldCatchAnOffender() throws {
        let pattern = try NSRegularExpression(pattern: #"^\s*(@_exported\s+)?import\s+(\S+)"#)
        for line in [
            "import Foundation", "import FoundationEssentials", "  import Dispatch", "@_exported import os",
        ] {
            let range = NSRange(line.startIndex..., in: line)
            let match = pattern.firstMatch(in: line, range: range)
            #expect(match != nil)
            if let match, let moduleRange = Range(match.range(at: 2), in: line) {
                #expect(!Self.allowedModules.contains(String(line[moduleRange])))
            }
        }
        for line in ["import Darwin", "import Glibc", "  import Musl", "// import Foundation in a comment"] {
            let range = NSRange(line.startIndex..., in: line)
            if let match = pattern.firstMatch(in: line, range: range),
               let moduleRange = Range(match.range(at: 2), in: line) {
                #expect(Self.allowedModules.contains(String(line[moduleRange])))
            }
        }
    }

    /// `print` (stdout) is only allowed in `settings-merge`'s success path.
    @Test func printOnlyInSettingsMerge() throws {
        var offences: [String] = []
        for url in try Self.swiftSources() where url.lastPathComponent != "SettingsMerge.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.contains("print(") {
                    offences.append("\(url.lastPathComponent):\(number + 1): \(line)")
                }
            }
        }
        #expect(offences.isEmpty, "stdout writes belong only in SettingsMerge.swift: \(offences)")
    }
}
