// Guards the logging migration (WOR-304 S1): `os` is imported in exactly one place,
// Sources/TkzPlatform/Darwin/, and every other file logs through `TkzLogger`/`TkzSignposter`. On
// Linux there is no `os` module and the facade is a different type with the same API, so a stray
// `import os` or `Logger(`/`OSSignposter(` would build on the Mac and break only the Linux build.
// This test reads the source tree, so it runs on both OSes and catches the regression on either.

import Foundation
import Testing

@Suite struct LoggingImportHygieneTests {
    /// The repo root, located from this file rather than the working directory.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/TkzPlatformTests/LoggingImportHygieneTests.swift
            .deletingLastPathComponent()          // Tests/TkzPlatformTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // <repo>
    }

    /// The only directory allowed to import `os` or name the `os` types directly.
    static let darwinFacade = "Sources/TkzPlatform/Darwin/"

    /// An import of `os` (or a submodule such as `os.log`) or of `OSLog`.
    static let osImport = #"^\s*(@_exported\s+)?import\s+(os|OSLog)\b"#

    /// The `os` type names the facade replaces. `TkzLogger` does not match: there is no word
    /// boundary inside it.
    static let osTypeName = #"\b(Logger|OSSignposter)\b"#

    /// Every Swift file under Sources/, as a repo-relative path.
    static func sourceFiles() throws -> [String] {
        let sources = repoRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let root = repoRoot.path + "/"
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { $0.path.hasPrefix(root) ? String($0.path.dropFirst(root.count)) : $0.path }
            .sorted()
    }

    /// Lines outside ``darwinFacade`` that match `pattern`, as `path:line: text`, skipping
    /// whole-line comments.
    static func offences(matching pattern: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        var offences: [String] = []
        for path in try sourceFiles() where !path.hasPrefix(darwinFacade) {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                    offences.append("\(path):\(number + 1): \(trimmed)")
                }
            }
        }
        return offences
    }

    @Test func findsTheSources() throws {
        let files = try Self.sourceFiles()
        #expect(files.contains("Sources/TkzPlatform/Darwin/Logging.swift"))
        #expect(files.contains("Sources/TkzCore/AppStore.swift"))
    }

    @Test func osIsImportedOnlyByTheDarwinFacade() throws {
        let offences = try Self.offences(matching: Self.osImport)
        #expect(offences.isEmpty, "import TkzPlatform instead of os: \(offences)")
    }

    @Test func callSitesNameTheFacadeTypes() throws {
        let offences = try Self.offences(matching: Self.osTypeName)
        #expect(offences.isEmpty, "use TkzLogger/TkzSignposter, which also exist on Linux: \(offences)")
    }

    /// The facade itself still has its import, so the scan above is looking at the right files.
    @Test func theDarwinFacadeImportsOS() throws {
        let regex = try NSRegularExpression(pattern: Self.osImport, options: .anchorsMatchLines)
        let text = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(Self.darwinFacade + "Logging.swift"), encoding: .utf8)
        #expect(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)
    }

    /// The patterns are only worth something if they can see an offender.
    @Test func thePatternsWouldCatchAnOffender() throws {
        let imports = try NSRegularExpression(pattern: Self.osImport)
        let names = try NSRegularExpression(pattern: Self.osTypeName)
        func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
            regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        for line in ["import os", "  import os", "@_exported import os", "import os.log", "import OSLog"] {
            #expect(matches(imports, line), "\(line)")
        }
        for line in ["import osmium", "import Foundation", "import TkzPlatform"] {
            #expect(!matches(imports, line), "\(line)")
        }
        for line in [
            "private let logger = Logger(subsystem: \"s\", category: \"c\")",
            "func f(logger: Logger) {}",
            "let s = OSSignposter(subsystem: \"s\", category: \"c\")",
        ] {
            #expect(matches(names, line), "\(line)")
        }
        for line in [
            "private let logger = TkzLogger(subsystem: \"s\", category: \"c\")",
            "let s = TkzSignposter(subsystem: \"s\", category: \"c\")",
            "logger.error(\"failed\")",
        ] {
            #expect(!matches(names, line), "\(line)")
        }
    }
}
