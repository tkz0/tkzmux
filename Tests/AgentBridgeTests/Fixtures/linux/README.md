# Linux agent fixtures

Captured from real agents on Linux (Arch, x86_64) by `RealAgentProbeTests` with `TKZMUX_REAL_AGENTS_CAPTURE` set (WOR-306 S6). The agents were **Claude Code 2.1.287** and **codex-cli 0.160.0**, each run in a tkzmux-style pane, through tkzmux's own shims and the release `tkzmux-hook`. They talked to `fake-model-api.py` on loopback, which answers every turn with `pong`, so no account and no network were involved.

The payloads are verbatim, with three rewrites: the probe's HOME is `/home/tester` (the macOS fixtures use `/Users/tester`), its `XDG_RUNTIME_DIR` is `/run/user/1000`, and the machine id inside a Linux `pidDomain` is all zeros. Conversation ids, pids and timestamps are the ones the run produced.

Antigravity (`agy`) was not installed on the capture machine, so there are no Linux Antigravity captures yet. `../antigravity` holds the macOS ones.

## Files

| File | What it is |
|---|---|
| `claude-code.trace`, `codex.trace` | The goldens. The normalized trace of the probe run (see `AgentTrace.swift`), compared section by section by the probe on every OS, and in their `launch`, `hooks` and `notify` sections by `AgentFixtureReplayTests` |
| `fake-model-api.py` | The model API stand-in: Anthropic Messages and OpenAI Responses, streamed |
| `<agent>/sequence` | The order the hook received everything: `launch <agent> <pane> <file>`, `hook <agent> <pane> <event> <file>`, `notify <agent> <pane> <event> <file>` |
| `<agent>/launch*.argv` | The shim's `tkzmux-hook launch …` arguments, one per line |
| `<agent>/hook-<Event>*.json` | What the agent wrote to the hook's stdin for that event |
| `claude/statusline-stdin.json` | The last statusline payload of the turn (Claude Code's own JSON on the statusline command's stdin) |
| `claude/session-busy.json`, `session-idle.json` | `<config>/sessions/<pid>.json` while busy and after the turn. Linux descriptors carry `procStart`, `pidDomain` and a `messagingSocketPath` under `$XDG_RUNTIME_DIR/cc-socks` |
| `claude/settings.json` | `StatuslineInstaller`'s statusline, with the Linux hook path |
| `claude/paths.txt` | The transcript path: `projects/<cwd with every non-alphanumeric character as ->/<id>.jsonl`, as on macOS |
| `codex/hooks.json` | `CodexHooksInstaller`'s output, with the Linux hook path |
| `codex/config.toml` | The probe's provider and `notify`, plus what Codex itself added: the folder trust and, after "Trust all and continue", the hook-trust ledger (`[hooks.state."<hooks.json>:<event>:0:0"] trusted_hash`) |
| `codex/notify-agent-turn-complete*.json` | `notify`'s argv payloads. Each turn produces two: one for the turn and one for the title Codex generates on a side thread |
| `codex/paths.txt` | The rollout paths: `sessions/<yyyy>/<mm>/<dd>/rollout-<time>-<id>.jsonl` |

The `trusted_hash` values were computed by Codex over the probe's real paths, before the rewrite to `/home/tester`. They show the shape, not hashes that would verify against these files.

## Regenerating

See docs/linux/agents.md, *Real-agent probe*. In short: build the release hook, run the probe inside a network namespace with `TKZMUX_REAL_AGENTS_CAPTURE=<dir>`, then copy `<dir>/<agent>/fixtures/*` here and move each `trace` to `<agent>.trace` (`claude-code.trace` for Claude Code). A new agent version that changes a golden is a finding: say what changed in the commit.
