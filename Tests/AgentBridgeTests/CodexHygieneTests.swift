// Guards the seam TKZ-86 depends on: nothing under `Sources/AgentBridge/Codex/` may name the
// other supported agent's own types or environment variables. A copy-pasted `ClaudeSessionInfo` or
// a stray `CLAUDE_` would mean Codex's adapter had quietly started depending on — or worse,
// producing — the other agent's vocabulary, which is exactly what the `AgentAdapter` seam exists
// to prevent (see `AgentBridge.swift`'s header). Mirrors `HookHygieneTests`, which does the same
// kind of directory scan for a different rule; both locate their sources via `#filePath` rather
// than the working directory, since a test's cwd is not guaranteed to be the package root.
import Foundation
import Testing

@testable import AgentBridge

@Suite struct CodexHygieneTests {
    static var moduleDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/AgentBridgeTests/CodexHygieneTests.swift
            .deletingLastPathComponent()          // Tests/AgentBridgeTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // <repo>
            .appendingPathComponent("Sources/AgentBridge/Codex")
    }

    static func swiftSources() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: moduleDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func findsTheCodexDirectory() throws {
        let names = try Self.swiftSources().map(\.lastPathComponent)
        #expect(names.contains("CodexAdapter.swift"))
        #expect(names.contains("CodexHookMapper.swift"))
    }

    /// There is no exception list any more.
    ///
    /// While the module was called `ClaudeBridge`, this scan had to forgive its own name: any file
    /// citing a path necessarily wrote that word, and failing on it would have forced comments to
    /// describe paths instead of naming them. TKZ-88 renamed the module to `AgentBridge`, so the
    /// carve-out is gone and the rule is now exactly what it says — a plain search with nothing
    /// forgiven, which is the version worth trusting.
    private static let moduleNameExceptions: [String] = []

    /// No file under this directory may name the other agent — not its types, not its
    /// environment-variable prefix, not its product name, not even in a comment. This directory's
    /// whole reason to exist is to keep one agent's vocabulary from leaking into another's, and a
    /// copy-pasted type name is exactly how that starts.
    @Test func namesNothingFromTheOtherAgent() throws {
        var offences: [String] = []
        for url in try Self.swiftSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                var haystack = line.lowercased()
                for exception in Self.moduleNameExceptions {
                    haystack = haystack.replacingOccurrences(of: exception, with: "")
                }
                if haystack.contains("claude") {
                    offences.append("\(url.lastPathComponent):\(number + 1): \(line)")
                }
            }
        }
        #expect(offences.isEmpty, "Sources/AgentBridge/Codex must not name the other agent: \(offences)")
    }

    /// The scan above is only worth something if it can actually see an offending line — this is
    /// the same "the check itself works" proof `HookHygieneTests.theImportCheckWouldCatchAnOffender`
    /// gives its own regex.
    @Test func theScanWouldCatchAnOffender() {
        func offends(_ line: String) -> Bool {
            var haystack = line.lowercased()
            for exception in Self.moduleNameExceptions {
                haystack = haystack.replacingOccurrences(of: exception, with: "")
            }
            return haystack.contains("claude")
        }
        for line in ["// uses ClaudeSessionInfo", "let x = CLAUDE_CONFIG_DIR", "// Claude Code", "// claude code"] {
            #expect(offends(line))
        }
        for line in ["// Codex CLI", "let x = CODEX_HOME"] {
            #expect(!offends(line))
        }
        // The module-name exception is narrow: a path is fine, the product name beside it is not.
        #expect(!offends("// see Tests/AgentBridgeTests/Fixtures/codex/hooks-json-verified.json"))
        #expect(offends("// AgentBridge's ClaudeAdapter does this differently"))
    }
}
