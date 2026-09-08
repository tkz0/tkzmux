// Guards the tkzmux-hook rule CLAUDE.md states directly: "Keep tkzmux-hook free of Foundation."
// The ticket further restricts it to `import Darwin` only. Mirrors the pattern in
// Tests/TkzCoreTests/SourceHygieneTests.swift (locate the module by #filePath, not the cwd).
import Foundation
import Testing

@testable import ClaudeBridge

@Suite struct HookHygieneTests {
    static var moduleDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/ClaudeBridgeTests/HookHygieneTests.swift
            .deletingLastPathComponent()          // Tests/ClaudeBridgeTests
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

    /// Every import statement in Sources/tkzmux-hook must be `import Darwin` — no Foundation, no
    /// anything else. `tkzmux-hook` must stay tiny and fast (< 20 ms) and never pull in Foundation's
    /// startup cost.
    @Test func onlyImportsDarwin() throws {
        let pattern = try NSRegularExpression(pattern: #"^\s*(@_exported\s+)?import\s+(\S+)"#)
        var offences: [String] = []
        for url in try Self.swiftSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = pattern.firstMatch(in: String(line), range: range) else { continue }
                guard let moduleRange = Range(match.range(at: 2), in: line) else { continue }
                let module = String(line[moduleRange])
                if module != "Darwin" {
                    offences.append("\(url.lastPathComponent):\(number + 1): import \(module)")
                }
            }
        }
        #expect(offences.isEmpty, "Sources/tkzmux-hook must only import Darwin: \(offences)")
    }

    /// The regex is only worth something if it can actually see an offending line.
    @Test func theImportCheckWouldCatchAnOffender() throws {
        let pattern = try NSRegularExpression(pattern: #"^\s*(@_exported\s+)?import\s+(\S+)"#)
        for line in ["import Foundation", "  import Dispatch", "@_exported import os"] {
            let range = NSRange(line.startIndex..., in: line)
            let match = pattern.firstMatch(in: line, range: range)
            #expect(match != nil)
            if let match, let moduleRange = Range(match.range(at: 2), in: line) {
                #expect(String(line[moduleRange]) != "Darwin")
            }
        }
        for line in ["import Darwin", "// import Foundation in a comment"] {
            let range = NSRange(line.startIndex..., in: line)
            if let match = pattern.firstMatch(in: line, range: range),
               let moduleRange = Range(match.range(at: 2), in: line) {
                #expect(String(line[moduleRange]) == "Darwin")
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
