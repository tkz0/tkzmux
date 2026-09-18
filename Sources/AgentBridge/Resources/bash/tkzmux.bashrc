# tkzmux shell integration for bash (installed as
# ~/Library/Application Support/tkzmux/bash/tkzmux.bashrc).
#
# tkzmux starts bash as `bash --rcfile <this file>`: an *interactive non-login* shell, because a
# login bash reads the profile files and ignores --rcfile (man bash, INVOCATION). So this file
# reproduces the login sequence itself -- /etc/profile, then the first readable one of
# ~/.bash_profile, ~/.bash_login, ~/.profile, and *not* ~/.bashrc, which a login shell would not
# read either -- and only then does tkzmux's part, last in the chain so it wins over anything
# those files put on PATH (brew shellenv, ~/.local/bin/env). What differs from a real login shell:
# `shopt -q login_shell` is false and $0 is `bash`.
#
# Guarded: without TKZMUX_BIN (this file sourced by hand, outside tkzmux) it does nothing at all.
# Nothing here is exported and BASH_ENV is never set, so a nested `bash` is a normal shell; it
# inherits PATH, which is what keeps the shim first there too. Written for bash 3.2 (/bin/bash):
# no associative arrays, no ${var,,}, no ;& -- and an array PROMPT_COMMAND (5.1+) is handled.

if [ -n "${TKZMUX_BIN:-}" ]; then
    # The command this session was opened to run (`claude --resume <id>`, `claude -w`). Out of the
    # environment before anything else can start: nothing the profile files or the command itself
    # start may inherit it and run it a second time. Run at the first prompt, not here -- see the
    # hook below.
    if [ -n "${TKZMUX_BOOT_COMMAND:-}" ]; then
        __tkzmux_boot_command="$TKZMUX_BOOT_COMMAND"
        unset TKZMUX_BOOT_COMMAND
    fi

    # The login sequence, as bash itself would run it for `bash -l`.
    if [ -r /etc/profile ]; then . /etc/profile; fi
    if [ -r "$HOME/.bash_profile" ]; then
        . "$HOME/.bash_profile"
    elif [ -r "$HOME/.bash_login" ]; then
        . "$HOME/.bash_login"
    elif [ -r "$HOME/.profile" ]; then
        . "$HOME/.profile"
    fi

    # $TKZMUX_BIN first on PATH, exactly once. Globbing off while PATH is split on `:`.
    case $- in *f*) __tkzmux_had_noglob=1 ;; *) __tkzmux_had_noglob=; set -f ;; esac
    __tkzmux_path=""
    __tkzmux_ifs="$IFS"
    IFS=:
    for __tkzmux_entry in $PATH; do
        if [ "$__tkzmux_entry" != "$TKZMUX_BIN" ]; then
            __tkzmux_path="$__tkzmux_path:$__tkzmux_entry"
        fi
    done
    IFS="$__tkzmux_ifs"
    if [ -z "$__tkzmux_had_noglob" ]; then set +f; fi
    export PATH="$TKZMUX_BIN$__tkzmux_path"
    unset __tkzmux_path __tkzmux_ifs __tkzmux_entry __tkzmux_had_noglob

    # Report the working directory to tkzmux as OSC 7 (`file://localhost/<percent-encoded path>`)
    # once now and from every prompt whose directory changed, so the sidebar title follows the
    # shell. `localhost` rather than $HOSTNAME on purpose: only tkzmux reads it, and a hostname that
    # does not match what the app resolves would be dropped.
    __tkzmux_report_cwd() {
        # Only to a terminal: a `bash -c` with stdout piped must not get escape bytes in its
        # output. TKZMUX_OSC7_TO_STDOUT is the tests' way to see it.
        [ -t 1 ] || [ -n "${TKZMUX_OSC7_TO_STDOUT:-}" ] || return 0
        local LC_ALL=C
        local encoded="" ch
        local -i i
        for (( i = 0; i < ${#PWD}; i++ )); do
            ch="${PWD:i:1}"
            case "$ch" in
                [A-Za-z0-9/._~-]) encoded="$encoded$ch" ;;
                *) printf -v ch '%%%02X' "'$ch"; encoded="$encoded$ch" ;;
            esac
        done
        printf '\033]7;file://localhost%s\007' "$encoded"
    }

    __tkzmux_precmd() {
        if [ "${__tkzmux_last_pwd:-}" != "$PWD" ]; then
            __tkzmux_last_pwd="$PWD"
            __tkzmux_report_cwd
        fi
        # One shot, whatever the command does: forget it first, run it second. Into the history
        # so it behaves like a typed command and Up repeats it. Bracketed in OSC 9;4 progress
        # (indeterminate, then remove) so tkzmux can tell when the command has *returned* -- the
        # only signal for a launch that fails straight back to the prompt. The guards sit on their
        # own lines so the command's exit status is its own.
        if [ -n "${__tkzmux_boot_command:-}" ]; then
            local cmd="$__tkzmux_boot_command"
            unset __tkzmux_boot_command
            history -s -- "$cmd"
            if [ -t 1 ] || [ -n "${TKZMUX_OSC7_TO_STDOUT:-}" ]; then printf '\033]9;4;3\007'; fi
            eval "$cmd"
            if [ -t 1 ] || [ -n "${TKZMUX_OSC7_TO_STDOUT:-}" ]; then printf '\033]9;4;0\007'; fi
        fi
    }
    __tkzmux_last_pwd="$PWD"
    __tkzmux_report_cwd

    # Appended *after* whatever the profile files installed (direnv prepends its own hook), which
    # is the state a command typed at the first prompt would see. Joined with a newline, not `;`,
    # so a PROMPT_COMMAND that already ends in `;` stays valid; an array PROMPT_COMMAND (bash 5.1+)
    # gets one more element.
    case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in
        "declare -a"*) PROMPT_COMMAND+=(__tkzmux_precmd) ;;
        *) PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND
}__tkzmux_precmd" ;;
    esac

    # Whatever the account picked in tkzmux needs re-exported (`CLAUDE_CONFIG_DIR`, or a future
    # agent's own variable) wins over the same name set in the user's own profile, which ran
    # above -- that is the whole point of running this after it rather than before. TKZMUX_REEXPORT
    # names the variables (space separated); TKZMUX_ENV_<NAME> carries each one's value. Nothing
    # here when no account was chosen -- then the user's environment decides, and the shim reports
    # what it decided. `${!var}` (bash's indirect expansion) works on bash 3.2, which is what
    # /bin/bash is on macOS; `declare -n` namerefs do not, so they are avoided here.
    if [ -n "${TKZMUX_REEXPORT:-}" ]; then
        for __tkzmux_reexport_name in $TKZMUX_REEXPORT; do
            __tkzmux_reexport_var="TKZMUX_ENV_${__tkzmux_reexport_name}"
            __tkzmux_reexport_value="${!__tkzmux_reexport_var}"
            if [ -n "$__tkzmux_reexport_value" ]; then
                export "${__tkzmux_reexport_name}=${__tkzmux_reexport_value}"
            fi
        done
        unset __tkzmux_reexport_name __tkzmux_reexport_var __tkzmux_reexport_value
    fi
fi
