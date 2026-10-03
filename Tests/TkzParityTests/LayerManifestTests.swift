// Tests/Parity/layers.json: every layer at both scales, every row with its owner issue, and the
// rule S1 promises: a pending row without an owner fails.

import Foundation
import Testing
@testable import TkzParity

@Suite struct LayerManifestTests {
    static var manifestURL: URL { TestImages.repoRoot.appending(path: "Tests/Parity/layers.json") }

    static func committed() throws -> LayerManifest {
        try LayerManifest.decode(Data(contentsOf: manifestURL))
    }

    @Test func theCommittedManifestIsValid() throws {
        let manifest = try Self.committed()
        #expect(manifest.problems() == [])
        #expect(manifest.rows.count == LayerManifest.layers.count * LayerManifest.scales.count)
        #expect(manifest.rows.count == 16)
    }

    /// The owners ADR-0003 §3 and WOR-322 name. A row changes owner only with the ADR.
    @Test func eachLayerNamesTheOwnerTheADRGivesIt() throws {
        let manifest = try Self.committed()
        let owners: [String: String] = [
            "L0-component": "WOR-316–WOR-319", "L0-window": "WOR-318 S7", "L1": "WOR-312",
            "L2": "WOR-322 S3", "L3": "WOR-313 S3", "L4": "WOR-312", "L5": "WOR-316–WOR-319",
            "L6": "WOR-318 S7",
        ]
        for row in manifest.rows {
            #expect(row.owner == owners[row.layer], "\(row.layer)@\(row.scale) is owned by \(row.owner)")
        }
    }

    /// L0, L5 and L6 stay pending until WOR-316–WOR-319 and WOR-318 S7 register producers; the
    /// layers they own may only be enforced by them.
    @Test func layersWithoutAProducerArePending() throws {
        let manifest = try Self.committed()
        for layer in ["L0-component", "L0-window", "L5", "L6"] {
            for scale in LayerManifest.scales {
                #expect(manifest.row(layer, scale: scale)?.state == .pending, "\(layer)@\(scale)")
            }
        }
    }

    @Test func aPendingRowWithoutAnOwnerFails() throws {
        var manifest = try Self.committed()
        let index = try #require(manifest.rows.firstIndex { $0.layer == "L6" && $0.scale == 1.6 })
        #expect(manifest.rows[index].state == .pending)
        for owner in ["", "TBD", "#318", "WOR-", "WOR-318 later", "WOR-319–WOR-316", " WOR-318"] {
            manifest.rows[index].owner = owner
            #expect(manifest.problems().count == 1, "owner \"\(owner)\" was accepted")
            #expect(manifest.problems().first?.hasPrefix("L6@1.6: pending row without an owner issue") == true)
        }
        // An ownerless row is rejected at decode time too: `owner` is required.
        let json = #"{"schema":1,"rows":[{"layer":"L6","scale":1.6,"state":"pending"}]}"#
        #expect(throws: DecodingError.self) { try LayerManifest.decode(Data(json.utf8)) }
    }

    @Test func ownerForms() {
        for owner in ["WOR-312", "WOR-318 S7", "WOR-313 S4b", "WOR-316–WOR-319"] {
            #expect(LayerManifest.isValidOwner(owner), "\(owner)")
        }
        for owner in ["WOR-316-WOR-319", "WOR-316–WOR-316", "wor-312", "WOR-312 s7", "312"] {
            #expect(!LayerManifest.isValidOwner(owner), "\(owner)")
        }
    }

    @Test func missingDuplicateAndUnknownRowsAreReported() throws {
        var manifest = try Self.committed()
        let first = manifest.rows.removeFirst()
        #expect(manifest.problems() == ["\(first.layer)@\(first.scale): no row"])
        manifest.rows.append(manifest.rows[0])
        manifest.rows.append(.init(layer: "L7", scale: 1.25, state: .enforced, owner: "WOR-999"))
        manifest.rows.append(first)
        let problems = manifest.problems()
        #expect(problems.contains("L7@1.25: unknown layer"))
        #expect(problems.contains("L7@1.25: unknown scale"))
        #expect(problems.contains("\(manifest.rows[0].layer)@\(manifest.rows[0].scale): 2 rows"))
        #expect(problems.count == 3)
    }

    @Test func aStateOutsidePendingAndEnforcedDoesNotDecode() {
        let json = #"{"schema":1,"rows":[{"layer":"L6","scale":1.6,"state":"skipped","owner":"WOR-318"}]}"#
        #expect(throws: DecodingError.self) { try LayerManifest.decode(Data(json.utf8)) }
    }
}
