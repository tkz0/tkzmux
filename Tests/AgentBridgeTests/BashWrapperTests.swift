// BashWrapperTests — the bash wrapper against this machine's own system files (WOR-306 S5). On
// Arch, bash reads /etc/bash.bashrc (SYS_BASHRC) before `--rcfile`, /etc/profile reads it again
// for an interactive shell, and /etc/profile.d/80-systemd-osc-context.sh hooks every prompt; the
// wrapper has to undo the double load and the per-prompt cost. On macOS (no bash_completion, no
// prompt hooks in the system files) both tests hold trivially, and the overhead one needs bash 5.
import Foundation
import Testing
import TkzCore

@testable import AgentBridge

private let installedBashes = installedHarnessShells.filter { $0.shell.family == .bash }

private struct BashFixture {
    var root: URL
    var home: URL
    var tkzmuxDir: URL
    var bin: URL { tkzmuxDir.appendingPathComponent("bin", isDirectory: true) }
    var wrapper: URL { tkzmuxDir.appendingPathComponent("bash/tkzmux.bashrc") }

    /// What the app hands bash, minus what this machine's own files do with it: the wrappers
    /// written by the real installer, an empty HOME, an xterm-like TERM (Arch's bash.bashrc only
    /// sets its OSC 0 title for one, and the systemd script stays quiet for `dumb`).
    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-ghostty",
            "USER": ProcessInfo.processInfo.userName, "TKZMUX_BIN": bin.path,
        ]
        for (key, value) in extra { env[key] = value }
        return env
    }
}

private func makeBashFixture() throws -> BashFixture {
    let root = try ShimTestSupport.makeTempDirectory("bash-system")
    let fixture = BashFixture(
        root: root, home: root.appendingPathComponent("home", isDirectory: true),
        tkzmuxDir: root.appendingPathComponent("tkzmux", isDirectory: true))
    for dir in [fixture.home, fixture.tkzmuxDir] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let hook = try ShimTestSupport.writeExecutable(
        "#!/bin/sh\nexit 0\n", to: root.appendingPathComponent("tkzmux-hook"))
    let installer = ShimInstaller(
        directory: fixture.tkzmuxDir, hookBinary: hook, resources: try ShimResources.bundled())
    _ = try installer.ensureInstalled()
    return fixture
}

