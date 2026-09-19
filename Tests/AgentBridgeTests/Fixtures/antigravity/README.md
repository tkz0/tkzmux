# Antigravity fixtures

Three kinds of file live here. What matters is which of them came off a real binary, because the
hand-written ones encode guesses and the captured ones do not.

**Captured from a real logged-in Antigravity CLI 1.2.7** (`agy`, see `version.txt`). Every
`hook-*.json` is the verbatim JSON the CLI wrote to a hook command's **stdin** during one real
`agy -p` turn; `transcript-short.jsonl` is that turn's own transcript. Absolute paths were rewritten
to `/Users/tester`, the conversation id to a fixed one, and the user-input step's trailing prompt
metadata truncated at 400 characters. Nothing else was altered, so the shapes are exactly what
Antigravity writes. `help.txt` is `agy --help` verbatim.

**Hand-written, but proven against the binary** — `hooks-json-verified.json` and
`hooks-json-rejected.json`. Neither came out of the CLI; both were *tested* against it, and the log
line each produced is quoted below.

---

## The hooks.json trap

`agy` accepts a `hooks.json` whose shape is wrong, logs one warning, and then runs the whole session
with **no hooks at all**. There is no error on stdout and nothing in the TUI. This is the same trap
Codex set (see `../codex/README.md`), and it is the single thing most likely to be got wrong here.

The structure is **per event**, which the docs state only in a table and which is easy to miss:

| Event | Structure |
|---|---|
| `PreToolUse`, `PostToolUse` | **Grouped** — `[{ "matcher": "<regex>", "hooks": [handler, …] }]` |
| `PreInvocation`, `PostInvocation`, `Stop` | **Flat** — `[handler, …]`, no wrapper |

`hooks-json-rejected.json` is the grouped shape applied to a flat event. It produced, in
`~/.gemini/antigravity-cli/log/cli-*.log`:

```
W hooks.go:103] Failed to parse hooks file /Users/tester/.gemini/config/hooks.json:
  invalid hook "tkzmux-probe": command hook must specify 'command'
```

`hooks-json-verified.json` is the shape that **did** fire, confirmed by
`I hooks_manager.go:53] loaded 1 named hooks from 1 hooks.json file(s)` plus the hook command
actually running. Any installer tkzmux ships must produce this shape and must check that log line,
not merely that the file parsed as JSON.

Only those five events exist in `hooks.json`. `SessionStart`, `PreTurn` and `PostTurn` appear as
types inside the binary but are **not** configurable here — a probe registering them was silently
ignored.

## Where the file goes

`~/.gemini/config/hooks.json` (user-level) or `<workspace>/.agents/hooks.json` (project-level).
Both were tested and both load. Note the CLI's own state lives in
`~/.gemini/antigravity-cli/`, and a `hooks.json` placed *there* is not read — the binary's changelog
records that as a fixed bug, so a future version moving it again is a real risk.

The hook command runs via `sh -c` with its **working directory set to the directory containing
`hooks.json`**, `~` expanded, and a default timeout of 30 s.

## Payload shape

Hook payloads are **camelCase** (protojson): `conversationId`, `transcriptPath`,
`artifactDirectoryPath`, `modelName`, `workspacePaths`.

The **transcript is snake_case**: `step_index`, `created_at`, `source`, `type`, `status`, `content`.
The two casings in one agent is not a typo in these fixtures; it is what Antigravity does.

`hook-stop.json` is the useful one for status: it carries `terminationReason` (`NO_TOOL_CALL` here),
`fullyIdle` and `error`, which is enough to tell a finished turn from an abandoned one without
reading the transcript at all.

## What is deliberately absent

**There is no token or cost accounting anywhere.** The transcript carries none, the `brain/`
directory carries none, and no config file carries a running total — searched for `token`, `usage`,
`totalTokens` and `input_tokens` across the whole config tree after a real turn. So
`AntigravityAdapter` must **not** claim `.transcriptUsage`, and a row's spend badge stays hidden.
That is an honest absence, not an unmeasured one; re-check it when the CLI's major version moves.

**There is no environment variable that relocates the config directory.** `GEMINI_HOME`,
`GEMINI_CONFIG_DIR`, `GEMINI_DIR`, `GEMINI_CLI_HOME`, `ANTIGRAVITY_HOME`, `ANTIGRAVITY_CONFIG_DIR`,
`ANTIGRAVITY_CLI_HOME`, `AGY_HOME`, `AGY_CONFIG_DIR` and `XDG_CONFIG_HOME` were each tested by
running `agy models` under a pristine `HOME` with that variable pointing elsewhere; in every case the
tree was created under `HOME` regardless. Only `HOME` itself moves it. So
`environment(configDir:)` must return `[:]` **always**, and Antigravity has exactly **one account per
machine** — unlike Claude and Codex, it cannot be pointed at a second config dir.

## The account-key problem

Antigravity's config root is `~/.gemini/`, inherited from its predecessor, while its own state is in
`~/.gemini/antigravity-cli/`. Neither is `~/.antigravity`, so
`Account.configDirectory(forKey: "antigravity", home:)` — which assumes `~/.<key>` — resolves to a
directory that does not exist. A restored row has nothing else to go on, so config-dir derivation has
to move behind the adapter before this agent can be registered.

## Command lines (from `help.txt`, 1.2.7)

| Intent | Flag | Note |
|---|---|---|
| `.new` | `agy` | bare |
| `.resume` | `agy --conversation <ID>` | takes the id. **`--continue`/`-c` is not this** — it reopens the most recent conversation and ignores any id |
| `.prompt` | `agy --prompt-interactive "<text>"` (`-i`) | stays interactive, which is what the intent requires. **`-p`/`--print`/`--prompt` is one-shot** and does not satisfy it |
| `.worktree` | — | no worktree flag exists; the capability stays off |
