// ParityThresholds against ADR-0003, which is normative: every constant is named there, every
// constant the ADR names exists here, and every value the ADR spells out is the value here. Plus
// the combined reference budget of ADR-0003 §5, measured on the committed trees.

import Foundation
import Testing
@testable import TkzParity

@Suite struct ParityThresholdTests {
    static var adrURL: URL { TestImages.repoRoot.appending(path: "docs/linux/adr-0003-parity.md") }

    /// The constants the ADR names in backticks, with the value when it writes `name = value`.
    static func adrConstants() throws -> [String: Double?] {
        let text = try String(contentsOf: adrURL, encoding: .utf8)
        var found: [String: Double?] = [:]
        for match in text.matches(of: #/`(l[0-6][A-Za-z]+|[a-z][A-Za-z]*Bytes)(?: = ([0-9.]+))?`/#) {
            let name = String(match.1)
            let value = match.2.flatMap { Double($0) }
            if let existing = found[name], let existing, let value, existing != value {
                Issue.record("ADR-0003 gives \(name) two values: \(existing) and \(value)")
            }
            if found[name] == nil || value != nil { found[name] = value }
        }
        return found
    }

    @Test func everyThresholdIsNamedInTheADR() throws {
        let adr = try Self.adrConstants()
        for (name, _) in ParityThresholds.all {
            #expect(adr.keys.contains(name), "\(name) is not in ADR-0003: amend the ADR in the same PR")
        }
    }

    @Test func everyConstantTheADRNamesExists() throws {
        let names = Set(ParityThresholds.all.map(\.name))
        for name in try Self.adrConstants().keys.sorted() {
            #expect(names.contains(name), "ADR-0003 names \(name), ParityThresholds has no such constant")
        }
        #expect(names.count == ParityThresholds.all.count, "a constant is listed twice")
    }

    @Test func theValuesAreTheADRs() throws {
        let adr = try Self.adrConstants()
        for (name, value) in ParityThresholds.all {
            guard case let adrValue?? = adr[name] else { continue }
            #expect(value == .number(adrValue), "\(name): ADR-0003 says \(adrValue), ParityThresholds \(value)")
        }
        // The values the ADR writes in prose rather than as `name = value`.
        #expect(ParityThresholds.l1Exact && ParityThresholds.l2Exact && ParityThresholds.l0Exact)
        #expect(ParityThresholds.referenceBudgetBytes == 9_437_184)
        #expect(try String(contentsOf: Self.adrURL, encoding: .utf8).contains("9 MiB (9,437,184 bytes)"))
        #expect(ParityThresholds.componentSnapshotShareBytes == 4 * 1024 * 1024)
        #expect(ParityThresholds.parityReferenceShareBytes == 5 * 1024 * 1024)
        #expect(ParityThresholds.componentSnapshotShareBytes + ParityThresholds.parityReferenceShareBytes
                == ParityThresholds.referenceBudgetBytes)
    }

    /// `all` is what the ADR checks see, so every constant declared in ParityThresholds.swift must
    /// be in it: a threshold added without a row in `all` would escape the cross-check.
    @Test func everyDeclaredConstantIsListed() throws {
        let source = TestImages.repoRoot.appending(path: "Sources/TkzParity/ParityThresholds.swift")
        // The enum alone: `ParityGate`'s static gates (`l4Glyph`, `l6Window`) follow it.
        let file = try String(contentsOf: source, encoding: .utf8)
        let text = try #require(file.split(separator: "public struct ParityGate").first)
        let declared = text.matches(of: #/\n    public static let (l[0-6][A-Za-z]+|[a-z][A-Za-z]*Bytes) = /#)
            .map { String($0.1) }
        #expect(declared.count == ParityThresholds.all.count)
        #expect(Set(declared) == Set(ParityThresholds.all.map(\.name)))
    }

    /// The check above only means something if it sees a name the ADR lacks.
    @Test func theCrossCheckWouldCatchAMissingName() throws {
        let adr = try Self.adrConstants()
        #expect(adr["l5ComponentMinSSIM"] == .some(0.95))
        #expect(adr["l0Exact"] == .some(nil))
        #expect(adr["l7Imaginary"] == nil)
        #expect(adr.count == ParityThresholds.all.count)
    }

    /// ADR-0003 §5: one combined budget for every committed reference, and each tree within its
    /// share. Every regular file counts, manifests included: they are committed bytes too. A tree
    /// that does not exist yet counts as empty.
    @Test func theReferenceTreesFitTheBudget() throws {
        func bytes(under path: String) throws -> Int {
            let root = TestImages.repoRoot.appending(path: path)
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
            var total = 0
            for case let url as URL in walker {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { total += values.fileSize ?? 0 }
            }
            return total
        }
        let components = try bytes(under: "Tests/TkzAppTests/ComponentSnapshots")
        let references = try bytes(under: "Tests/Parity/References")
        print("parity reference budget: ComponentSnapshots \(components) B, Parity/References \(references) B, "
              + "total \(components + references) of \(ParityThresholds.referenceBudgetBytes) B")
        #expect(components <= ParityThresholds.componentSnapshotShareBytes,
                "ComponentSnapshots is \(components) B, over WOR-307's share: renegotiate in ADR-0003")
        #expect(references <= ParityThresholds.parityReferenceShareBytes,
                "Tests/Parity/References is \(references) B, over WOR-322's share: renegotiate in ADR-0003")
        #expect(components + references <= ParityThresholds.referenceBudgetBytes)
    }
}
