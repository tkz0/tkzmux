// tkzmux-vtdump — headless VT tooling. `abi` and `version` (M1.1 / TKZ-7); record / replay / render
// arrive in M1.3 (TKZ-9). See docs/design.md → Testing without UI.
import Foundation
import TkzTerminalCore

let usage = """
usage: tkzmux-vtdump <command>
  abi       print the libghostty-vt ABI manifest (ghostty_type_json) as sorted, pretty JSON
  version   print the vendored libghostty-vt version and build options
  record | replay | render   not implemented yet (M1.3 / TKZ-9)
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// `vendor/ghostty-vt/COMMIT` relative to this source file (a dev tool; the repo path is compile-time).
func vendoredCommit() -> String? {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let file = repoRoot.appending(path: "vendor/ghostty-vt/COMMIT")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    let commit = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return commit.isEmpty ? nil : commit
}

switch CommandLine.arguments.dropFirst().first {
case "abi":
    let raw = GhosttyVtInfo.abiManifestJSON
    guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
          let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: pretty, encoding: .utf8)
    else {
        print(raw)
        fail("tkzmux-vtdump: ghostty_type_json() is not valid JSON", code: 1)
    }
    print(text)

case "version":
    var line = "libghostty-vt \(GhosttyVtInfo.versionString)"
        + "  simd=\(GhosttyVtInfo.simd)"
        + " kitty-graphics=\(GhosttyVtInfo.kittyGraphics)"
        + " tmux-control-mode=\(GhosttyVtInfo.tmuxControlMode)"
        + " optimize=\(GhosttyVtInfo.optimizeName)"
    if let commit = vendoredCommit() { line += "  commit=\(commit)" }
    print(line)

case "record", "replay", "render":
    fail("tkzmux-vtdump: not implemented yet (M1.3 / TKZ-9)", code: 2)

default:
    fail(usage, code: 2)
}
