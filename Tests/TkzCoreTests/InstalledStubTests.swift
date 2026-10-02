// InstalledStubTests — WOR-303 S4. The Linux `tkzmux` copied into a relocated `<prefix>/bin`, with
// a generated `<prefix>/lib/tkzmux/version.plist` and dummy resource bundles beside it, reports the
// stamped version and resolves every bundle from that tree, never from `.build`. It has to be the
// real process: the lookup starts at `/proc/self/exe`.
//
// The binary is `$TKZMUX_TEST_STUB` when set (CI points it at the release build), else the debug
// `tkzmux` that `swift test` builds next to the test runner.
import Foundation
import Testing

@testable import TkzCore

@Suite(.enabled(if: ResourceLocator.Platform.current == .linux))
struct InstalledStubTests {
    static let stubVariable = "TKZMUX_TEST_STUB"

    static func stub() throws -> URL {
        if let path = ProcessInfo.processInfo.environment[stubVariable], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let runner = try #require(ResourceLocator.procSelfExe(), "no /proc/self/exe")
        return URL(fileURLWithPath: runner).deletingLastPathComponent().appending(path: "tkzmux")
    }

    /// Runs the installed copy with no `TKZMUX_RESOURCE_DIR`, from inside the temporary tree, so
    /// nothing on the lookup path points into the repo or `.build`.
    static func runInstalled(_ executable: URL, _ argument: String, root: URL) throws -> ScriptSupport.Output {
        try ScriptSupport.run(
            executable, [argument], environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root)
    }

    @Test func relocatedInstallReportsItsVersionAndResolvesEveryBundle() throws {
        let stub = try Self.stub()
        try #require(FileManager.default.isExecutableFile(atPath: stub.path),
                     "no tkzmux at \(stub.path): build it, or set \(Self.stubVariable)")

        let root = try ScriptSupport.makeTemporaryDirectory("tkz-installed")
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appending(path: "bin/tkzmux")
        let install = root.appending(path: "lib/tkzmux")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: stub, to: binary)

        // Before the install: the visible dev fallback, and no bundle anywhere.
        let bare = try Self.runInstalled(binary, "--version", root: root)
        #expect(bare.status == 0, "\(bare.stderr)")
        #expect(bare.stdout == "tkzmux 0.0.0-dev (0) libghostty-vt unknown\n")
        #expect(try Self.runInstalled(binary, "--locate-resources", root: root).status == 1)

        // The install: version.plist from the script, one dummy bundle per module.
        let version = "1.2.3-dev.4+abc1234"
        let written = try ScriptSupport.bash(
            ["scripts/linux-version-plist.sh", install.appending(path: "version.plist").path],
            extraEnvironment: ["VERSION": version])
        try #require(written.status == 0, "\(written.stderr)")
        for module in ResourceLocator.resourceModules {
            try FileManager.default.createDirectory(
                at: install.appending(path: "tkzmux_\(module).resources"), withIntermediateDirectories: true)
        }
        let stamped = try #require(AppVersion.infoDictionary(contentsOf: install.appending(path: "version.plist")))
        let build = try #require(stamped[AppVersion.buildKey] as? String)
        let commit = try ScriptSupport.ghosttyCommit()
        #expect(Int(build) != nil)
        #expect(commit.count == 40 && commit.allSatisfy { $0.isHexDigit })

        // Launched directly and through a symlink in another prefix (`~/.local/bin/tkzmux` → the
        // install): both resolve the install, because the lookup follows /proc/self/exe.
        let launcher = root.appending(path: "home/.local/bin/tkzmux")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: binary)

        for executable in [binary, launcher] {
            let banner = try Self.runInstalled(executable, "--version", root: root)
            #expect(banner.status == 0, "\(banner.stderr)")
            #expect(banner.stdout == "tkzmux \(version) (\(build)) libghostty-vt \(commit)\n")

            let located = try Self.runInstalled(executable, "--locate-resources", root: root)
            #expect(located.status == 0, "\(located.stderr)")
            let expected = ResourceLocator.resourceModules.map {
                "\($0) \(install.appending(path: "tkzmux_\($0).resources").path)"
            }
            #expect(located.stdout.split(separator: "\n").map(String.init) == expected)
        }
    }
}
