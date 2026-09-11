# Security

tkzmux is a personal project with no support commitment (see the README's *Status* section). There
is no security team, no SLA, and no guarantee that a report will be acted on.

That said, reports are welcome. Open a GitHub issue describing the problem. If you believe the
details are dangerous to publish, open an issue saying only that you have a security report and
asking for a private channel, and one will be arranged.

What is in scope is anything that makes tkzmux leak or expose data it holds — see
[docs/privacy.md](docs/privacy.md) for what that is, in particular the unencrypted terminal
snapshots under `~/Library/Application Support/tkzmux/sessions` and the local hook socket.
Vulnerabilities in Claude Code itself belong to Anthropic, and vulnerabilities in libghostty-vt to
the Ghostty project.
