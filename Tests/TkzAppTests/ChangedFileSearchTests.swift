import AppKit
import Foundation
import GitStatus
import Testing
import TkzCore

@testable import TkzApp

/// The overlay's "Files changed" section (TKZ-52, design 2c.6). The ranking is pure — the paths are
/// handed in, so none of this needs a repo on disk.
@MainActor
@Suite(.serialized)
struct ChangedFileSearchTests {

    static let session = (id: SessionID(uuid: UUID()), title: "core-invest")
    static let other = (id: SessionID(uuid: UUID()), title: "aira")

    static func rows(
        _ query: String,
        _ paths: [SessionID: [ChangedPath]],
        limit: Int = 60
    ) -> [FileRow] {
        MainWindowController.fileRows(
            matching: query,
            sessions: [session, other],
            paths: { paths[$0] ?? [] },
            limit: limit)
    }

    static func changed(_ paths: String...) -> [ChangedPath] {
        paths.map { ChangedPath(path: $0, status: "M") }
    }

    // MARK: Ranking

    @Test func aPathHitCarriesItsSessionAndStatus() throws {
        let rows = Self.rows(
            "audit",
            [
                Self.session.id: [
                    ChangedPath(path: "src/Api/PositionAuditService.cs", status: "M"),
                    ChangedPath(path: "src/Api/Startup.cs", status: "A"),
                ]
            ])

        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.sessionID == Self.session.id)
        #expect(row.sessionTitle == "core-invest")
        #expect(row.status == "M")
        #expect(row.path == "src/Api/PositionAuditService.cs")
        let range = try #require(row.matchRanges.first)
        #expect(row.path[range].lowercased().hasPrefix("a"))
    }

    @Test func theShorterPathWinsATie() throws {
        let rows = Self.rows(
            "readme",
            [Self.session.id: Self.changed("docs/deep/nested/README.md", "README.md")])
        #expect(rows.map(\.path) == ["README.md", "docs/deep/nested/README.md"])
    }

    @Test func hitsFromEverySessionAreRankedTogether() {
        let rows = Self.rows(
            "service",
            [
                Self.session.id: Self.changed("src/PositionService.cs"),
                Self.other.id: Self.changed("api/Service.swift"),
            ])
        #expect(Set(rows.map(\.sessionID)) == [Self.session.id, Self.other.id])
    }

    @Test func aShortQueryIsNotASearch() {
        // One character matches every path in every tree, which is noise rather than a result.
        #expect(Self.rows("s", [Self.session.id: Self.changed("src/A.swift")]).isEmpty)
        #expect(Self.rows("  ", [Self.session.id: Self.changed("src/A.swift")]).isEmpty)
        #expect(!Self.rows("sr", [Self.session.id: Self.changed("src/A.swift")]).isEmpty)
    }

    @Test func aPathThatDoesNotMatchIsNotListed() {
        #expect(Self.rows("kubernetes", [Self.session.id: Self.changed("src/A.swift")]).isEmpty)
    }

    @Test func theLimitCapsTheList() {
        let paths = (0..<200).map { ChangedPath(path: "src/File\($0)Service.swift", status: "M") }
        #expect(Self.rows("service", [Self.session.id: paths], limit: 5).count == 5)
    }

    @Test func noGitIntegrationMeansNoFilesSection() {
        let harness = MainWindowControllerTests.makeHarness()
        defer { harness.tearDown() }
        // `git` is nil in the harness: the section is simply absent, not an error.
        #expect(harness.controller.changedFileRows(matching: "service").isEmpty)
    }

    // MARK: Rendering

    @Test func theMatchedCharactersOfAPathAreMarked() throws {
        let rows = Self.rows("audit", [Self.session.id: Self.changed("src/PositionAudit.cs")])
        let row = try #require(rows.first)
        let string = SearchFileRowView.pathString(row, theme: .default)

        var marked = ""
        string.enumerateAttribute(
            .backgroundColor, in: NSRange(location: 0, length: string.length)
        ) { value, range, _ in
            if let color = value as? NSColor, color == Theme.default.searchMatchBackground.nsColor {
                marked += (string.string as NSString).substring(with: range)
            }
        }
        #expect(marked.lowercased() == "audit")
    }
}
