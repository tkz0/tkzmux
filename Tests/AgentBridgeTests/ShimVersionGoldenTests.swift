// Pins `ShimInstaller.version`'s digest (WOR-304 S4). The installer rewrites every shim and
// wrapper when VERSION differs, so a hasher whose output moved would force a reinstall on the
// next launch; this must pass unchanged across the switch from CryptoKit's SHA256 to TkzPlatform's.
//
// The goldens are SHA-256 over the exact bytes `version` feeds its hasher (sorted shim names and
// contents, each wrapper's installed path and content in `LoginShell.allWrapperFiles` order, then
// "<size>:<mtime>" of the hook binary when it exists), computed outside Swift with Python's
// hashlib, so they do not come from either implementation under test.

import Foundation
import Testing

@testable import AgentBridge

@Suite struct ShimVersionGoldenTests {
    static let resources = ShimResources(
        shimScripts: [
            "codex": "#!/bin/sh\nexec \"$TKZMUX_REAL_CODEX\" \"$@\"\n",
            "claude": "#!/bin/sh\n# claude shim — golden\nexec \"$TKZMUX_REAL_CLAUDE\" \"$@\"\n",
        ],
        wrappers: [
            "zsh/.zshenv": "export TKZMUX_GOLDEN=1\n",
            "zsh/.zprofile": "",
            "zsh/.zshrc": "# rc …\n",
            "zsh/.zlogin": "true",
            "bash/tkzmux.bashrc": "source ~/.bashrc\n",
            // fish/tkzmux.fish missing: hashed as its path and an empty string.
        ])

    @Test func versionWithoutAHookBinary() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkzmux-golden-\(UUID().uuidString)/tkzmux-hook")
        #expect(ShimInstaller.version(resources: Self.resources, hookBinary: missing)
            == "bb850765dd573f9e9b192f6d611137b5cdae23baa6c7bb82405b0c9289ea46f1")
    }

    @Test func versionWithAHookBinary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkzmux-golden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = directory.appendingPathComponent("tkzmux-hook")
        try Data("golden hook binary".utf8).write(to: hook)  // 18 bytes
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: hook.path)
        // Hashes "18:1700000000.0" after the resources.
        #expect(ShimInstaller.version(resources: Self.resources, hookBinary: hook)
            == "99037a02facc3a2075c37836d01060d1ebd4bc2c4438e9f1ebf3efce7ce8dc02")
    }
}
