// ShimInstallerPrefixTests — the installer run the way an installed Linux tkzmux runs it
// (WOR-306 S3): from a copied `<prefix>` holding `bin/tkzmux`, `bin/tkzmux-hook` and
// `lib/tkzmux/tkzmux_AgentBridge.resources`, with a temporary `HOME` and `XDG_DATA_HOME`.
//
// The locator is built from the prefix alone: no `TKZMUX_RESOURCE_DIR`, no main resource URL, and
// `ShimResources.bundled(locator:)` has no `Bundle.module` fallback, so nothing is read from
// `.build` — the in-process equivalent of deleting it, which a running `swift test` cannot do.
// Each run checks that the user data lands in `$XDG_DATA_HOME/tkzmux` and that the prefix is left
// byte-for-byte, mode-for-mode and mtime-for-mtime as it was, including with `PREFIX=$HOME/.local`,
// where the install and the default user data share one `~/.local` (ADR-0002).

#if os(Linux)
import Foundation
import Testing
import TkzCore
import TkzPlatform

@testable import AgentBridge

@Suite(.serialized)
struct ShimInstallerPrefixTests {
    /// One file of a tree: what an installer could have changed about it.
    struct Entry: Equatable {
        var contents: Data?
        var mode: Int
        var modified: Date
        var isSymlink: Bool
    }

    /// Every path under `root`, relative, with its contents (regular files only), mode and mtime.
    static func snapshot(_ root: URL) throws -> [String: Entry] {
        let fm = FileManager.default
        var entries: [String: Entry] = [:]
        for relative in try fm.subpathsOfDirectory(atPath: root.path) {
            let path = root.appendingPathComponent(relative).path
            let attributes = try fm.attributesOfItem(atPath: path)
            let type = attributes[.type] as? FileAttributeType
            entries[relative] = Entry(
                contents: type == .typeRegular ? fm.contents(atPath: path) : nil,
                mode: (attributes[.posixPermissions] as? Int) ?? -1,
                modified: (attributes[.modificationDate] as? Date) ?? .distantPast,
                isSymlink: type == .typeSymbolicLink)
        }
        return entries
    }

    /// The layout under test: where the prefix goes, and whether `XDG_DATA_HOME` is set.
    enum Layout: String, CaseIterable {
        /// `<root>/opt` with `XDG_DATA_HOME=<root>/data`.
        case separatePrefix
        /// `PREFIX=$HOME/.local` and no `XDG_DATA_HOME`, so user data is `~/.local/share/tkzmux`
        /// beside the install's `~/.local/lib/tkzmux`.
        case homeLocalPrefix
    }

    @Test(arguments: Layout.allCases)
    func installsIntoXDGDataHomeAndLeavesThePrefixAlone(layout: Layout) throws {
        let fm = FileManager.default
        let root = try ShimTestSupport.makeTempDirectory("prefix")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let prefix: URL
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let expectedSupport: URL
        switch layout {
        case .separatePrefix:
            prefix = root.appendingPathComponent("opt", isDirectory: true)
            environment["XDG_DATA_HOME"] = root.appendingPathComponent("data").path
            expectedSupport = root.appendingPathComponent("data/tkzmux", isDirectory: true)
        case .homeLocalPrefix:
            prefix = home.appendingPathComponent(".local", isDirectory: true)
            expectedSupport = home.appendingPathComponent(".local/share/tkzmux", isDirectory: true)
        }

        // The prefix: the built hook and AgentBridge bundle copied out of `.build`, and a stand-in
        // `bin/tkzmux` (the locator only needs its path). A `~/bin/tkzmux` symlink to it is the
        // executable, as a user's PATH link would be.
        let bin = prefix.appendingPathComponent("bin", isDirectory: true)
        let install = prefix.appendingPathComponent(ResourceLocator.installDirectoryPath, isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: install, withIntermediateDirectories: true)
        let builtBundle = ModuleResources.bundle.bundleURL
        let builtHook = builtBundle.deletingLastPathComponent().appendingPathComponent("tkzmux-hook")
        try #require(fm.isExecutableFile(atPath: builtHook.path), "the build's tkzmux-hook")
        try fm.copyItem(at: builtHook, to: bin.appendingPathComponent("tkzmux-hook"))
        try fm.copyItem(
            at: builtBundle,
            to: install.appendingPathComponent("\(ResourceLocator.bundlePrefix)AgentBridge.resources"))
        try ShimTestSupport.writeExecutable("#!/bin/sh\nexit 0\n", to: bin.appendingPathComponent("tkzmux"))
        let link = home.appendingPathComponent("bin/tkzmux")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: bin.appendingPathComponent("tkzmux"))
        let before = try Self.snapshot(prefix)

