// Guards the seam for the third agent: nothing under `Sources/AgentBridge/Antigravity/` may name
// either of the other supported agents. Sibling of `CodexHygieneTests`, which does the same scan
// for its own directory — read that one first.
//
// One deliberate difference from the Codex rule: this directory is allowed to say `gemini`, and
// has to. Antigravity's config lives at `~/.gemini`, named after the CLI it replaced, so a file
// here that could not write that word could not describe the path it actually reads. The forbidden
// list is other *agents tkzmux supports*, not every product name in existence.
import Foundation
import Testing

@testable import AgentBridge

@Suite struct AntigravityHygieneTests {
    static var moduleDirectory: URL {
        URL(fileURLWithPath: #filePath)          // Tests/AgentBridgeTests/AntigravityHygieneTests.swift
            .deletingLastPathComponent()          // Tests/AgentBridgeTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // <repo>
            .appendingPathComponent("Sources/AgentBridge/Antigravity")
    }

    /// The agents this directory must not name. `gemini` is deliberately absent — see the header.
    static let forbidden = ["claude", "codex"]

    static func swiftSources() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: moduleDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func findsTheAntigravityDirectory() throws {
        let names = try Self.swiftSources().map(\.lastPathComponent)
        #expect(names.contains("AntigravityAdapter.swift"))
        #expect(names.contains("AntigravityHookMapper.swift"))
        #expect(names.contains("AntigravityTranscriptReader.swift"))
        #expect(names.contains("AntigravityHooksInstaller.swift"))
    }

    /// No file under this directory may name another supported agent — not its types, not its
    /// environment-variable prefix, not its product name, not even in a comment. This directory's
    /// whole reason to exist is to keep one agent's vocabulary from leaking into another's, and a
    /// copy-pasted type name is exactly how that starts.
    @Test func namesNoOtherSupportedAgent() throws {
        var offences: [String] = []
        for url in try Self.swiftSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let haystack = line.lowercased()
                for name in Self.forbidden where haystack.contains(name) {
                    offences.append("\(url.lastPathComponent):\(number + 1): \(line)")
                }
            }
        }
        #expect(
            offences.isEmpty,
            "Sources/AgentBridge/Antigravity must not name another supported agent: \(offences)")
    }

    /// The scan above is only worth something if it can actually see an offending line — the same
    /// "the check itself works" proof the sibling suites give their own scans.
    @Test func theScanWouldCatchAnOffender() {
        func offends(_ line: String) -> Bool {
            let haystack = line.lowercased()
            return Self.forbidden.contains { haystack.contains($0) }
        }
        #expect(offends("let dir = ClaudeAdapter().binaryName"))
        #expect(offends("// falls back the way codex does"))
        #expect(offends("CLAUDE_CONFIG_DIR"))
        // And the allowances: this directory's own vocabulary, and the config path it must name.
        #expect(!offends("let configDir = home + \"/.gemini\""))
        #expect(!offends("public let kind: AgentKind = .antigravity"))
    }
}
