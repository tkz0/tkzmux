// ResourceLocatorTests — the candidate order, both bundle extensions, both terminfo layouts and a
// symlinked launcher. Every test injects the platform, so the Linux order is checked on the Mac and
// the Mac order on Linux, against real directories in a temporary tree.
import Foundation
import Testing

@testable import TkzCore

@Suite struct ResourceLocatorTests {
    /// A fresh temporary directory, symlinks resolved so paths compare equal on the Mac
    /// (`/var` → `/private/var`).
    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tkz-resources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func makeFile(_ url: URL) throws {
        try makeDirectory(url.deletingLastPathComponent())
        try Data().write(to: url)
    }

    /// Paths with symlinks resolved, for comparing what the locator derives with what a test built.
    /// Both sides go through it, and every compared directory exists, because on the Mac
    /// `resolvingSymlinksInPath` drops a `/private` prefix only for a path that exists.
    static func paths(_ urls: [URL]) -> [String] {
        urls.map { $0.resolvingSymlinksInPath().path }
    }

    static func linux(executable: URL?, environment: [String: String] = [:], main: URL? = nil) -> ResourceLocator {
        ResourceLocator(
            platform: .linux, executablePath: executable?.path, environment: environment, mainResourceURL: main)
    }

    /// The repo root, located from this file rather than the working directory.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/TkzCoreTests/ResourceLocatorTests.swift
            .deletingLastPathComponent()          // Tests/TkzCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // <repo>
    }

    // MARK: Candidates

    /// macOS is exactly the pre-locator lookup: `Bundle.main.resourceURL` and `.bundle`, nothing
    /// else, whatever the environment says.
    @Test func macOSProbesOnlyTheMainResourceURL() {
        let main = URL(fileURLWithPath: "/Applications/tkzmux.app/Contents/Resources", isDirectory: true)
        let locator = ResourceLocator(
            platform: .macOS, executablePath: "/Applications/tkzmux.app/Contents/MacOS/tkzmux",
            environment: [ResourceLocator.resourceDirectoryVariable: "/somewhere"], mainResourceURL: main)
        #expect(locator.candidateDirectories == [main])
        #expect(locator.bundleExtensions == ["bundle"])
        #expect(locator.installDirectory == nil)

        let noMain = ResourceLocator(platform: .macOS, executablePath: nil, environment: [:], mainResourceURL: nil)
        #expect(noMain.candidateDirectories.isEmpty)
        #expect(noMain.bundleURL(forModule: "TkzTerminalCore") == nil)
    }

    @Test func linuxOrderIsOverrideInstallExecutableMain() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "prefix/bin/tkzmux")
        try Self.makeFile(executable)
        let expected = ["override", "prefix/lib/tkzmux", "prefix/bin", "main"].map { root.appending(path: $0) }
        for directory in expected { try Self.makeDirectory(directory) }

        let locator = Self.linux(
            executable: executable,
            environment: [ResourceLocator.resourceDirectoryVariable: expected[0].path],
            main: expected[3])
        #expect(locator.bundleExtensions == ["resources", "bundle"])
        #expect(Self.paths(locator.candidateDirectories) == Self.paths(expected))
    }

    /// An empty override is ignored, and `Bundle.main.resourceURL` (the executable's directory on
    /// Linux) is not listed twice.
    @Test func linuxSkipsEmptyOverrideAndDuplicates() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "prefix/bin/tkzmux")
        try Self.makeFile(executable)
        let expected = ["prefix/lib/tkzmux", "prefix/bin"].map { root.appending(path: $0) }
        for directory in expected { try Self.makeDirectory(directory) }

        let locator = Self.linux(
            executable: executable,
            environment: [ResourceLocator.resourceDirectoryVariable: ""],
            main: root.appending(path: "prefix/bin", directoryHint: .isDirectory))
        #expect(Self.paths(locator.candidateDirectories) == Self.paths(expected))

        let bare = Self.linux(executable: nil)
        #expect(bare.candidateDirectories.isEmpty)
        #expect(bare.installDirectory == nil)
    }

    // MARK: Bundles

    /// Within one directory `.resources` (native) wins over `.bundle` (Swift Build); an earlier
    /// directory wins over a later one whatever its extension.
    @Test func linuxProbesBothExtensionsPerDirectory() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "prefix/bin/tkzmux")
        try Self.makeFile(executable)
        let install = root.appending(path: "prefix/lib/tkzmux")
        let binDir = root.appending(path: "prefix/bin")
        let locator = Self.linux(executable: executable)

        #expect(locator.bundleURL(forModule: "AgentBridge") == nil)

        try Self.makeDirectory(binDir.appending(path: "tkzmux_AgentBridge.bundle"))
        #expect(Self.paths([try #require(locator.bundleURL(forModule: "AgentBridge"))])
            == Self.paths([binDir.appending(path: "tkzmux_AgentBridge.bundle")]))

        try Self.makeDirectory(binDir.appending(path: "tkzmux_AgentBridge.resources"))
        #expect(Self.paths([try #require(locator.bundleURL(forModule: "AgentBridge"))])
            == Self.paths([binDir.appending(path: "tkzmux_AgentBridge.resources")]))

        try Self.makeDirectory(install.appending(path: "tkzmux_AgentBridge.bundle"))
        #expect(Self.paths([try #require(locator.bundleURL(forModule: "AgentBridge"))])
            == Self.paths([install.appending(path: "tkzmux_AgentBridge.bundle")]))

        // A file with the bundle's name is not a bundle, and other modules are not matched.
        try Self.makeFile(install.appending(path: "tkzmux_TkzTerminalRender.resources"))
        #expect(locator.bundleURL(forModule: "TkzTerminalRender") == nil)
        #expect(locator.bundleURL(forModule: "TkzTerminalCore") == nil)
    }

    @Test func macOSIgnoresResourcesExtension() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeDirectory(root.appending(path: "tkzmux_TkzTerminalCore.resources"))
        let locator = ResourceLocator(platform: .macOS, executablePath: nil, environment: [:], mainResourceURL: root)
        #expect(locator.bundleURL(forModule: "TkzTerminalCore") == nil)

        try Self.makeDirectory(root.appending(path: "tkzmux_TkzTerminalCore.bundle"))
        #expect(locator.bundleURL(forModule: "TkzTerminalCore")?.lastPathComponent == "tkzmux_TkzTerminalCore.bundle")
    }

    @Test func overrideWinsOverTheInstall() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "prefix/bin/tkzmux")
        try Self.makeFile(executable)
        try Self.makeDirectory(root.appending(path: "prefix/lib/tkzmux/tkzmux_TkzTerminalCore.resources"))
        try Self.makeDirectory(root.appending(path: "override/tkzmux_TkzTerminalCore.bundle"))

        let locator = Self.linux(
            executable: executable,
            environment: [ResourceLocator.resourceDirectoryVariable: root.appending(path: "override").path])
        #expect(Self.paths([try #require(locator.bundleURL(forModule: "TkzTerminalCore"))])
            == Self.paths([root.appending(path: "override/tkzmux_TkzTerminalCore.bundle")]))
    }

    // MARK: Symlinked launcher

    /// `~/.local/bin/tkzmux` → `/opt/bin/tkzmux` finds `/opt/lib/tkzmux`, not `~/.local/lib/tkzmux`:
    /// the install directory comes from the resolved executable, as `/proc/self/exe` gives it.
    @Test(arguments: [false, true])
    func symlinkedLauncherResolvesToTheInstall(relative: Bool) throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "opt/bin/tkzmux")
        try Self.makeFile(target)
        let install = root.appending(path: "opt/lib/tkzmux")
        try Self.makeDirectory(install.appending(path: "tkzmux_TkzTerminalCore.resources"))
        let launcher = root.appending(path: "home/.local/bin/tkzmux")
        try Self.makeDirectory(launcher.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(
            atPath: launcher.path, withDestinationPath: relative ? "../../../opt/bin/tkzmux" : target.path)

        let locator = Self.linux(executable: launcher)
        #expect(Self.paths([try #require(locator.installDirectory)]) == Self.paths([install]))
        #expect(Self.paths(locator.candidateDirectories) == Self.paths([install, root.appending(path: "opt/bin")]))
        #expect(Self.paths([try #require(locator.bundleURL(forModule: "TkzTerminalCore"))])
            == Self.paths([install.appending(path: "tkzmux_TkzTerminalCore.resources")]))
    }

    // MARK: Terminfo

    @Test(arguments: ["78/xterm-ghostty", "x/xterm-ghostty"])
    func terminfoAcceptsEitherLayout(entry: String) throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root.appending(path: "terminfo/\(entry)"))
        #expect(Self.paths([try #require(ResourceLocator.terminfoDirectory(in: root))])
            == Self.paths([root.appending(path: "terminfo")]))
    }

    @Test func terminfoRejectsOtherContents() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ResourceLocator.terminfoDirectory(in: root) == nil)
        try Self.makeFile(root.appending(path: "terminfo/g/ghostty"))
        #expect(ResourceLocator.terminfoDirectory(in: root) == nil)

        let file = root.appending(path: "flat")
        try Self.makeFile(file.appending(path: "terminfo"))
        #expect(ResourceLocator.terminfoDirectory(in: file) == nil)
    }

    /// The committed database carries both layouts.
    @Test func committedTerminfoIsFound() throws {
        let resources = Self.repoRoot.appending(path: "Sources/TkzTerminalCore/Resources")
        let terminfo = try #require(ResourceLocator.terminfoDirectory(in: resources))
        for entry in ResourceLocator.terminfoEntries {
            #expect(FileManager.default.fileExists(atPath: terminfo.appending(path: entry).path), "\(entry)")
        }
    }

    /// Linux ncurses reads the letter layout from the located directory. The assertion is on the
    /// file infocmp reports, so a system-wide xterm-ghostty cannot mask a miss.
    @Test(.enabled(if: ResourceLocator.Platform.current == .linux
                   && FileManager.default.isExecutableFile(atPath: "/usr/bin/infocmp")))
    func linuxNcursesReadsTheLocatedTerminfo() throws {
        let resources = Self.repoRoot.appending(path: "Sources/TkzTerminalCore/Resources")
        let terminfo = try #require(ResourceLocator.terminfoDirectory(in: resources))
        let home = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: home) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
        process.arguments = ["xterm-ghostty"]
        process.environment = ["TERMINFO": terminfo.path, "HOME": home.path, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "\(text)")
        // `#	Reconstructed via infocmp from file: <TERMINFO>/./x/xterm-ghostty` on ncurses 6.
        let source = text.split(separator: "\n").first { $0.contains("from file: ") }
            .map { String($0.split(separator: "from file: ", maxSplits: 1).last ?? "") }
        #expect(source?.hasPrefix(terminfo.path + "/") == true, "\(text.prefix(200))")
        #expect(source?.hasSuffix("/x/xterm-ghostty") == true, "\(text.prefix(200))")
    }
}
