// ShimInstallerTests — ShimInstaller against a temp application-support directory and a fake hook
// binary. Never touches the real `~/Library/Application Support/tkzmux`.
import Foundation
import Testing

@testable import ClaudeBridge

private func makeTempDirectory(_ label: String) throws -> URL {
    try ShimTestSupport.makeTempDirectory(label)
}

private func makeFakeHookBinary(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("tkzmux-hook")
    try Data("fake hook binary".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func posixPermissions(of url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.posixPermissions] as? Int) ?? -1
}

private func modificationDate(of url: URL) throws -> Date {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.modificationDate] as? Date) ?? .distantPast
}

@Test func bundledResourcesLoadUnderSwiftTest() throws {
    let resources = try ShimResources.bundled()
    #expect(resources.shimScript.contains("#!/bin/bash"))
    #expect(resources.zshFiles.keys.sorted() == ["zlogin", "zprofile", "zshenv", "zshrc"])
    #expect(resources.wrappers.keys.sorted() == [
        "bash/tkzmux.bashrc", "fish/tkzmux.fish",
        "zsh/.zlogin", "zsh/.zprofile", "zsh/.zshenv", "zsh/.zshrc",
    ])
    for content in resources.wrappers.values {
        #expect(!content.isEmpty)
    }
    #expect(resources.wrapper(for: .bash)?.contains("TKZMUX_BIN") == true)
    #expect(resources.wrapper(for: .fish)?.contains("TKZMUX_BIN") == true)
    #expect(resources.wrapper(for: .other) == nil)
}

@Test func installWritesFilesModesAndVersion() throws {
    let root = try makeTempDirectory("installer")
    let hookBinary = try makeFakeHookBinary(in: root)
    let installer = ShimInstaller(
        directory: root.appendingPathComponent("app-support"), hookBinary: hookBinary,
        resources: try ShimResources.bundled())

    let outcome = try installer.ensureInstalled()
    #expect(outcome == .installed)

    let dir = root.appendingPathComponent("app-support")
    let claude = dir.appendingPathComponent("bin/claude")
    let hook = dir.appendingPathComponent("bin/tkzmux-hook")
    let version = dir.appendingPathComponent("VERSION")

    #expect(FileManager.default.fileExists(atPath: claude.path))
    #expect(FileManager.default.fileExists(atPath: hook.path))
    #expect(FileManager.default.fileExists(atPath: version.path))
    #expect(try posixPermissions(of: claude) == 0o755)
    #expect(try posixPermissions(of: hook) == 0o755)

    for name in ShimResources.zshFileNames {
        let dotfile = dir.appendingPathComponent("zsh/.\(name)")
        #expect(FileManager.default.fileExists(atPath: dotfile.path))
        #expect(try posixPermissions(of: dotfile) == 0o644)
    }
    for path in ["bash/tkzmux.bashrc", "fish/tkzmux.fish"] {
        let wrapper = dir.appendingPathComponent(path)
        #expect(FileManager.default.fileExists(atPath: wrapper.path), "\(path)")
        #expect(try posixPermissions(of: wrapper) == 0o644)
    }

    #expect(installer.isInstalled)
}

@Test func secondCallIsUpToDateAndTouchesNothing() throws {
    let root = try makeTempDirectory("installer")
    let hookBinary = try makeFakeHookBinary(in: root)
    let installer = ShimInstaller(
        directory: root.appendingPathComponent("app-support"), hookBinary: hookBinary,
        resources: try ShimResources.bundled())

    #expect(try installer.ensureInstalled() == .installed)

    let checked = [
        root.appendingPathComponent("app-support/bin/claude"),
        root.appendingPathComponent("app-support/VERSION"),
        root.appendingPathComponent("app-support/zsh/.zshrc"),
    ]
    let before = try checked.map { try modificationDate(of: $0) }

    #expect(try installer.ensureInstalled() == .upToDate)
    let after = try checked.map { try modificationDate(of: $0) }
    #expect(before == after)
}

@Test func touchingTheHookBinaryTriggersAnUpdate() throws {
    let root = try makeTempDirectory("installer")
    let hookBinary = try makeFakeHookBinary(in: root)
    let installer = ShimInstaller(
        directory: root.appendingPathComponent("app-support"), hookBinary: hookBinary,
        resources: try ShimResources.bundled())

    #expect(try installer.ensureInstalled() == .installed)

    // Change the hook binary's mtime (and size, to be unambiguous) so the content hash changes.
    try Data("fake hook binary v2".utf8).write(to: hookBinary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookBinary.path)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: hookBinary.path)

    #expect(try installer.ensureInstalled() == .updated)
    #expect(try installer.ensureInstalled() == .upToDate)
}

@Test func removeLeavesSessionsAndStateFileInPlace() throws {
    let root = try makeTempDirectory("installer")
    let hookBinary = try makeFakeHookBinary(in: root)
    let appSupport = root.appendingPathComponent("app-support")
    let installer = ShimInstaller(
        directory: appSupport, hookBinary: hookBinary, resources: try ShimResources.bundled())
    _ = try installer.ensureInstalled()

    let sessions = appSupport.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let marker = sessions.appendingPathComponent("s1.ghsnap")
    try Data("snapshot".utf8).write(to: marker)
    let stateFile = appSupport.appendingPathComponent("state.json")
    try Data("{}".utf8).write(to: stateFile)

    try installer.remove()

    #expect(!FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("bin").path))
    #expect(!FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("zsh").path))
    #expect(!FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("bash").path))
    #expect(!FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("fish").path))
    #expect(!FileManager.default.fileExists(atPath: appSupport.appendingPathComponent("VERSION").path))
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(FileManager.default.fileExists(atPath: stateFile.path))
    #expect(!installer.isInstalled)
}

@Test func copesWithAnAlreadyExistingEmptyZshDirectory() throws {
    // TerminalViewHost creates an empty zsh/ at startup, before the installer ever runs.
    let root = try makeTempDirectory("installer")
    let hookBinary = try makeFakeHookBinary(in: root)
    let appSupport = root.appendingPathComponent("app-support")
    try FileManager.default.createDirectory(
        at: appSupport.appendingPathComponent("zsh"), withIntermediateDirectories: true)

    let installer = ShimInstaller(
        directory: appSupport, hookBinary: hookBinary, resources: try ShimResources.bundled())
    #expect(try installer.ensureInstalled() == .installed)
    #expect(installer.isInstalled)
}
