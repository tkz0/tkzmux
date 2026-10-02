// Guards the code that builds on Linux against run-loop-bound APIs. On Linux the main loop is GTK's
// (WOR-314), and a Foundation `Timer`, a `RunLoop.main` source or a `perform(_:afterDelay:)` never
// fires under it; under Swift Testing's async main a nested `RunLoop.run` does not drain the main
// queue either (docs/linux/spikes.md, "RunLoop inventory" and S3). Such code compiles and passes
// review, and then silently does nothing, so it is caught here instead.
//
// The scanned set is every target in the arrays Package.swift marks `hygiene-scan` (`shared` and
// `linuxOnly`), read from the manifest so a target moved there is covered without touching this
// file. The test is plain text processing and runs on both OSes.

import Foundation
import Testing

@Suite struct RunLoopHygieneTests {
    /// The repo root, located from this file rather than the working directory.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/TkzCoreTests/RunLoopHygieneTests.swift
            .deletingLastPathComponent()          // Tests/TkzCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // <repo>
    }

    /// What is forbidden: the spikes.md inventory grep plus `dispatchMain()`. Written so that this
    /// file's own source does not match it (hence `after[D]elay`).
    static let forbidden = #"\bRunLoop\b|CFRunLoop[A-Za-z]*\(|\.add\(to: *\.main|Timer\.scheduledTimer|Timer\((timeInterval|fire)|after[D]elay:|\bdispatchMain\(\)"#

    /// The known run-loop-bound sites that may stay, as repo-relative path + the trimmed line.
    /// Only WOR-300 S2's Mac-only inventory: the display link at TerminalMetalView.swift:546, which
    /// WOR-314 replaces with the GTK frame clock. Keyed by text, not line number, so an unrelated
    /// edit above it does not break the entry. Spliced, like the samples below, so that this
    /// file does not match the pattern itself.
    static let allowed: Set<String> = [
        "Sources/TkzTerminalView/TerminalMetalView.swift: link.add(to:" + " .main, forMode: .common)",
    ]

    /// The `path:` of every `Sources/…` or `Tests/…` target in Package.swift's `hygiene-scan` arrays.
    static func scannedTargetPaths() throws -> [String] {
        let manifest = try String(
            contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let named = try NSRegularExpression(
            pattern: #"\.(target|executableTarget|testTarget)\(\s*name:\s*"([^"]+)""#)
        let path = try NSRegularExpression(pattern: #"path:\s*"((?:Sources|Tests)/[^"]+)""#)

        var paths: [String] = []
        var arrays = 0
        var block: [Substring]?
        for line in manifest.split(separator: "\n", omittingEmptySubsequences: false) {
            if block == nil, line.hasPrefix("let "), line.hasSuffix("// hygiene-scan") {
                block = []
            } else if let lines = block, line == "]" {
                let text = lines.joined(separator: "\n")
                let range = NSRange(text.startIndex..., in: text)
                let found = path.matches(in: text, range: range).compactMap { match in
                    Range(match.range(at: 1), in: text).map { String(text[$0]) }
                }
                // A target on SwiftPM's default path would silently escape the scan.
                let targets = named.numberOfMatches(in: text, range: range)
                #expect(found.count == targets, "every scanned target needs an explicit Sources/ or Tests/ path: \(text)")
                paths += found
                arrays += 1
                block = nil
            } else {
                block?.append(line)
            }
        }
        #expect(arrays >= 2, "Package.swift should mark the shared and linuxOnly arrays `hygiene-scan`")
        return paths
    }

    /// Lines in `paths` that match ``forbidden``, as `path:line: text`, minus ``allowed`` and
    /// minus whole-line comments (the inventory grep skips those too).
    static func offences(in paths: [String], allowing allowed: Set<String> = allowed) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: forbidden)
        var offences: [String] = []
        for directory in paths {
            let root = repoRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                offences.append("\(directory): cannot be listed")
                continue
            }
            let files = walker.compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
                .sorted { $0.path < $1.path }
            for url in files {
                let relative = url.path.hasPrefix(root.path + "/")
                    ? directory + url.path.dropFirst(root.path.count)
                    : "\(directory)/…/\(url.lastPathComponent)"
                let text = try String(contentsOf: url, encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || allowed.contains("\(relative): \(trimmed)") { continue }
                    if pattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                        offences.append("\(relative):\(number + 1): \(trimmed)")
                    }
                }
            }
        }
        return offences
    }

    @Test func readsTheScannedTargetsFromThePackageManifest() throws {
        let paths = try Self.scannedTargetPaths()
        #expect(paths.contains("Sources/TkzCore"))
        #expect(paths.contains("Tests/TkzCoreTests"))
        #expect(paths.contains("Sources/tkzmux-linux"))
        #expect(paths.contains("Tests/GhosttyVtSmokeTests"))
        // The Mac-only graph is not scanned.
        #expect(!paths.contains("Sources/TkzApp"))
        #expect(!paths.contains("Sources/TkzTerminalView"))
    }

    @Test func noRunLoopBoundAPIsInTheLinuxGraph() throws {
        let offences = try Self.offences(in: try Self.scannedTargetPaths())
        #expect(offences.isEmpty, "run-loop-bound APIs never fire under the Linux main loop: \(offences)")
    }

    /// The allow-list entry still names a real line, and hides exactly that one. (Only the entry is
    /// checked: TkzTerminalView is Mac-only and not scanned.)
    @Test func theAllowListEntryMatchesTheDisplayLink() throws {
        let unfiltered = try Self.offences(in: ["Sources/TkzTerminalView"], allowing: [])
        let filtered = try Self.offences(in: ["Sources/TkzTerminalView"])
        #expect(unfiltered.contains { $0.hasPrefix("Sources/TkzTerminalView/TerminalMetalView.swift:") })
        #expect(filtered.count == unfiltered.count - 1)
    }

    /// The pattern is only worth something if it can see an offender. The samples are spliced
    /// together so this file does not contain them verbatim.
    @Test func thePatternWouldCatchAnOffender() throws {
        let pattern = try NSRegularExpression(pattern: Self.forbidden)
        let offenders = [
            "Timer" + ".scheduledTimer(withTimeInterval: 1, repeats: false) { _ in }",
            "Run" + "Loop.main.add(timer, forMode: .common)",
            "Run" + "Loop.current.run(until: Date())",
            "perform(#selector(tick), with: nil, after" + "Delay: 0.5)",
            "dispatch" + "Main()",
            "link.add(to: " + ".main, forMode: .common)",
            "let t = Timer" + "(timeInterval: 1, repeats: true) { _ in }",
            "CFRun" + "LoopRun()",
        ]
        for line in offenders {
            #expect(pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil, "\(line)")
        }
        for line in ["try await Task.sleep(for: .seconds(1))", "DispatchQueue.main.async { }", "let runLoopFree = true"] {
            #expect(pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil, "\(line)")
        }
    }
}
