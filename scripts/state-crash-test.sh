#!/usr/bin/env bash
# The M5.1 / TKZ-29 crash acceptance: "a loop that mutates and sends SIGKILL at random points 50
# times never produces an unparsable state.json (the file is either the old or the new complete
# version)". See docs/design.md → *Session flows & persistence* and docs/manual-checks.md.
#
#   scripts/state-crash-test.sh [rounds]      # default 50
#
# Each round runs `tkzmux-vtdump state-churn`, which saves as fast as it can, kills it with SIGKILL
# after a random delay, and then checks what survived. Half the rounds start from the
# "primary missing, .bak present" state on purpose: that is the one a naive rotation
# (`unlink(.bak); link(primary, .bak)`) loses, and it is invisible to a test that always starts
# from a complete pair.
set -euo pipefail

cd "$(dirname "$0")/.."
rounds="${1:-50}"
work="$(mktemp -d "${TMPDIR:-/tmp}/tkzmux-state-crash.XXXXXX")"
# Kept only when something failed, so a failure is still inspectable; see the trap below.
keep=0
trap '[ "$keep" -eq 1 ] || rm -rf "$work"' EXIT

echo "==> building tkzmux-vtdump (release)"
swift build -c release --product tkzmux-vtdump >/dev/null
churn="$(swift build -c release --product tkzmux-vtdump --show-bin-path)/tkzmux-vtdump"

# Parses as a v1 state file with the keys the schema requires. `plutil -extract` reads JSON and is
# on every macOS, so this needs no python and no jq. (`plutil -lint` is not usable here: it assumes
# a property list and rejects a perfectly good JSON object.)
parses() {
  [ "$(plutil -extract schemaVersion raw -o - "$1" 2>/dev/null)" = "1" ] || return 1
  plutil -extract groups raw -o - "$1" >/dev/null 2>&1 || return 1
  plutil -extract sessions raw -o - "$1" >/dev/null 2>&1 || return 1
  plutil -extract sidebar raw -o - "$1" >/dev/null 2>&1 || return 1
}

failures=0
for ((round = 1; round <= rounds; round++)); do
  dir="$work/round-$round"
  mkdir -p "$dir"

  # Seed the round so the churn starts from a real file about half the time, and from the
  # recovery-shaped state (no primary, good backup) a quarter of the time.
  "$churn" state-churn "$dir" --iterations 40 --seed "$round" >/dev/null 2>&1 || true
  case $((round % 4)) in
    2) rm -f "$dir/state.json" ;;                       # primary missing, .bak present
    3) rm -f "$dir/state.json" "$dir/state.json.bak" ;; # nothing at all
  esac

  "$churn" state-churn "$dir" --seed "$((round * 7))" >/dev/null 2>&1 &
  pid=$!
  # 5-120 ms: long enough to be mid-save, short enough that 50 rounds take a couple of seconds.
  perl -e "select undef, undef, undef, (5 + int(rand(115))) / 1000"
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  survivors=0
  for candidate in "$dir/state.json" "$dir/state.json.bak"; do
    [ -f "$candidate" ] || continue
    if parses "$candidate"; then
      survivors=$((survivors + 1))
    else
      echo "FAIL round $round: $candidate does not parse"
      keep=1
      failures=$((failures + 1))
    fi
  done

  # A SIGKILL between the two renames can strand the staged backup or an unfinished temp file.
  # Neither is dangerous, but the next launch must clean them up rather than leave litter in
  # Application Support forever — so run the loader once, as a launch would, and check.
  "$churn" state-churn "$dir" --iterations 0 >/dev/null 2>&1 || true
  for litter in "$dir"/state.json.bak.new "$dir"/.state.*.tmp; do
    [ -e "$litter" ] || continue
    echo "FAIL round $round: $(basename "$litter") survived the next launch"
    keep=1
    failures=$((failures + 1))
  done

  if [ "$survivors" -eq 0 ]; then
    echo "FAIL round $round: no readable state left at all"
    keep=1
    failures=$((failures + 1))
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "==> $failures failure(s) over $rounds rounds; the evidence is in $work"
  exit 1
fi
echo "==> $rounds rounds, every survivor parsed, no round lost its state"
