#!/usr/bin/env bash
# hook-latency.sh: exec-to-exit latency of a built tkzmux-hook, the number its < 20 ms budget is
# about (CLAUDE.md). Linux only; the Mac's budget is HookBinaryTests' job.
#
# Two runs of N relay invocations each (`tkzmux-hook Stop`, a small hook payload on stdin):
#
#   socket     TKZMUX_SOCKET points at a python3 AF_UNIX listener that accepts every
#              connection and reads it to EOF, like the app's HookServer. Every frame must
#              arrive as one JSON line, or the script fails.
#   no-socket  TKZMUX_SOCKET unset: the path every hook takes while the app is not running.
#
# Every invocation runs under `env -i` with only HOME, TKZMUX_SESSION_ID and (in the first run)
# TKZMUX_SOCKET set, so a hook that needs the toolchain, LD_LIBRARY_PATH or a RUNPATH fails here.
# Each one is timed from bash with $EPOCHREALTIME, so the figure includes bash's fork, exec and
# wait. That is the overhead an agent pays per hook as well. A few untimed runs warm the page
# cache first. The script reports p50, p99 and max in milliseconds.
#
# Usage:
#   scripts/hook-latency.sh [--runs N] [--budget] [<hook>]
#
#   <hook>      the binary to time (default: .build/release/tkzmux-hook)
#   --runs N    invocations per run (default 200)
#   --budget    fail unless socket p50 < 3 ms, socket p99 < 20 ms and no-socket p50 < 3 ms
#               (WOR-305 S6, measured on the reference machine; docs/linux/hook.md)
#   -h, --help  show this help
#
# Exit status: 0 = measured (and within budget with --budget), 1 = a frame was lost or the
# budget was missed, 2 = usage or setup error.
#
# Example (the shipped musl hook, docs/linux/hook.md):
#   swift build -c release --product tkzmux-hook --swift-sdk x86_64-swift-linux-musl
#   scripts/hook-latency.sh --budget .build/x86_64-swift-linux-musl/release/tkzmux-hook
set -uo pipefail
export LC_ALL=C

if [ -z "${EPOCHREALTIME:-}" ]; then
  echo "hook-latency: needs bash >= 5 (EPOCHREALTIME)" >&2
  exit 2
fi

runs=200
budget=0
hook=""

usage() { sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }
die() { echo "hook-latency: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --runs) [ $# -ge 2 ] || die "--runs needs a number"; runs="$2"; shift 2 ;;
    --runs=*) runs="${1#--runs=}"; shift ;;
    --budget) budget=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) [ -z "$hook" ] || die "one hook per run"; hook="$1"; shift ;;
  esac
done

case "$runs" in ''|*[!0-9]*|0) die "--runs must be a positive integer" ;; esac
if [ -z "$hook" ]; then
  hook="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.build/release/tkzmux-hook"
fi
[ -x "$hook" ] || die "no executable hook at $hook (build it first, see --help)"
hook="$(realpath "$hook")"
command -v python3 >/dev/null || die "needs python3 for the AF_UNIX listener"

work="$(mktemp -d "${TMPDIR:-/tmp}/tkzmux-hook-latency.XXXXXX")" || die "mktemp failed"
listener_pid=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  [ -n "$listener_pid" ] && kill "$listener_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

sock="$work/hook.sock"
payload="$work/payload.json"
printf '{"session_id":"latency","hook_event_name":"Stop","cwd":"/tmp","stop_hook_active":false}\n' > "$payload"

# Counts frames until SIGTERM, then prints "<frames> <valid JSON lines>".
python3 - "$sock" > "$work/listener.out" <<'PY' &
import json, signal, socket, sys
frames = valid = 0
def stop(*_):
    print(frames, valid, flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen(512)
while True:
    conn, _ = server.accept()
    data = b""
    while chunk := conn.recv(65536):
        data += chunk
    conn.close()
    frames += 1
    try:
        if data.endswith(b"\n") and data.count(b"\n") == 1:
            json.loads(data)
            valid += 1
    except ValueError:
        pass
PY
listener_pid=$!

for _ in $(seq 100); do
  [ -S "$sock" ] && break
  sleep 0.05
done
[ -S "$sock" ] || die "the python3 listener did not come up"

# One run: N timed invocations, durations in microseconds into $1.
time_run() {
  local out="$1"; shift
  local i t0 t1
  : > "$out"
  for ((i = 0; i < runs; i++)); do
    t0="$EPOCHREALTIME"
    env -i "$@" "$hook" Stop < "$payload" > /dev/null
    t1="$EPOCHREALTIME"
    echo "$(( ${t1/./} - ${t0/./} ))" >> "$out"
  done
}

# p50/p99/max of a run file, in milliseconds (nearest rank).
stats() {
  sort -n "$1" | awk '{ v[NR] = $1 }
    function rank(p) { r = int((p * NR + 99) / 100); return r < 1 ? 1 : r }
    END { printf "p50 %.2f ms  p99 %.2f ms  max %.2f ms  (n=%d)\n", v[rank(50)] / 1000, v[rank(99)] / 1000, v[NR] / 1000, NR }'
}
pct_us() { sort -n "$1" | awk -v p="$2" '{ v[NR] = $1 } END { r = int((p * NR + 99) / 100); print v[r < 1 ? 1 : r] }'; }

base_env=(HOME="$work" TKZMUX_SESSION_ID=latency)
for _ in 1 2 3 4 5; do env -i "${base_env[@]}" "$hook" Stop < "$payload" > /dev/null; done

time_run "$work/socket.us" "${base_env[@]}" TKZMUX_SOCKET="$sock"
time_run "$work/nosocket.us" "${base_env[@]}"

kill -TERM "$listener_pid"
wait "$listener_pid" 2>/dev/null
listener_pid=""
read -r frames valid < "$work/listener.out" || { frames=0; valid=0; }

echo "hook       $hook"
echo "size       $(stat -c %s "$hook") bytes"
echo "socket     $(stats "$work/socket.us")"
echo "no-socket  $(stats "$work/nosocket.us")"
echo "frames     $valid valid of $frames received, $runs sent"

status=0
if [ "$frames" -ne "$runs" ] || [ "$valid" -ne "$runs" ]; then
  echo "hook-latency: FAIL: the listener got $valid valid frames of $runs" >&2
  status=1
fi
if [ "$budget" -eq 1 ]; then
  s50="$(pct_us "$work/socket.us" 50)"; s99="$(pct_us "$work/socket.us" 99)"; n50="$(pct_us "$work/nosocket.us" 50)"
  if [ "$s50" -ge 3000 ] || [ "$s99" -ge 20000 ] || [ "$n50" -ge 3000 ]; then
    echo "hook-latency: FAIL: over budget (socket p50 < 3 ms, p99 < 20 ms; no-socket p50 < 3 ms)" >&2
    status=1
  else
    echo "budget     ok (socket p50 < 3 ms, p99 < 20 ms; no-socket p50 < 3 ms)"
  fi
fi
exit "$status"