/// Runs `bash` with `script` on stdin, stdout and stderr into files: an xtrace of the whole
/// startup is far more than a pipe holds, and `ShimTestSupport.run` reads the pipes one at a time.
private func runBash(
    _ bash: String, _ arguments: [String], environment: [String: String], script: String,
    in root: URL
) throws -> (stdout: String, stderr: String) {
    let outURL = root.appendingPathComponent("stdout.txt")
    let errURL = root.appendingPathComponent("stderr.txt")
    let inURL = root.appendingPathComponent("stdin.txt")
    try Data(script.utf8).write(to: inURL)
    for url in [outURL, errURL] { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: bash)
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = root
    process.standardInput = try FileHandle(forReadingFrom: inURL)
    process.standardOutput = try FileHandle(forWritingTo: outURL)
    process.standardError = try FileHandle(forWritingTo: errURL)
    try process.run()
    process.waitUntilExit()
    return (
        (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
        (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
}

@Suite(.serialized)
struct BashWrapperTests {
    /// bash_completion is sourced at most once by a tkzmux bash. `SHELLOPTS=xtrace` in the
    /// environment turns tracing on before bash reads its system bashrc, so every
    /// `. …/bash_completion` it runs, from whichever file, is one trace line (`+` per nesting
    /// level). Before the wrapper sourced /etc/profile with PS1 unset, Arch showed two.
    @Test(arguments: installedBashes)
    func bashCompletionLoadsOnce(_ harness: HarnessShell) throws {
        let fixture = try makeBashFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runBash(
            harness.shell.path, ["--rcfile", fixture.wrapper.path, "-i"],
            environment: fixture.environment(["SHELLOPTS": "xtrace"]), script: "exit\n",
            in: fixture.root)
        let loads = result.stderr.split(separator: "\n").filter {
            $0.wholeMatch(of: /\++ (\.|source) \S*\/bash_completion/) != nil
        }
        #expect(loads.count <= 1, "\(harness.shell.path): \(loads)")
    }

    /// No title and no OSC 3008 from the system files, as on macOS: the shell's first prompt
    /// (the PROMPT_COMMAND that runs before it) writes only OSC 7. Arch's bash.bashrc sets an
    /// OSC 0 `user@host:dir` title for an xterm-like TERM; the harness's own fixture cannot see
    /// it, because its PROMPT_COMMAND assignment overwrites that array element.
    @Test(arguments: installedBashes)
    func noSystemTitleOrContextReports(_ harness: HarnessShell) throws {
        let fixture = try makeBashFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let result = try runBash(
            harness.shell.path, ["--rcfile", fixture.wrapper.path, "-i"],
            environment: fixture.environment(["TKZMUX_OSC7_TO_STDOUT": "1"]),
            script: "cd /\nexit\n", in: fixture.root)
        #expect(result.stdout.contains("\u{1b}]7;file://localhost/\u{7}"), "\(result.stdout)")
        #expect(!result.stdout.contains("\u{1b}]0;"), "\(result.stdout)")
        #expect(!result.stdout.contains("\u{1b}]2;"), "\(result.stdout)")
        #expect(!result.stdout.contains("\u{1b}]3008;"), "\(result.stdout)")
    }

    /// The per-prompt cost of a tkzmux bash -- every PROMPT_COMMAND element plus the PS0 and PS1
    /// expansions, 300 times -- is under 2 ms a prompt above a plain `bash --norc --noprofile`.
    /// Arch's systemd OSC 3008 hooks alone cost 8.4 ms a prompt on the reference machine; the
    /// wrapper unhooks them. bash 5 for EPOCHREALTIME and `@P` (macOS's /bin/bash 3.2 is skipped).
    @Test(arguments: installedBashes)
    func perPromptOverheadIsUnderTwoMilliseconds(_ harness: HarnessShell) throws {
        let fixture = try makeBashFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let measure = """
            __tkzmux_test_measure() {
                local n=300 i c t0 t1 x
                if ((BASH_VERSINFO[0] < 5)); then echo PROMPT_US=skip; return; fi
                t0=${EPOCHREALTIME/./}
                for ((i = 0; i < n; i++)); do
                    for c in "${PROMPT_COMMAND[@]}"; do eval "$c"; done
                    x="${PS0@P}${PS1@P}"
                done > /dev/null
                t1=${EPOCHREALTIME/./}
                echo "PROMPT_US=$(( (t1 - t0) / n ))"
            }
            __tkzmux_test_measure
            exit

            """
        /// nil for bash < 5. The startup's own OSC output shares the line with the result.
        func microseconds(_ arguments: [String], _ env: [String: String]) throws -> Int? {
            let out = try runBash(
                harness.shell.path, arguments, environment: env, script: measure, in: fixture.root
            ).stdout
            let at = try #require(out.range(of: "PROMPT_US="), "\(harness.shell.path): \(out)")
            let value = out[at.upperBound...].prefix { $0 != "\n" }
            if value == "skip" { return nil }
            // Bound first: returned directly, `#require` would wrap it in the `Int?` result and
            // never fail.
            let perPrompt: Int = try #require(Int(String(value)), "\(harness.shell.path): \(out)")
            return perPrompt
        }
        // TKZMUX_OSC7_TO_STDOUT: the wrapper's terminal-only work runs as it would on a tty.
        guard let tkzmux = try microseconds(
            ["--rcfile", fixture.wrapper.path, "-i"],
            fixture.environment(["TKZMUX_OSC7_TO_STDOUT": "1"]))
        else { return }
        let plain = try #require(try microseconds(
            ["--norc", "--noprofile", "-i"], fixture.environment()))
        #expect(tkzmux - plain < 2000, "\(harness.shell.path): tkzmux \(tkzmux) µs, plain \(plain) µs")
    }
}