        let locator = ResourceLocator(
            platform: .linux, executablePath: link.path, environment: environment, mainResourceURL: nil)
        #expect(!locator.candidateDirectories.contains { $0.path.contains("/.build/") })
        let installer = try ShimInstaller.standard(locator: locator)
        #expect(installer.directory.standardizedFileURL.path == expectedSupport.path)
        #expect(installer.hookBinary.path == bin.appendingPathComponent("tkzmux-hook").path)

        #expect(try installer.ensureInstalled() == .installed)
        #expect(try installer.ensureInstalled() == .upToDate)

        // The user data: every shim, the hook, every wrapper and VERSION.
        let support = expectedSupport
        for name in ["agy", "claude", "codex", "tkzmux-hook"] {
            #expect(fm.isExecutableFile(atPath: support.appendingPathComponent("bin/\(name)").path), "bin/\(name)")
        }
        for file in LoginShell.allWrapperFiles {
            #expect(fm.fileExists(atPath: file.url(in: support).path), "\(file.installedPath)")
        }
        #expect(fm.fileExists(atPath: support.appendingPathComponent("VERSION").path))
        #expect(fm.contents(atPath: support.appendingPathComponent("bin/tkzmux-hook").path)
            == fm.contents(atPath: builtHook.path))

        // The install is untouched: no file added, removed or rewritten, no mode or mtime moved.
        let after = try Self.snapshot(prefix)
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
            .filter { layout != .homeLocalPrefix || !$0.hasPrefix("share") }
        #expect(changed.isEmpty, "changed under the prefix: \(changed.sorted())")
        #expect(!fm.fileExists(atPath: install.appendingPathComponent("bin").path))
        #expect(!fm.fileExists(atPath: install.appendingPathComponent("VERSION").path))
    }

    /// Without a bundle in the prefix there is nothing to fall back to: the build tree is never
    /// consulted.
    @Test func aPrefixWithoutResourcesIsAnErrorNotTheBuildTree() throws {
        let root = try ShimTestSupport.makeTempDirectory("prefix-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = ResourceLocator(
            platform: .linux, executablePath: root.appendingPathComponent("bin/tkzmux").path,
            environment: ["HOME": root.path], mainResourceURL: nil)
        #expect(throws: ShimInstallerError.self) { try ShimResources.bundled(locator: locator) }
        #expect(throws: ShimInstallerError.self) { try ShimInstaller.standard(locator: locator) }
    }

    /// The hook beside a symlinked executable is the install's, not the link directory's.
    @Test func hookBinaryFollowsTheExecutableSymlink() throws {
        let fm = FileManager.default
        let root = try ShimTestSupport.makeTempDirectory("prefix-link")
        defer { try? fm.removeItem(at: root) }
        let bin = root.appendingPathComponent("opt/bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try ShimTestSupport.writeExecutable("#!/bin/sh\n", to: bin.appendingPathComponent("tkzmux"))
        let link = root.appendingPathComponent("tkzmux")
        try fm.createSymbolicLink(at: link, withDestinationURL: bin.appendingPathComponent("tkzmux"))
        let locator = ResourceLocator(
            platform: .linux, executablePath: link.path, environment: [:], mainResourceURL: nil)
        #expect(ShimInstaller.hookBinary(locator: locator)?.path
            == bin.appendingPathComponent("tkzmux-hook").resolvingSymlinksInPath().path)
    }
}
#endif
