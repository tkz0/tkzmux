# AgentBridge on Linux

How the agent side of tkzmux (hook socket, watchers, liveness, installers, shell integration) runs on Linux, and what real Claude Code, Codex and Antigravity sessions produce there. Created in WOR-306 S1, which covers the hook socket. WOR-306 S2-S6 add the watchers, liveness and installers, shell integration, and the real-agent probe traces and dotfile-sync notes.

## Bring-up

AgentBridge joins the Linux graph a file at a time. `Package.swift` lists the sources that build on Linux (`agentBridgeLinuxSources`) and the tests that run on them (`agentBridgeLinuxTests`), and excludes the rest of each directory. On macOS both targets still compile everything. Once every file builds, AgentBridge moves to the shared targets.

| Session | Linux sources | Linux tests |
|---|---|---|
| WOR-306 S1 | `HookFrame.swift`, `HookServer.swift` | `HookServerTests` (plus the hook's own `HookHygieneTests` and `HookSupportPathTests` from WOR-305) |

## Hook socket

### Where it lives

| | Linux | macOS (unchanged) |
|---|---|---|
| Directory | `$XDG_RUNTIME_DIR/tkzmux`, created 0700 | the support directory |
| Fallback | the support directory, `$XDG_DATA_HOME/tkzmux` | – |
| Socket | `<directory>/tkzmux-<pid>.sock`, mode 0600 | same |

`HookSocket.directory(support:environment:)` (`Sources/TkzCore/HookSocket.swift`) decides. Everything that names the socket calls it:

- `TerminalEnvironment.make` exports `TKZMUX_SOCKET` from the environment the pane inherits (`baseEnvironment`). So inside a pane, `TKZMUX_SOCKET` is `$XDG_RUNTIME_DIR/tkzmux/tkzmux-<pid>.sock` for the pane's own `$XDG_RUNTIME_DIR`.
- `AgentIntegration` builds the `HookServer` path and sweeps stale sockets from the process environment. In the app that is the same environment, because `TerminalHost.baseEnvironment` defaults to the process environment.

The fallback to the support directory applies when `$XDG_RUNTIME_DIR` is unset, empty or relative (the XDG spec says to ignore it then), or when `<XDG_RUNTIME_DIR>/tkzmux` cannot be made private and writable. That covers a file or symlink in its place, an entry another user owns, a missing or read-only root, and a root this user cannot write. `AppPaths.privateRuntimeDirectory(environment:)` (`Sources/TkzPlatform/AppPaths.swift`) does the check. It never creates `$XDG_RUNTIME_DIR` itself. CI containers often have no `$XDG_RUNTIME_DIR`, so there the socket sits in the support directory, as on the Mac.

The runtime directory is a per-user tmpfs that logout clears, so a crash no longer leaves a stale socket in persistent storage. `HookServer.sweepStaleInstanceSockets` still runs on every start, in whichever directory was chosen. The path is about 40 bytes, well inside Linux's 108-byte `sun_path` (`MemoryLayout.size(ofValue: sockaddr_un().sun_path)`, 104 on macOS).

### Access boundary

There is **no peer-credential check** (`SO_PEERCRED`) on either OS. The boundary is the file system:

- the directory is 0700 and owned by the user (`makePrivateDirectory` narrows an existing one, and refuses a symlink or another owner's directory);
- the socket is `chmod 0600` right after `bind` (`HookServer.startOnQueue`);
- connecting to an `AF_UNIX` socket needs write permission on it, so only the user (and root) can send frames.

A peer check would add nothing against the same user: any process of that user can already write the support directory, `~/.claude` and the agents' configuration. The frames only change what a row shows. In the fallback case the support directory's own mode applies, as on the Mac.

### Socket flags

On Linux the listener is opened with `SOCK_CLOEXEC`, and connections are accepted with `accept4(SOCK_NONBLOCK | SOCK_CLOEXEC)`. A pane spawned while a hook is connected therefore never inherits the listener or a connection. Swift's Glibc module hides `accept4` (glibc declares it only under `_GNU_SOURCE`), so it is called through `tkz_accept4` in `TkzPlatformShim`. macOS keeps `accept` plus `fcntl(O_NONBLOCK)`. The server never writes to a connection, so it needs neither `SO_NOSIGPIPE` nor `MSG_NOSIGNAL`. Corelibs Dispatch does not mark sources `Sendable`, so the accept and read sources are created and resumed under the state lock, as in `Pty`.

### Tests

- `HookSocketTests` (TkzCoreTests): on Linux, the private runtime directory and every fallback (unset, empty, relative, a file, a symlinked `tkzmux`, a missing root, and an unwritable root, which is skipped as root). On macOS, the directory is the support directory whatever `XDG_RUNTIME_DIR` says.
- `TerminalEnvironmentTests.hookSocketDirectoryFollowsTheRuntimeDirectory`: `TKZMUX_SOCKET == $XDG_RUNTIME_DIR/tkzmux/tkzmux-<pid>.sock` on Linux, the support path when the variable is unset, empty or relative, and the support path on macOS.
- `HookServerTests` on both OSes. `paneAndServerAgreeOnTheSocketDirectory` points `XDG_RUNTIME_DIR` at a temp directory, checks that the pane's `TKZMUX_SOCKET` is the server's path, checks the 0700/0600 modes, and delivers a frame there. On Linux, `listenerAndConnectionsAreCloseOnExec` checks `FD_CLOEXEC` on the listener and on an accepted connection. The test clients use `send(MSG_NOSIGNAL)` on Linux, where macOS sets `SO_NOSIGPIPE` and uses `write`.
