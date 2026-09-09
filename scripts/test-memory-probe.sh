#!/bin/bash
# Runs each test target on its own and watches how much memory the test helper takes.
#
# Why this exists: on 2026-09-09 a plain `swift test` grew a single `swiftpm-testing-helper`
# to 19-48 GB and then stalled holding it, which took a 36 GB machine deep into swap. macOS
# blamed tkzmux, because a helper started from a tkzmux terminal inherits the app's process
# coalition and both jetsam and Activity Monitor bill a coalition to its leader.
# See docs/perf.md -> "Test-suite memory".
#
# The failure is a *stall*, so there are two trip wires: a footprint cap and a wall clock.
# Whichever fires first, the helper is diagnosed (vmmap/heap/sample) *before* it is killed --
# a process sitting on 40 GB will tell you what it is holding, which beats bisecting for it.
#
# Usage:
#   scripts/test-memory-probe.sh                  # every target, serially
#   scripts/test-memory-probe.sh TkzAppTests ...  # just these
#
# Knobs (env):
#   LIMIT_MB   RSS cap per test tree, default 4096
#   TIMEOUT_S  wall clock per target, default 420
#   OUT_DIR    where reports land,    default .build/memory-probe

set -uo pipefail
cd "$(dirname "$0")/.."

LIMIT_MB="${LIMIT_MB:-4096}"
TIMEOUT_S="${TIMEOUT_S:-420}"
OUT_DIR="${OUT_DIR:-.build/memory-probe}"
# 0.1 s, not 1 s: several targets finish in about a second, and at a 1 s poll their peak was
# missed entirely — the first sample caught only the `swift` driver, before the test helper had
# even forked, and reported a 99-test suite as peaking at 4 MB. One `ps` per tick is cheap.
POLL_S="${POLL_S:-0.1}"

DEFAULT_TARGETS=(
  TkzCoreTests PersistenceTests ClaudeBridgeTests GitStatusTests
  TkzTerminalCoreTests TkzTerminalRenderTests TkzTerminalViewTests TkzAppTests
)
# `ALL` means the unfiltered `swift test` — every test in one helper process, which is the
# shape that actually blew up. Running one target at a time bounds the concurrency and hides it.
if [ "$#" -gt 0 ]; then TARGETS=("$@"); else TARGETS=("${DEFAULT_TARGETS[@]}"); fi

mkdir -p "$OUT_DIR"

# Every descendant of the pids in $1, breadth-first, including them.
# Depth-bounded: the real chain is deep (zsh -> claude -> bash -> swift-package -> helper)
# but it must still terminate if the table is odd.
descendants() {
  local roots="$1" out="$1" depth=0 kids
  while [ -n "$roots" ] && [ "$depth" -lt 12 ]; do
    # `ps` output is newline-separated; awk -v cannot take a newline in its value, so every
    # pid list is flattened to spaces before it is handed over.
    kids=$(ps -eo pid=,ppid= | awk -v r="$(echo $roots)" '
      BEGIN { n = split(r, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
      want[$2] { print $1 }' | tr '\n' ' ')
    kids="$(echo $kids)"
    [ -z "$kids" ] && break
    out="$out $kids"; roots="$kids"; depth=$((depth + 1))
  done
  echo $out
}

# "totalMB biggestMB biggestComm biggestPid" over a pid list.
tree_rss_mb() {
  local list
  list=$(echo "$1" | tr ' ' ',')
  ps -o rss=,pid=,comm= -p "$list" 2>/dev/null | awk '
    { total += $1; if ($1 > topRss) { topRss = $1; topPid = $2; topComm = $3 } }
    END {
      n = split(topComm, parts, "/")
      printf "%d %d %s %d\n", total/1024, topRss/1024, (n ? parts[n] : "-"), topPid
    }'
}

# Run a command with a hard deadline; macOS ships no timeout(1).
run_capped() {
  local secs="$1"; shift
  "$@" & local p=$!
  ( sleep "$secs"; kill -9 "$p" 2>/dev/null ) & local w=$!
  wait "$p" 2>/dev/null; local rc=$?
  kill -9 "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}

diagnose() {
  local pid="$1" target="$2" reason="$3" rssmb="$4"
  local stem="$OUT_DIR/$target"
  echo "  !! $reason at ${rssmb} MB (pid $pid) -- capturing diagnostics"
  {
    echo "target=$target reason=$reason rss_mb=$rssmb pid=$pid date=$(date -Iseconds)"
    ps -o pid=,ppid=,rss=,etime=,comm= -p "$pid" 2>/dev/null
  } > "$stem.summary.txt"
  # vmmap says *which kind* of memory (MALLOC vs IOSurface vs graphics); heap says the
  # allocation classes and sizes; sample says the stack it is stuck in.
  run_capped 60 sh -c "vmmap -summary '$pid' > '$stem.vmmap.txt' 2>&1"
  run_capped 90 sh -c "heap '$pid' > '$stem.heap.txt' 2>&1"
  run_capped 60 sh -c "sample '$pid' 2 -file '$stem.sample.txt' >/dev/null 2>&1"
  echo "  !! wrote $stem.{summary,vmmap,heap,sample}.txt"
}

# Build tests once up front so build time is not charged to any target's wall clock.
echo "== building tests"
if ! swift build --build-tests > "$OUT_DIR/build.log" 2>&1; then
  echo "build failed; see $OUT_DIR/build.log"
  tail -20 "$OUT_DIR/build.log"
  exit 1
fi

printf '\n%-26s %10s %16s %8s  %s\n' TARGET PEAK_MB BIGGEST SECS OUTCOME
printf '%s\n' "--------------------------------------------------------------------------------"
overall=0

for target in "${TARGETS[@]}"; do
  if [ "$target" = "ALL" ]; then
    swift test > "$OUT_DIR/ALL.log" 2>&1 &
  else
    swift test --filter "$target" > "$OUT_DIR/$target.log" 2>&1 &
  fi
  runner=$!
  peak=0; biggest="-"; outcome=""; started=$SECONDS

  while kill -0 "$runner" 2>/dev/null; do
    tree=$(descendants "$runner")
    read -r total topmb topcomm toppid <<< "$(tree_rss_mb "$tree")"
    total="${total:-0}"
    if [ "$total" -gt "$peak" ]; then peak="$total"; biggest="$topcomm:${topmb}M"; fi

    if [ "$total" -ge "$LIMIT_MB" ]; then
      diagnose "${toppid:-$runner}" "$target" "RSS cap" "$total"
      outcome="OVER LIMIT (${total} MB)"; break
    fi
    if [ $((SECONDS - started)) -ge "$TIMEOUT_S" ]; then
      diagnose "${toppid:-$runner}" "$target" "wall-clock timeout" "$total"
      outcome="STALLED (${TIMEOUT_S}s, ${total} MB)"; break
    fi
    sleep "$POLL_S"
  done

  if [ -n "$outcome" ]; then
    for p in $(descendants "$runner"); do kill -9 "$p" 2>/dev/null; done
    wait "$runner" 2>/dev/null
    overall=1
  else
    wait "$runner"; rc=$?
    if [ "$rc" -eq 0 ]; then outcome="passed"; else outcome="test failures (exit $rc)"; fi
  fi

  printf '%-26s %10s %16s %8s  %s\n' "$target" "$peak" "$biggest" "$((SECONDS - started))" "$outcome"
done

echo
echo "logs and reports: $OUT_DIR"
exit $overall
