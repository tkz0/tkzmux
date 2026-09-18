# Codex fixtures

Two kinds of file live here.

**Redacted real rollouts** — `rollout-short.jsonl`, `rollout-turn.jsonl`. Both come from real
`~/.codex/sessions/2026/06/02/rollout-*.jsonl` files written by codex-cli **0.130.0**. Before
committing, each had its shipped system prompt replaced with a placeholder, its git remote, branch
and commit hash replaced with obvious fakes, every `/Users/<name>` path rewritten to
`/Users/tester`, and every message body over 400 characters truncated. Nothing else was altered, so
the line shapes are exactly what Codex wrote.

**Hand-written fixtures** — everything else. These stand in for events the two real transcripts do
not contain, because both sessions lasted seconds. Their field names come from codex-cli **0.155.0**
binary strings and current documentation, **not** from a measured live run, and TKZ-86 records which
of them are still unverified. Anything reading them must skip a shape it does not recognise rather
than guess a value; see `CodexUsageExtractor` for why that matters for `token_count` in particular.

The two versions differ by 25 releases. A reader keyed to a structural field that moved between
them will pass here and fail in the field, so parse leniently and key off as little as possible.
