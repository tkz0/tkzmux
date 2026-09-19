#!/bin/bash
# tkzmux's `agy` (Antigravity CLI) shim. Installed at `$TKZMUX_BIN/agy` by ShimInstaller; the
# ZDOTDIR wrapper (`zshrc`) puts `$TKZMUX_BIN` first on PATH, after the user's own rc files ran.
# Sibling of `codex.sh` -- read that one first, the structure below mirrors it.
#
# Job: find the *real* agy, announce our pid over the socket, then exec the real binary unmodified.
# Outside a tkzmux session (no TKZMUX_SESSION_ID/SOCKET) or for anything we don't understand, this
# must be a no-op pass-through -- never break `agy`.
#
# Like Codex and unlike Claude, there is no settings flag to merge: Antigravity's hooks live in a
# file the user owns (`~/.gemini/config/hooks.json`, written once with consent by
# AntigravityHooksInstaller), so the argv this shim execs is always exactly what it was handed.
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

# Step 1: find the real agy on PATH, skipping ourselves.
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

    candidate="$dir/agy"
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
    echo "agy: command not found (tkzmux shim)" >&2
    exit 127
fi
debug "real agy resolved to $real"

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
# instrumenting -- measured against `agy --help` on the installed 1.2.7 (captured verbatim in the
# test target's Fixtures/antigravity/help.txt, so this list can be audited against it).
#
# Every subcommand agy has is in this list, because none of them starts a session: an interactive
# Antigravity session is always a bare `agy` or `agy <flags>` with no subcommand at all. That is
# the deliberate difference from codex.sh, where `resume` and `fork` had to be excluded.
if [[ $pass_through -eq 0 && $# -gt 0 ]]; then
    case "$1" in
        agent|agents|changelog|help|install|mcp|mic-serve|models|plugin|plugins|\
remote-control|update)
            pass_through=1
            debug "subcommand '$1'; pass-through"
            ;;
    esac
fi

if [[ $pass_through -eq 0 ]]; then
    for arg in "$@"; do
        case "$arg" in
            --version|--help|-h)
                pass_through=1
                debug "flag '$arg'; pass-through"
                break
                ;;
            # `-p`/`--print`/`--prompt` run one turn non-interactively and exit. There is no
            # session for the sidebar to hold, so announcing a launch would create a row that is
            # already over. `--prompt-interactive`/`-i` is deliberately NOT here: it starts a real
            # interactive session and is exactly what tkzmux's own prompt launches use.
            -p|--print|--prompt)
                pass_through=1
                debug "print mode '$arg'; pass-through"
                break
                ;;
        esac
    done
fi

if [[ $pass_through -eq 1 ]]; then
    exec "$real" "$@"
fi

# Step 3: announce the launch, then exec the original argv completely unmodified.
#
# Which account this process belongs to follows from this directory and nothing else. It is
# `~/.gemini` -- named after the CLI Antigravity replaced, and NOT relocatable: ten candidate
# environment variables were tested against a pristine HOME during the measurement spike and none
# of them moved it, so there is no variable to honour here the way codex.sh honours CODEX_HOME.
cfg="$HOME/.gemini"

"$hook_bin" launch --pid $$ --cwd "$PWD" --config-dir "$cfg" --agent antigravity -- "$@" >/dev/null 2>&1

# Exported, not just set: the real `agy` process this line execs into inherits it, and so does
# every hook process *it* spawns for each event -- that's the entire mechanism for the relay path
# to know which agent it's relaying for, with no flag involved.
export TKZMUX_AGENT=antigravity

exec "$real" "$@"
