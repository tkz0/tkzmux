#!/bin/bash
# tkzmux's `claude` shim. Installed at `$TKZMUX_BIN/claude` by ShimInstaller; the ZDOTDIR wrapper
# (`zshrc`) puts `$TKZMUX_BIN` first on PATH, after the user's own rc files ran. See
# docs/design.md -> Claude integration -> Shim install, Shim.
#
# Job: find the *real* claude, inject tkzmux's hooks via `--settings`, announce our pid over the
# socket, then exec the real binary. Outside a tkzmux session (no TKZMUX_SESSION_ID/SOCKET) or for
# anything we don't understand, this must be a no-op pass-through -- never break `claude`.
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

# Step 1: find the real claude on PATH, skipping ourselves.
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

    candidate="$dir/claude"
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
    echo "claude: command not found (tkzmux shim)" >&2
    exit 127
fi
debug "real claude resolved to $real"

# Step 2: decide whether to pass through untouched.
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

if [[ $pass_through -eq 0 && $# -gt 0 ]]; then
    case "$1" in
        agents|attach|auth|auto-mode|doctor|gateway|import|install|logs|mcp|plugin|plugins|project|respawn|rm|setup-token|stop|kill|ultrareview|update|upgrade)
            pass_through=1
            debug "subcommand '$1'; pass-through"
            ;;
    esac
fi

if [[ $pass_through -eq 0 ]]; then
    for arg in "$@"; do
        case "$arg" in
            -p|--print|--bare|--safe-mode|-v|--version|-h|--help)
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

# Step 3: strip --settings from the args, remembering the last value; merge; launch; exec.
args=()
user_settings=""
skip_next=0
for arg in "$@"; do
    if [[ $skip_next -eq 1 ]]; then
        user_settings="$arg"
        skip_next=0
        continue
    fi
    case "$arg" in
        --settings)
            skip_next=1
            ;;
        --settings=*)
            user_settings="${arg#--settings=}"
            ;;
        *)
            args+=("$arg")
            ;;
    esac
done

merged="$("$hook_bin" settings-merge "$user_settings" 2>/dev/null)"
merge_status=$?

if [[ $merge_status -ne 0 || -z "$merged" ]]; then
    debug "settings-merge failed (status $merge_status); exec original argv"
    exec "$real" "$@"
fi

debug "merged settings: $merged"
"$hook_bin" launch --pid $$ --cwd "$PWD" -- "$@" >/dev/null 2>&1

# macOS ships bash 3.2 as /bin/bash, where `"${args[@]}"` on an *empty* array is itself an
# unbound-variable error under `set -u` (fixed in bash 4.4+, but this must work on 3.2 too).
exec "$real" "${args[@]+"${args[@]}"}" --settings "$merged"
