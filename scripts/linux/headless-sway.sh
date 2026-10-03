#!/usr/bin/env bash
# headless-sway.sh — run a command against a private, headless sway (WOR-314 S2).
#
#   scripts/linux/headless-sway.sh <command> [args…]
#
# Starts sway with the headless wlroots backend and the pixman renderer (no GPU, no seat, no
# input devices), waits for its Wayland socket, runs the command with WAYLAND_DISPLAY pointing at
# it and GDK_BACKEND=wayland, then stops sway. Exits with the command's status. The sway log is
# printed when sway fails to start, or when TKZMUX_SWAY_LOG=1.
#
# The asan-valgrind CI job runs the GTK window tests through it, inside `dbus-run-session`. It is
# safe inside a desktop session too: the session's WAYLAND_DISPLAY, DISPLAY and SWAYSOCK are
# dropped for sway, so nothing appears on screen. Without an XDG_RUNTIME_DIR (a CI container
# running as root) it makes a private one.
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "usage: $0 <command> [args…]" >&2
  exit 64
fi
if ! command -v sway > /dev/null; then
  echo "headless-sway.sh: sway is not installed (Arch: sway; docs/linux/dev.md)" >&2
  exit 127
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/tkzmux-sway.XXXXXX")"
runtime="${XDG_RUNTIME_DIR:-}"
if [ -z "$runtime" ] || [ ! -w "$runtime" ]; then
  runtime="$work/runtime"
  mkdir -m 0700 "$runtime"
fi

# sway names its socket itself (the first free wayland-N); the config's exec reports it. No
# background client either.
ready="$work/wayland-display"
cat > "$work/config" << EOF
swaybg_command -
exec printenv WAYLAND_DISPLAY > "$ready.tmp" && mv "$ready.tmp" "$ready"
EOF

env -u WAYLAND_DISPLAY -u DISPLAY -u SWAYSOCK -u I3SOCK \
  XDG_RUNTIME_DIR="$runtime" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
  sway --config "$work/config" > "$work/sway.log" 2>&1 &
sway_pid=$!

# shellcheck disable=SC2329  # invoked by the EXIT trap
stop() {
  kill "$sway_pid" 2> /dev/null || true
  wait "$sway_pid" 2> /dev/null || true
  if [ "${TKZMUX_SWAY_LOG:-}" = 1 ]; then cat "$work/sway.log" >&2; fi
  rm -rf "$work"
}
trap stop EXIT

for _ in $(seq 200); do
  [ -s "$ready" ] && break
  if ! kill -0 "$sway_pid" 2> /dev/null; then
    echo "headless-sway.sh: sway exited before its socket was ready:" >&2
    cat "$work/sway.log" >&2
    exit 1
  fi
  sleep 0.05
done
if [ ! -s "$ready" ]; then
  echo "headless-sway.sh: sway's socket was not ready after 10 s:" >&2
  cat "$work/sway.log" >&2
  exit 1
fi

status=0
XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY="$(cat "$ready")" GDK_BACKEND=wayland "$@" || status=$?
exit "$status"
