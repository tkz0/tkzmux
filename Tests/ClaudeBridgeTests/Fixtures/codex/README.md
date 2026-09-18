# Codex fixtures

Three kinds of file live here. What matters is which of them came off a real binary, because the
hand-written ones encode guesses and the captured ones do not.

**Captured from a real logged-in codex-cli 0.155.0.** Every `hook-*.json` and `rollout-exec.jsonl`
is the verbatim payload Codex produced during the TKZ-86 spike, with absolute paths rewritten to
`/Users/tester`, the shipped system prompt replaced, the git remote and branch faked, and any text
over 400 characters truncated. Nothing else was altered, so the shapes are exactly what Codex
writes. `hook-stop.json` in particular proves `Stop` carries `last_assistant_message`, which the
ticket had assumed would have to be dug out of the rollout.

**Redacted real rollouts from an older build** — `rollout-short.jsonl` and `rollout-turn.jsonl`,
written by codex-cli **0.130.0**, redacted the same way. They are 25 releases behind
`rollout-exec.jsonl` and are kept deliberately: a reader keyed to a field that moved between those
versions passes on one and fails on the other, which is the cheapest version-drift test available.

**Hand-written** — `rollout-token-count.jsonl`, `hook-permission-request.json`,
`hook-interrupt.json`, `notify-agent-turn-complete.json`. These stand in for things a scripted
`codex exec` run cannot produce.

`rollout-token-count.jsonl` uses the **real** `token_count` shape as captured (the usage blocks are
nested under `info`, and each carries `cache_write_input_tokens`) — an earlier draft of this file
guessed that shape wrongly and was corrected against the capture. It exists because a single real
run has only one turn, and the thing most likely to be got wrong needs two: `total_token_usage` is
a running **thread** total, not a per-line delta, so a reader that sums successive lines overcounts
badly. The second turn's total is 2600 while its own turn used 1100, and the third line repeats the
second unchanged, standing in for the duplicate emission Codex makes on a rate-limit refresh. A
correct reader reports 2600; a summing one reports 6700.

`hook-permission-request.json` and `hook-interrupt.json` are **inferred, not measured**: under
`codex exec` the sandbox refuses a write outright rather than asking, and `Interrupt` is
interactive-only. Their field names follow `hook-pre-tool-use.json`, which is real. Anything reading
them should key off as little as possible and skip a shape it does not recognise.
