#!/bin/bash
# tkzmux's `codex` shim. Installed at `$TKZMUX_BIN/codex` by ShimInstaller; the ZDOTDIR wrapper
# (`zshrc`) puts `$TKZMUX_BIN` first on PATH, after the user's own rc files ran. Sibling of
# `claude.sh` -- read that one first, the structure below mirrors it.
#
# Job: find the *real* codex, announce our pid over the socket, then exec the real binary
# unmodified. Outside a tkzmux session (no TKZMUX_SESSION_ID/SOCKET) or for anything we don't
# understand, this must be a no-op pass-through -- never break `codex`.
#
# Unlike `claude`, there is no `--settings` equivalent to merge: Codex has no hook-injection
# mechanism of its own, so the argv this shim execs is always exactly what it was handed. The only
# thing this shim adds is the `launch` announcement before exec, and only for the invocations that
# start an interactive session.
set -u

debug() {
    if [[ "${TKZMUX_HOOK_DEBUG:-}" == "1" ]]; then
        printf 'tkzmux-shim: %s\n' "$1" >&2
    fi
}

self_path="${BASH_SOURCE[0]}"
self_real=""
if command -v realpath >/dev/null 2>&1; then
    self_real="$(realpath "$self_path" 2>/dev/null || true)"
fi

tkzmux_bin_real=""
if [[ -n "${TKZMUX_BIN:-}" ]] && command -v realpath >/dev/null 2>&1; then
    tkzmux_bin_real="$(realpath "$TKZMUX_BIN" 2>/dev/null || true)"
fi

# Step 1: find the real codex on PATH, skipping ourselves.
real=""
# `IFS=':' read -a` rather than `path_dirs=($PATH)`: the latter is subject to pathname expansion,
# so a PATH entry containing a literal `*` would get glob-expanded against the cwd.
IFS=':' read -r -a path_dirs <<< "$PATH"

for dir in "${path_dirs[@]+"${path_dirs[@]}"}"; do
    [[ -n "$dir" ]] || continue

    # Skip any PATH entry that is tkzmux's own bin dir (literal or realpath match) -- that's
    # where this script lives, and we must never resolve to ourselves.
    if [[ -n "${TKZMUX_BIN:-}" && "$dir" == "$TKZMUX_BIN" ]]; then
        continue
    fi
    if [[ -n "$tkzmux_bin_real" ]] && command -v realpath >/dev/null 2>&1; then
        dir_real="$(realpath "$dir" 2>/dev/null || true)"
        if [[ -n "$dir_real" && "$dir_real" == "$tkzmux_bin_real" ]]; then
            continue
        fi
    fi

    candidate="$dir/codex"
    if [[ -f "$candidate" && -x "$candidate" ]]; then
        # Skip a candidate that resolves to this very script (e.g. TKZMUX_BIN listed twice, or
        # reached via a symlinked path).
        if [[ "$candidate" == "$self_path" ]]; then
            continue
        fi
        if [[ -n "$self_real" ]] && command -v realpath >/dev/null 2>&1; then
            candidate_real="$(realpath "$candidate" 2>/dev/null || true)"
            if [[ -n "$candidate_real" && "$candidate_real" == "$self_real" ]]; then
                continue
            fi
        fi
        real="$candidate"
        break
    fi
done

if [[ -z "$real" ]]; then
    echo "codex: command not found (tkzmux shim)" >&2
    exit 127
fi
debug "real codex resolved to $real"

# Step 2: decide whether to pass through untouched -- no `launch` announcement, argv unmodified.
pass_through=0

if [[ -z "${TKZMUX_SESSION_ID:-}" || -z "${TKZMUX_SOCKET:-}" ]]; then
    pass_through=1
    debug "no tkzmux session env; pass-through"
fi

hook_bin="${TKZMUX_BIN:-}/tkzmux-hook"
if [[ $pass_through -eq 0 ]]; then
    if [[ -z "${TKZMUX_BIN:-}" || ! -x "$hook_bin" ]]; then
        pass_through=1
        debug "tkzmux-hook missing or not executable; pass-through"
    fi
fi

# Subcommands that never start an interactive session, so there is nothing here worth
# instrumenting -- measured against `codex --help` on the installed 0.155.0.
#
# `resume` and `fork` are deliberately NOT in this list, even though `codex --help` lists them as
# subcommands: both start an interactive session, and `codex resume <id>` is tkzmux's own resume
# command. Those are exactly the invocations that need a `launch` announcement, so they fall
# through to Step 3 below like a bare `codex` invocation does.
if [[ $pass_through -eq 0 && $# -gt 0 ]]; then
    case "$1" in
        agents|exec|review|login|logout|mcp|plugin|app-server|remote-control|app|completion|\
update|doctor|sandbox|debug|apply|queue|archive|delete|migrate-rollouts|unarchive|\
cloud|exec-server|features|help)
            pass_through=1
            debug "subcommand '$1'; pass-through"
            ;;
    esac
fi

if [[ $pass_through -eq 0 ]]; then
    for arg in "$@"; do
        case "$arg" in
            --version|-V|--help|-h)
                pass_through=1
                debug "flag '$arg'; pass-through"
                break
                ;;
        esac
    done
fi

if [[ $pass_through -eq 1 ]]; then
    exec "$real" "$@"
fi

# Step 3: announce the launch, then exec the original argv completely unmodified -- there is no
# settings file to merge for Codex.
#
# Which account this Codex process belongs to follows from this directory and nothing else.
cfg="${CODEX_HOME:-$HOME/.codex}"

"$hook_bin" launch --pid $$ --cwd "$PWD" --config-dir "$cfg" --agent codex -- "$@" >/dev/null 2>&1

# Exported, not just set: the real `codex` process this line execs into inherits it, and so does
# every hook process *it* spawns for each event -- that's the entire mechanism for the relay path
# to know which agent it's relaying for, with no flag involved.
export TKZMUX_AGENT=codex

exec "$real" "$@"
