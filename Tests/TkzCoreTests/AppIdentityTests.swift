// AppIdentityTests — WOR-303 S4. The id must equal the Mac's committed `CFBundleIdentifier`, a
// Linux debug build must be `.Devel`, and every form must match the window-rule pattern ADR-0005
// documents. The rule is a pure function, so all four platform/configuration pairs run everywhere.
import Foundation
import Testing

@testable import TkzCore

@Suite struct AppIdentityTests {
    /// `CFBundleIdentifier` in the committed `Resources/Info.plist`.
    static func bundleIdentifier() throws -> String {
        let plist = ScriptSupport.repoRoot.appending(path: "Resources/Info.plist")
        let dictionary = try #require(AppVersion.infoDictionary(contentsOf: plist))
        return try #require(dictionary["CFBundleIdentifier"] as? String)
    }

    @Test func releaseIDIsTheBundleIdentifier() throws {
        #expect(AppIdentity.releaseID == (try Self.bundleIdentifier()))
    }

    /// The Mac's id is its bundle identifier in every configuration.
    @Test(.enabled(if: ResourceLocator.Platform.current == .macOS))
    func macOSIDIsTheBundleIdentifier() throws {
        #expect(AppIdentity.id == (try Self.bundleIdentifier()))
    }

    /// A Linux debug build (`swift build`, `swift run`, `swift test`) never shares the installed
    /// app's id, so it never forwards its activation to the installed instance.
    @Test(.enabled(if: ResourceLocator.Platform.current == .linux))
    func linuxDebugIDIsDevel() throws {
        #expect(AppIdentity.id(for: .linux, isDebugBuild: true).hasSuffix(".Devel"))
        #expect(AppIdentity.id(for: .linux, isDebugBuild: true) == (try Self.bundleIdentifier()) + ".Devel")
        #expect(AppIdentity.id == (AppIdentity.isDebugBuild ? AppIdentity.develID : AppIdentity.releaseID))
        #if DEBUG
        #expect(AppIdentity.id.hasSuffix(".Devel"))
        #else
        #expect(AppIdentity.id == AppIdentity.releaseID)
        #endif
    }

    @Test func idRule() {
        #expect(AppIdentity.id(for: .macOS, isDebugBuild: false) == AppIdentity.releaseID)
        #expect(AppIdentity.id(for: .macOS, isDebugBuild: true) == AppIdentity.releaseID)
        #expect(AppIdentity.id(for: .linux, isDebugBuild: false) == AppIdentity.releaseID)
        #expect(AppIdentity.id(for: .linux, isDebugBuild: true) == AppIdentity.develID)
    }

    /// ADR-0005's Hyprland rule key, which WOR-314's snippet check uses too.
    @Test func everyIDMatchesTheWindowRulePattern() throws {
        let pattern = try NSRegularExpression(pattern: #"^se\.tkz\.tkzmux(\.Devel)?$"#)
        for id in [AppIdentity.releaseID, AppIdentity.develID, AppIdentity.id] {
            #expect(pattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil, "\(id)")
        }
    }

    /// Linux: installed means `<prefix>/lib/tkzmux` exists beside `<prefix>/bin`.
    @Test func linuxInstalledMeansTheInstallDirectoryExists() throws {
        let root = try ScriptSupport.makeTemporaryDirectory("tkz-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "prefix/bin/tkzmux")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        let locator = ResourceLocator(
            platform: .linux, executablePath: executable.path, environment: [:], mainResourceURL: nil)
        #expect(!locator.installDirectoryExists)

        try FileManager.default.createDirectory(
            at: root.appending(path: "prefix/lib/tkzmux"), withIntermediateDirectories: true)
        #expect(locator.installDirectoryExists)

        let mac = ResourceLocator(
            platform: .macOS, executablePath: executable.path, environment: [:], mainResourceURL: nil)
        #expect(!mac.installDirectoryExists)
    }

    /// The test runner lives in `.build`, which has no `lib/tkzmux` beside it.
    @Test(.enabled(if: ResourceLocator.Platform.current == .linux))
    func linuxTestRunnerIsNotInstalled() {
        #expect(!AppIdentity.isInstalled)
    }
}
