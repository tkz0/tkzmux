// Tests/Parity/References/manifest.json, the Mac reference set's manifest (WOR-322 S2; ADR-0003
// §5): the machine it records, and the files it lists matching the tree byte for byte. Every file
// under Tests/Parity/References/ is listed with its sha256, and so is every WOR-307 golden in
// Tests/TkzAppTests/ComponentSnapshots/ (listed, never copied). The trees' own manifest.json files
// are not: each carries a provenance block that a rerun changes, and lists the same files. So a reference or a golden that
// changes without `make parity-references` fails here, on both OSes, until the set is regenerated
// on the reference runner (docs/linux/parity.md, "Regenerating the references").
//
// Found through `#filePath` (TestImages.repoRoot), not `.copy` resources. Until the exporter's
// first set is committed there is no manifest, and the suite does not run.

import Foundation
import Testing
import TkzPlatform
import TkzPNG

private let referencesURL = TestImages.repoRoot.appending(path: "Tests/Parity/References")
private let referenceManifestURL = referencesURL.appending(path: "manifest.json")

@Suite(.enabled(if: FileManager.default.fileExists(atPath: referenceManifestURL.path)))
struct ReferenceManifestTests {
    static var references: URL { referencesURL }
    static var manifestURL: URL { referenceManifestURL }
    static let goldensPath = "Tests/TkzAppTests/ComponentSnapshots"

    struct Manifest: Decodable {
        var schema: Int
        var reference: [String: String]
        var scales: [Double]
        var commands: [String]
        var skipped: [String]
        var files: [String: String]
        var componentSnapshots: [String: String]
        var provenance: [String: String]
    }

    static func committed() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    }

    /// Every regular file under `root`, as paths relative to it, but the manifests and `excluding`.
    static func files(under root: URL, excluding: Set<String>) throws -> Set<String> {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var paths: Set<String> = []
        while let path = walker.nextObject() as? String {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.appending(path: path).path, isDirectory: &isDirectory),
                  !isDirectory.boolValue, !excluding.contains(path),
                  (path as NSString).lastPathComponent != "manifest.json" else { continue }
            paths.insert(path)
        }
        return paths
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).description
    }

    /// The fields WOR-312's font manifest defined, the runner image first, and a provenance block
    /// apart from them.
    @Test func itRecordsTheReferenceMachine() throws {
        let manifest = try Self.committed()
        #expect(manifest.schema == 1)
        for key in ["ImageOS", "ImageVersion", "macOSBuild", "macOSVersion", "xcode", "swift", "hwModel",
                    "coreTextVersion", "AppleFontSmoothing", "displayProfile"] {
            let value = manifest.reference[key] ?? ""
            #expect(!value.isEmpty && value != "unknown", "reference.\(key) is \(value.isEmpty ? "missing" : value)")
        }
        #expect(manifest.reference["ImageOS"]?.hasPrefix("macos") == true, "not from a hosted macOS runner")
        #expect(Set(manifest.provenance.keys) == ["commit", "run"])
        #expect(manifest.scales == [1.6, 2.0])
    }

    /// No user or host names (ADR-0003 §5): the manifest names the runner image, never a machine.
    @Test func itHoldsNoPathsOrHostNames() throws {
        let text = try String(contentsOf: Self.manifestURL, encoding: .utf8)
        for needle in ["/Users/", "/home/", "/private/", "/var/folders/", ".local\"", "runner@"] {
            #expect(!text.contains(needle), "the manifest contains \(needle)")
        }
    }

    @Test func itListsEveryReferenceWithItsHash() throws {
        let manifest = try Self.committed()
        let onDisk = try Self.files(under: Self.references, excluding: [])
        #expect(Set(manifest.files.keys) == onDisk, """
            Tests/Parity/References/ and its manifest disagree: not listed \
            \(onDisk.subtracting(manifest.files.keys).sorted()), missing \
            \(Set(manifest.files.keys).subtracting(onDisk).sorted()). Rerun make parity-references
            """)
        for (path, hash) in manifest.files.sorted(by: { $0.key < $1.key }) where onDisk.contains(path) {
            #expect(try Self.sha256(Self.references.appending(path: path)) == hash,
                    "Tests/Parity/References/\(path) is not the file the manifest lists")
        }
    }

    /// WOR-307's goldens are the L5 and L0-component references: listed by path and hash, never
    /// copied into Tests/Parity/References/.
    @Test func itListsTheComponentGoldensWithoutCopyingThem() throws {
        let manifest = try Self.committed()
        let root = TestImages.repoRoot.appending(path: Self.goldensPath)
        let onDisk = Set(try Self.files(under: root, excluding: ["README.md"]).map { "\(Self.goldensPath)/\($0)" })
        #expect(Set(manifest.componentSnapshots.keys) == onDisk, """
            \(Self.goldensPath) and the parity manifest disagree: not listed \
            \(onDisk.subtracting(manifest.componentSnapshots.keys).sorted().prefix(10)), missing \
            \(Set(manifest.componentSnapshots.keys).subtracting(onDisk).sorted().prefix(10)). \
            Rerun make parity-references after the goldens change
            """)
        for (path, hash) in manifest.componentSnapshots.sorted(by: { $0.key < $1.key }) where onDisk.contains(path) {
            #expect(try Self.sha256(TestImages.repoRoot.appending(path: path)) == hash,
                    "\(path) is not the golden the parity manifest lists")
        }
        let goldenHashes = Set(manifest.componentSnapshots.values)
        let copies = manifest.files.filter { goldenHashes.contains($0.value) && $0.key.hasSuffix(".png") }
        #expect(copies.isEmpty, "golden copies under Tests/Parity/References: \(copies.keys.sorted())")
    }

    /// The terminal frames: every recording at both scales, each a PNG that decodes.
    @Test func theTerminalFramesCoverEveryRecordingAtBothScales() throws {
        let manifest = try Self.committed()
        let names = ["golden-screen", "claude-boot", "claude-tool-run", "synthetic-basic", "zsh-ls-color", "glyph-sheet"]
        for name in names {
            for scale in ["1.6", "2.0"] {
                let path = "terminal/\(name)@\(scale).png"
                guard manifest.files[path] != nil else {
                    Issue.record("the manifest lists no \(path)")
                    continue
                }
                let image = try PNG.decode([UInt8](try Data(contentsOf: Self.references.appending(path: path))))
                #expect(image.width > 0 && image.height > 0)
            }
        }
    }
}
