# `.tkzrec` fixtures

Recorded with `tkzmux-vtdump record` (M1.3 / TKZ-9) under the **full `TerminalEnvironment`** —
`TERM=xterm-ghostty`, `TERM_PROGRAM=ghostty`, `TERM_PROGRAM_VERSION`, `COLORTERM=truecolor` and the
bundled `TERMINFO` — because Claude Code gates kitty keyboard and synchronized output on
`TERM_PROGRAM`. A recording made without that contract is worthless as a fixture.

All of them were captured in a throwaway `mktemp -d` directory, never in a real project, with the
recorder's default minimal base environment (`HOME`, `PATH`, `SHELL`, `USER`, `LOGNAME`, `TMPDIR`,
`LANG` only). The `.txt` next to each recording is the golden PLAIN screen, regenerated from the
**sanitized** file with `tkzmux-vtdump replay --format plain`.

| Fixture | What it is | Ends |
|---|---|---|
| `synthetic-basic.tkzrec` | **Synthetic** — hand-built, not a recording. Container/replay test only. | — |
| `zsh-ls-color.tkzrec` | `zsh -f -i` running `ls --color=always -F` over files of four types. | child `exit 0` |
| `claude-boot.tkzrec` | Real `claude` 2.1.263 booting through the trust prompt to the idle prompt. | `SIGKILL` |
| `claude-tool-run.tkzrec` | Real `claude` running one Bash tool call (`echo hi`). | `SIGKILL` |

The two Claude recordings end with **SIGKILL, not SIGHUP, on purpose**: a hang-up makes Claude Code
tear down (alt screen off, mouse off, kitty flags cleared, `CSI < u`), and the whole point of these
fixtures is the state a *running* program leaves the terminal in. The `stop` script command does
this. The format tolerates the resulting recording exactly as it tolerates a killed session.

`vttest-menu1` is **missing**: `vttest` is not installed on the recording machine and the ticket says
not to install it.

## Sanitization

Every byte replacement is **length-preserving**, so the recorded cursor positioning still lines up
and the recording replays to the same screen. Applied to the raw file (frames included):

(The literal values that were removed are deliberately not repeated here — that would put them back
into the repository. Each row says what kind of value it was and where it appeared.)

| What | Replacement | Occurrences |
|---|---|---|
| the recording user's account name (12 chars) | `redacteduser` | `claude-boot` 1, `claude-tool-run` 1 — inside an OSC 8 `file:///Users/<name>/…` URI |
| the `mktemp -d` suffix, `tkzrec.[A-Za-z0-9]{6}` | `tkzrec.XXXXXX` | `claude-boot` 2, `claude-tool-run` 2 |
| a live `claude.ai/code/session_[A-Za-z0-9]{24}` URL | `session_` + 24 × `R` | `claude-boot` 1, `claude-tool-run` 1 — inside an OSC 8 URI |
| the machine hostname (15 chars) | `host-anonymized` | `zsh-ls-color` 1 — zsh's default `%m` prompt |

Re-scanned afterwards for the account name, the hostname, the user's email domain, `sk-…` style API
keys, `/Users/…`, `session_…`, any `local-part@domain.tld` address, and `api[_-]key|token|secret|
password` assignments: the only remaining matches are the placeholders above. No API keys, tokens,
private repository names or email addresses were present in any of the recordings to begin with.

What deliberately **was** kept, because it is behaviour under test and not personal data: the Claude
Code version banner, the model name, the subscription tier, the context/usage meters and the
`/private/tmp/tkzrec.XXXXXX/proj` working directory of the throwaway project.

## Re-recording

```sh
WORK=$(mktemp -d)
tkzmux-vtdump record --out "$WORK/claude-boot.tkzrec" --cols 100 --rows 30 \
    --cwd "$WORK/proj" --quiet --timeout 90000 --script boot.script \
    --golden "$WORK/claude-boot.txt" -- claude
```

with `boot.script`:

```
waitfor "trust" 25000
wait 800
send "\e[B"
wait 400
send "\r"
waitfor "shortcuts" 40000
wait 4000
stop
```

Then sanitize with length-preserving substitutions and regenerate the golden from the sanitized file.
