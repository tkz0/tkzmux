// LoginShellTests — TKZ-33: which shell a session runs, and the argv/layout contract shared by the
// pty and the installer. Pure: nothing here spawns a shell (see ClaudeBridgeTests' harness).
import Foundation
import Testing

@testable import TkzCore

@Suite struct LoginShellTests {
    private let allExecutable: (String) -> Bool = { _ in true }

    @Test func shellFromTheEnvironmentWins() {
        let shell = LoginShell.detect(
            environment: ["SHELL": "/bin/bash"], passwordDatabaseShell: "/bin/zsh",
            isExecutable: allExecutable)
        #expect(shell == LoginShell(path: "/bin/bash"))
        #expect(shell.family == .bash)
        #expect(shell.name == "bash")
    }

    @Test func fallsBackToThePasswordDatabaseThenToZsh() {
        let fromPasswd = LoginShell.detect(
            environment: [:], passwordDatabaseShell: "/opt/homebrew/bin/fish",
            isExecutable: allExecutable)
        #expect(fromPasswd.family == .fish)
        #expect(fromPasswd.path == "/opt/homebrew/bin/fish")

        let nothing = LoginShell.detect(
            environment: [:], passwordDatabaseShell: nil, isExecutable: allExecutable)
        #expect(nothing == .zsh)
    }

    /// A stale `SHELL` (a removed Homebrew fish) or a relative one must not leave the user without
    /// a terminal: skip it and take the next candidate.
    @Test func skipsCandidatesThatAreNotExecutableFiles() {
        let shell = LoginShell.detect(
            environment: ["SHELL": "/opt/homebrew/bin/fish"], passwordDatabaseShell: "/bin/bash",
            isExecutable: { $0 == "/bin/bash" })
        #expect(shell.path == "/bin/bash")

        let relative = LoginShell.detect(
            environment: ["SHELL": "bash"], passwordDatabaseShell: nil, isExecutable: allExecutable)
        #expect(relative == .zsh)
    }

    @Test func classifiesByBasename() {
        #expect(LoginShell(path: "/bin/zsh").family == .zsh)
        #expect(LoginShell(path: "/opt/homebrew/bin/bash").family == .bash)
        #expect(LoginShell(path: "/usr/local/bin/fish").family == .fish)
        #expect(LoginShell(path: "/bin/tcsh").family == .other)
        #expect(LoginShell(path: "/bin/tcsh").name == "tcsh")
    }

    @Test func zshArgvIsUnchanged() {
        let dir = URL(fileURLWithPath: "/tmp/support")
        #expect(LoginShell.zsh.argv(tkzmuxDir: dir, wrapperPresent: true) == ["-zsh", "-l"])
        #expect(LoginShell.zsh.argv(tkzmuxDir: dir, wrapperPresent: false) == ["-zsh", "-l"])
        #expect(LoginShell.zsh.entryWrapper(in: dir) == nil)
    }

    /// `--rcfile` is honoured only by an interactive *non-login* bash, so the integrated form has
    /// no leading dash and no `-l`; without the wrapper on disk, a plain login bash.
    @Test func bashArgv() {
        let dir = URL(fileURLWithPath: "/tmp/support")
        let bash = LoginShell(path: "/bin/bash")
        #expect(bash.entryWrapper(in: dir)?.path == "/tmp/support/bash/tkzmux.bashrc")
        #expect(bash.argv(tkzmuxDir: dir, wrapperPresent: true)
            == ["bash", "--rcfile", "/tmp/support/bash/tkzmux.bashrc"])
        #expect(bash.argv(tkzmuxDir: dir, wrapperPresent: false) == ["-bash", "-l"])
    }

    @Test func fishArgv() {
        let dir = URL(fileURLWithPath: "/tmp/it's here")
        let fish = LoginShell(path: "/opt/homebrew/bin/fish")
        #expect(fish.entryWrapper(in: dir)?.path == "/tmp/it's here/fish/tkzmux.fish")
        #expect(fish.argv(tkzmuxDir: dir, wrapperPresent: true)
            == ["-fish", "-l", "-C", "source '/tmp/it\\'s here/fish/tkzmux.fish'"])
        #expect(fish.argv(tkzmuxDir: dir, wrapperPresent: false) == ["-fish", "-l"])
    }

    /// tcsh rejects `-l` alongside any other argument; the dash alone is the login signal.
    @Test func otherShellsGetADashArgv0AndNoWrapper() {
        let dir = URL(fileURLWithPath: "/tmp/support")
        let tcsh = LoginShell(path: "/bin/tcsh")
        #expect(tcsh.argv(tkzmuxDir: dir, wrapperPresent: true) == ["-tcsh"])
        #expect(tcsh.wrapperFiles.isEmpty)
        #expect(tcsh.entryWrapper(in: dir) == nil)
    }

    /// The layout the installer writes and the pty reads. Changing it changes every existing
    /// install's `VERSION` hash, which is fine, but do it knowingly.
    @Test func wrapperLayout() {
        #expect(LoginShell.allWrapperFiles.map(\.installedPath) == [
            "zsh/.zshenv", "zsh/.zprofile", "zsh/.zshrc", "zsh/.zlogin",
            "bash/tkzmux.bashrc", "fish/tkzmux.fish",
        ])
        #expect(LoginShell.wrapperDirectories == ["zsh", "bash", "fish"])
        for file in LoginShell.allWrapperFiles {
            #expect(!file.resourceName.hasPrefix("."), "resources are never dotted: \(file)")
            #expect(file.installedPath.hasPrefix(file.resourceDirectory + "/"))
        }
    }
}
