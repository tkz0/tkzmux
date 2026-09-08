// Guards the one architectural rule TkzCore cannot express in the type system: it is the headless
// half of the app, so it must never import a UI framework. This test reads the module's own
// sources — a regression here fails the build long before someone tries to link TkzCore into a
// command-line tool.

import Foundation
import Testing

@testable import TkzCore

@Suite struct SourceHygieneTests {
    /// `Sources/TkzCore`, located from this file rather than the working directory.
    static var moduleDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/TkzCoreTests/SourceHygieneTests.swift
            .deletingLastPathComponent()          // Tests/TkzCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // <repo>
            .appendingPathComponent("Sources/TkzCore")
    }

    static func swiftSources() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: moduleDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func findsTheModuleSources() throws {
        let names = try Self.swiftSources().map(\.lastPathComponent)
        #expect(names.contains("AppStore.swift"))
        #expect(names.contains("Models.swift"))
        #expect(names.count >= 6)
    }

    /// TKZ-17 acceptance: no `import AppKit` / `import SwiftUI` (or Cocoa) anywhere in TkzCore.
    /// Matches actual import statements, not the word — RGB.swift's header comment mentions AppKit.
    @Test func noUIFrameworkImports() throws {
        let pattern = try NSRegularExpression(
            pattern: #"^\s*(@_exported\s+)?import\s+(AppKit|SwiftUI|Cocoa)\b"#)
        var offences: [String] = []
        for url in try Self.swiftSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if pattern.firstMatch(in: String(line), range: range) != nil {
                    offences.append("\(url.lastPathComponent):\(number + 1): \(line)")
                }
            }
        }
        #expect(offences.isEmpty, "TkzCore must stay UI-framework free: \(offences)")
    }

    /// The regex above is only worth something if it can actually see an offending line.
    @Test func theImportCheckWouldCatchAnOffender() throws {
        let pattern = try NSRegularExpression(
            pattern: #"^\s*(@_exported\s+)?import\s+(AppKit|SwiftUI|Cocoa)\b"#)
        for line in ["import AppKit", "  import SwiftUI", "@_exported import Cocoa"] {
            #expect(pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil)
        }
        for line in ["// No AppKit/Foundation here", "import Foundation", "let s = \"import AppKit\""] {
            #expect(pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil)
        }
    }
}
