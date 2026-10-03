# tkzmux shell integration for bash (installed as
# <support>/bash/tkzmux.bashrc, where <support> is ~/Library/Application Support/tkzmux on macOS
# and $XDG_DATA_HOME/tkzmux on Linux).
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

    # The login sequence, as bash itself would run it for `bash -l`. On Linux, bash has already
    # read the system bashrc (/etc/bash.bashrc, compiled in as SYS_BASHRC on Arch and Debian) before
    # this file, and /etc/profile sources it again whenever PS1 is set. Arch's loads
    # bash_completion with no guard, so it would load twice: when the system bashrc has loaded it
    # already, PS1 is out of the way while /etc/profile runs, and put back unless the profile set
    # one of its own. Otherwise /etc/profile runs with PS1 as before: Debian's bash.bashrc leaves
    # completion to /etc/profile.d/bash_completion.sh, which only runs with PS1 set, and macOS's
    # /bin/bash has no system bashrc of its own (/etc/profile is what reads /etc/bashrc).
    case ${OSTYPE:-} in
        darwin*)
            if [ -r /etc/profile ]; then . /etc/profile; fi
            ;;
        *)
            if [ -n "${BASH_COMPLETION_VERSINFO+set}" ]; then
                __tkzmux_ps1="${PS1-}"
                unset PS1
                if [ -r /etc/profile ]; then . /etc/profile; fi
                if [ -z "${PS1+set}" ]; then PS1="$__tkzmux_ps1"; fi
                unset __tkzmux_ps1
            elif [ -r /etc/profile ]; then
                . /etc/profile
            fi
            ;;
    esac
    if [ -r "$HOME/.bash_profile" ]; then
        . "$HOME/.bash_profile"
    elif [ -r "$HOME/.bash_login" ]; then
        . "$HOME/.bash_login"
    elif [ -r "$HOME/.profile" ]; then
        . "$HOME/.profile"
    fi

    # Two prompt hooks of Arch's system files that tkzmux has no use for, unhooked by their exact
    # text so nothing of the user's own is touched (on macOS neither exists):
    #   - /etc/bash.bashrc's `printf "\033]0;%s@%s:%s\007" ...` for an xterm-like TERM. An OSC 0
    #     title at every prompt replaces the title tkzmux derives from OSC 7 and counts as
    #     terminal activity.
    #   - /etc/profile.d/80-systemd-osc-context.sh's OSC 3008 context reports, which tkzmux
    #     ignores and which fork several subshells and a sed at every prompt and every command
    #     (8.4 ms a prompt, measured). Its PS0 part is cut too: a `$(...)` in PS0 forks even when
    #     the function returns at once.
    case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in
        "declare -a"*)
            __tkzmux_kept=()
            for __tkzmux_entry in "${PROMPT_COMMAND[@]}"; do
                case "$__tkzmux_entry" in
                    __systemd_osc_context_precmdline) ;;
                    'printf "\033]0;%s@%s:%s\007" '*) ;;
                    *) __tkzmux_kept+=("$__tkzmux_entry") ;;
                esac
            done
            PROMPT_COMMAND=(${__tkzmux_kept[@]+"${__tkzmux_kept[@]}"})
            unset __tkzmux_kept __tkzmux_entry
            ;;
    esac
    __tkzmux_ps0='$(__systemd_osc_context_ps0)'
    if [ -n "${PS0:-}" ]; then PS0=${PS0#"$__tkzmux_ps0"}; fi
    unset __tkzmux_ps0

    # $TKZMUX_BIN first on PATH, exactly once: now, and again at every prompt (below), because a
    # prompt hook installed above -- mise with `activate_aggressive`, direnv -- may put its own
    # directories in front again, and a `claude` resolved past the shim never binds its row.
    # Globbing off while PATH is split on `:`. Builtins only: this runs at every prompt.
    __tkzmux_bin_first() {
        local had_noglob="" entry rest="" ifs="$IFS"
        case $- in *f*) had_noglob=1 ;; *) set -f ;; esac
        IFS=:
        for entry in $PATH; do
            if [ "$entry" != "$TKZMUX_BIN" ]; then rest="$rest:$entry"; fi
        done
        IFS="$ifs"
        if [ -z "$had_noglob" ]; then set +f; fi
        export PATH="$TKZMUX_BIN$rest"
    }
    __tkzmux_bin_first

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
        case $PATH in
            "$TKZMUX_BIN" | "$TKZMUX_BIN":*) ;;
            *) if [ -n "${TKZMUX_BIN:-}" ]; then __tkzmux_bin_first; fi ;;
        esac
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
