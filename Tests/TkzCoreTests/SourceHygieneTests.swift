// Guards the one architectural rule TkzCore cannot express in the type system: it is the headless
// half of the app, so it must never import a UI framework. This test reads the module's own
// sources — a regression here fails the build long before someone tries to link TkzCore into a
// command-line tool. Since WOR-304 it also keeps OS-only frameworks (CoreGraphics, os, CryptoKit,
// the GTK/Vulkan/text stack) out of TkzCore, Persistence and TkzPlatform's shared code.

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

    /// M2.1 acceptance: no `import AppKit` / `import SwiftUI` (or Cocoa) anywhere in TkzCore.
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

    // MARK: Platform frameworks (WOR-304 S3)

    /// Frameworks that exist on one OS only, or belong to a UI layer: TkzCore builds on both OSes
    /// headless, and TkzPlatform keeps them in its per-OS `Darwin/` back-end. `#if canImport`
    /// guards do not hide an import from this, by design: WOR-303's temporary CoreGraphics guards
    /// are gone and must not come back.
    static let platformImport =
        #"^\s*(@_exported\s+)?import\s+(Gtk|Gdk|CGtk|Vulkan|FreeType|HarfBuzz|Fontconfig|CoreGraphics|os|CryptoKit)\b"#

    static let coreGraphicsImport = #"^\s*(@_exported\s+)?import\s+CoreGraphics\b"#

    /// The TkzApp presentation-model files TkzCore's geometry types flow into; WOR-308/WOR-310 port
    /// them, so they must stay on Foundation's `CGFloat`/`CGRect`.
    static let tkzAppModelFiles = [
        "Sources/TkzApp/Panes/PaneHeaderModels.swift",
        "Sources/TkzApp/Panes/PaneModels.swift",
        "Sources/TkzApp/Tabs/TabStripModels.swift",
    ]

    static var repoRoot: URL { moduleDirectory.deletingLastPathComponent().deletingLastPathComponent() }

    /// Every `.swift` file under `directory` (repo-relative), recursively, sorted.
    static func swiftSources(under directory: String) throws -> [URL] {
        let root = repoRoot.appendingPathComponent(directory)
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// `file:line: text` for each line of `files` that matches `pattern`.
    static func offences(of pattern: String, in files: [URL]) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var offences: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (number, line) in lines.enumerated() {
                // On Apple platforms CGRect's geometry API and its Hashable/Codable conformances live
                // in the CoreGraphics overlay, so shared files may import it — but only guarded, so
                // Linux (where the guard is false) keeps using swift-corelibs-foundation's CG types.
                if number > 0, lines[number - 1].trimmingCharacters(in: .whitespaces) == "#if canImport(CoreGraphics)",
                   line.trimmingCharacters(in: .whitespaces).hasPrefix("import CoreGraphics") {
                    continue
                }
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                    offences.append("\(relative):\(number + 1): \(line)")
                }
            }
        }
        return offences
    }

    @Test func noPlatformFrameworkImportsInTkzCore() throws {
        let files = try Self.swiftSources(under: "Sources/TkzCore")
        #expect(files.count >= 6)
        let offences = try Self.offences(of: Self.platformImport, in: files)
        #expect(offences.isEmpty, "TkzCore builds on both OSes: \(offences)")
    }

    @Test func platformFrameworksOnlyInTkzPlatformsDarwinBackEnd() throws {
        let all = try Self.swiftSources(under: "Sources/TkzPlatform")
        let shared = all.filter { !$0.path.contains("/Sources/TkzPlatform/Darwin/") }
        #expect(shared.count < all.count, "the Darwin back-end was not found")
        #expect(shared.contains { $0.lastPathComponent == "AppPaths.swift" })
        let offences = try Self.offences(of: Self.platformImport, in: shared)
        #expect(offences.isEmpty, "only TkzPlatform/Darwin/ may import these: \(offences)")
    }

    @Test func noCoreGraphicsInPersistenceOrTheTkzAppModelFiles() throws {
        let files = try Self.swiftSources(under: "Sources/Persistence")
            + Self.tkzAppModelFiles.map { Self.repoRoot.appendingPathComponent($0) }
        #expect(files.count >= 7)
        let offences = try Self.offences(of: Self.coreGraphicsImport, in: files)
        #expect(offences.isEmpty, "CoreGraphics only behind #if canImport(CoreGraphics): \(offences)")
    }

    // MARK: Design tokens (WOR-307 S3)

    /// `DesignTokens*.swift` is the toolkit-free table both UIs read, so it imports Foundation and
    /// nothing else — not even CoreGraphics, which `platformImport` would also catch but
    /// `noUIFrameworkImports` would not — and spells its values as `Double`, never `CGFloat`.
    @Test func designTokensImportOnlyFoundation() throws {
        let files = try Self.swiftSources().filter { $0.lastPathComponent.hasPrefix("DesignTokens") }
        #expect(files.count >= 2, "the DesignTokens sources were not found")
        let imports = try NSRegularExpression(pattern: #"^\s*(@_exported\s+)?import\s+(\w+)"#)
        var offences: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            var foundation = false
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(line)
                let range = NSRange(line.startIndex..., in: line)
                if let match = imports.firstMatch(in: line, range: range),
                   let module = Range(match.range(at: 2), in: line).map({ String(line[$0]) }) {
                    if module == "Foundation" { foundation = true } else {
                        offences.append("\(url.lastPathComponent):\(number + 1): \(line)")
                    }
                }
                let code = line.components(separatedBy: "//")[0]
                if code.contains("CGFloat") || code.contains("CGRect") || code.contains("CGSize") {
                    offences.append("\(url.lastPathComponent):\(number + 1): \(line)")
                }
            }
            if !foundation { offences.append("\(url.lastPathComponent): no `import Foundation`") }
        }
        #expect(offences.isEmpty, "DesignTokens is Foundation and Double only: \(offences)")
    }

    /// The platform pattern sees guarded and re-exported imports, and only imports.
    @Test func thePlatformImportCheckWouldCatchAnOffender() throws {
        let pattern = try NSRegularExpression(pattern: Self.platformImport)
        let offenders = [
            "import CoreGraphics", "  import CoreGraphics", "@_exported import os", "import os",
            "import CryptoKit", "import Gtk", "import CGtk", "import Vulkan", "import HarfBuzz",
            "import FreeType", "import Fontconfig", "import Gdk",
        ]
        for line in offenders {
            #expect(pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil, "\(line)")
        }
        let fine = [
            "import Foundation", "import Glibc", "import Darwin", "import OSLog", "import osx",
            "#if canImport(CoreGraphics)", "// import CoreGraphics", "let s = \"import os\"",
            "import TkzPlatform",
        ]
        for line in fine {
            #expect(pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil, "\(line)")
        }
    }
}
