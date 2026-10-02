// AbiCommand — `tkzmux-vtdump abi` and `tkzmux-vtdump version`.
//
//   abi       the libghostty-vt ABI manifest (ghostty_type_json) as sorted, pretty JSON
//   version   ghostty_build_info: library version, build options and the vendored commit
//
// Self-contained on purpose: it imports only Foundation and GhosttyVt and calls the C API
// directly, with no TkzTerminalCore, Metal or `#filePath`. scripts/build-ghostty-vt-linux.sh
// copies this file into a throwaway probe package next to a copy of the Linux artifact bundle and
// writes vendor/ghostty-vt/abi-types.x86_64-linux-gnu.json from it; the macOS manifest
// (abi-types.aarch64-macos.json) comes from the same code inside tkzmux-vtdump.

import Foundation
import GhosttyVt

enum AbiCommand {
    /// The raw `ghostty_type_json()` document, as the library returns it.
    static var rawManifest: String { String(cString: ghostty_type_json()) }

    /// The manifest re-serialised with sorted keys and pretty-printed, as committed under
    /// vendor/ghostty-vt/. Nil when the library's document is not valid JSON.
    static func prettyManifest() -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(rawManifest.utf8)),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    /// One line: version, build options and, when `commitFile` names a readable non-empty file
    /// (vendor/ghostty-vt/COMMIT), the vendored commit.
    static func versionLine(commitFile: URL?) -> String {
        var line = "libghostty-vt \(buildString(GHOSTTY_BUILD_INFO_VERSION_STRING))"
            + "  simd=\(buildBool(GHOSTTY_BUILD_INFO_SIMD))"
            + " kitty-graphics=\(buildBool(GHOSTTY_BUILD_INFO_KITTY_GRAPHICS))"
            + " tmux-control-mode=\(buildBool(GHOSTTY_BUILD_INFO_TMUX_CONTROL_MODE))"
            + " optimize=\(optimizeName)"
        if let commitFile, let commit = vendoredCommit(at: commitFile) { line += "  commit=\(commit)" }
        return line
    }

    /// The trimmed contents of a COMMIT file, or nil when it is missing or empty.
    static func vendoredCommit(at file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let commit = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    private static var optimizeName: String {
        var mode = GHOSTTY_OPTIMIZE_DEBUG
        _ = ghostty_build_info(GHOSTTY_BUILD_INFO_OPTIMIZE, &mode)
        switch mode {
        case GHOSTTY_OPTIMIZE_DEBUG: return "Debug"
        case GHOSTTY_OPTIMIZE_RELEASE_SAFE: return "ReleaseSafe"
        case GHOSTTY_OPTIMIZE_RELEASE_SMALL: return "ReleaseSmall"
        case GHOSTTY_OPTIMIZE_RELEASE_FAST: return "ReleaseFast"
        default: return "unknown(\(mode.rawValue))"
        }
    }

    private static func buildBool(_ key: GhosttyBuildInfo) -> Bool {
        var value = false
        _ = ghostty_build_info(key, &value)
        return value
    }

    private static func buildString(_ key: GhosttyBuildInfo) -> String {
        var value = GhosttyString()
        _ = ghostty_build_info(key, &value)
        guard let ptr = value.ptr, value.len > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
    }
}
