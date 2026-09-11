# tkzmux shell integration for fish (installed as
# ~/Library/Application Support/tkzmux/fish/tkzmux.fish). TKZ-33.
#
# tkzmux starts fish as `fish -l -C 'source <this file>'`. --init-command runs after fish has read
# the user's configuration -- config.fish, conf.d, the universal variables -- and before the first
# prompt: last in the chain, so what it puts on PATH wins over anything the user's files put there.
#
# Deliberately not an XDG_CONFIG_HOME substitute (the ticket's first idea): fish keeps its
# universal variables (fish_user_paths, abbreviations, colours) under the config directory, so a
# substituted one would lose them, and the substitute would leak to every child process (git,
# nvim). Nothing here is persisted -- no universal variables, no fish_user_paths -- so shells
# outside tkzmux and a nested `fish` are untouched; the nested one inherits PATH, which keeps the
# shim first there too.
#
# Guarded: without TKZMUX_BIN (this file sourced by hand, outside tkzmux) it does nothing.

if set -q TKZMUX_BIN; and test -n "$TKZMUX_BIN"
    # $TKZMUX_BIN first on PATH, exactly once. `set -gx PATH`, not `fish_add_path`, whose default
    # scope is the *universal* fish_user_paths -- that would persist tkzmux's bin directory into
    # every shell outside tkzmux.
    set -gx PATH $TKZMUX_BIN (string match -rv -- '^'(string escape --style=regex -- $TKZMUX_BIN)'$' $PATH)

    # Report the working directory to tkzmux as OSC 7 (`file://localhost/<percent-encoded path>`)
    # once now and on every change of $PWD, so the sidebar title follows the shell. `localhost`
    # rather than $hostname on purpose: only tkzmux reads it, and a hostname that does not match
    # what the app resolves would be dropped. Encoded per path segment: --style=url would encode
    # the slashes too.
    function __tkzmux_report_cwd --on-variable PWD
        # Only to a terminal: a `fish -c` with stdout piped must not get escape bytes in its
        # output. TKZMUX_OSC7_TO_STDOUT is the tests' way to see it.
        if not isatty stdout; and not set -q TKZMUX_OSC7_TO_STDOUT
            return 0
        end
        printf '\e]7;file://localhost%s\a' (string join / -- (string split / -- $PWD | string escape --style=url))
    end
    __tkzmux_report_cwd

    # The account the user picked in tkzmux wins over a `set -x CLAUDE_CONFIG_DIR ...` in the
    # user's own configuration, which ran before this file. Unset when no account was chosen --
    # then the user's environment decides, and the shim reports what it decided.
    if set -q TKZMUX_CLAUDE_CONFIG_DIR; and test -n "$TKZMUX_CLAUDE_CONFIG_DIR"
        set -gx CLAUDE_CONFIG_DIR $TKZMUX_CLAUDE_CONFIG_DIR
    end
end

# The command this session was opened to run: `claude --resume <id>` for a resume, a preset's
# command for a new session. Run at the *first prompt* rather than now, from a one-shot
# fish_prompt handler defined after every handler the user's configuration installed (direnv's
# among them), which is the state a command typed at the first prompt would see.
if set -q TKZMUX_BOOT_COMMAND; and test -n "$TKZMUX_BOOT_COMMAND"
    set -g __tkzmux_boot_command $TKZMUX_BOOT_COMMAND
    # Out of the environment before anything else can start: nothing this command starts --
    # claude itself, a nested shell -- may inherit it and run it a second time.
    set -e TKZMUX_BOOT_COMMAND
    function __tkzmux_run_boot_command --on-event fish_prompt
        # Remove first, run second: one shot, whatever the command does.
        functions -e __tkzmux_run_boot_command
        set -l cmd $__tkzmux_boot_command
        set -e __tkzmux_boot_command
        # Into the history, so the command behaves like one that was typed and Up repeats it.
        history append -- $cmd
        # Bracketed in OSC 9;4 progress (indeterminate, then remove) so tkzmux can tell when the
        # command has *returned* -- the only signal for a launch that fails straight back to the
        # prompt, and what takes the "Starting Claude…" overlay down in that case. Only to a
        # terminal, like the OSC 7 above. The guards sit on their own lines so the command's exit
        # status is its own.
        if isatty stdout; or set -q TKZMUX_OSC7_TO_STDOUT
            printf '\e]9;4;3\a'
        end
        eval $cmd
        if isatty stdout; or set -q TKZMUX_OSC7_TO_STDOUT
            printf '\e]9;4;0\a'
        end
    end
end
