#!/usr/bin/env bash
# parity-chrome-references.sh: write the Mac chrome metrics reference (WOR-312 S2; ADR-0003 §5).
#
#   scripts/parity-chrome-references.sh [--check] [--out FILE] [--regenerate] [--unofficial]
#
#   --check        write into a temporary file and fail unless it equals the committed one byte for
#                  byte (the determinism check; nothing in the tree changes)
#   --out FILE     where the dump goes (default: Tests/Parity/References/fonts/chrome-metrics.json)
#   --regenerate   allow a runner image other than the one the committed file names
#   --unofficial   run outside a hosted runner; needs --out, so such a dump never lands in the tree
#
# The dump is a test: ChromeMetricsDumpTests (Tests/TkzAppTests), which runs only when
# TKZMUX_CHROME_METRICS_OUT names its output and is skipped by every other `swift test`. It
# measures every DesignTokens typography role and the chrome's inline fonts through
# Theme.Fonts.ui/mono (metrics, and the advances of a fixed corpus, printable ASCII and the
# symbols), SessionRowView's detail-line width and wrap grid, and StatusBarView's visibility and
# truncation grid. Its header lists the fields; docs/linux/parity.md, "The font references".
#
# macOS only, and only on the reference runner (ADR-0003 §5): the GitHub-hosted macos-26 image
# with Xcode 26.1, through .github/workflows/font-references.yml. The file shares
# Tests/Parity/References/fonts/ with scripts/parity-font-references.sh (WOR-312 S1), which never
# touches it; the runner it came from is the file's own `reference` block. WOR-322 S2's
# `make parity-references` calls this script unchanged.
# Exit status: 0 = written (or, with --check, identical), 1 = a build, dump or comparison failure,
# 2 = usage or refused.
set -euo pipefail
export LC_ALL=C

die() { echo "parity-chrome-references: $*" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
committed="$root/Tests/Parity/References/fonts/chrome-metrics.json"
out="$committed"
out_given=0
check=0
regenerate=0
unofficial=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1; shift ;;
    --out) [ $# -ge 2 ] || die "--out needs a file"; out="$2"; out_given=1; shift 2 ;;
    --regenerate) regenerate=1; shift ;;
    --unofficial) unofficial=1; shift ;;
    *) die "unknown argument $1" ;;
  esac
done

case "$out" in /*) ;; *) out="$PWD/$out" ;; esac  # before the cd below

[ "$(uname -s)" = Darwin ] || die "macOS only: the chrome metrics are AppKit's (ADR-0003 §5)"
if [ -z "${CI:-}" ] || [ -z "${ImageOS:-}" ]; then
  [ "$unofficial" = 1 ] || die "refusing outside a hosted runner (CI and ImageOS unset); --unofficial --out FILE writes a dump to look at"
  [ "$out_given" = 1 ] && [ "$check" = 0 ] || die "--unofficial needs --out FILE and no --check: an unofficial dump never replaces $committed"
fi
committed_image() { sed -n 's/.*"imageVersion":"\([^"]*\)".*/\1/p' "$1" | head -n 1; }
if [ -f "$committed" ] && [ "$regenerate" = 0 ] && [ "$unofficial" = 0 ]; then
  pinned="$(committed_image "$committed")"
  if [ -n "$pinned" ] && [ "$pinned" != "${ImageVersion:-}" ]; then
    die "the committed dump comes from image $pinned, this is ${ImageVersion:-unset}; pass --regenerate to replace it"
  fi
fi

cd "$root"
swift build --build-tests

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
target="$out"
[ "$check" = 1 ] && target="$work/chrome-metrics.json"
rm -f "$target"

# The summary-line guard of ci-linux.yml: `swift test` can exit 0 mid-run
# (Tests/TkzAppTests/SheetTestSupport.swift), which here would leave no file or a stale one.
log="$work/test.log"
TKZMUX_CHROME_METRICS_OUT="$target" swift test --skip-build --no-parallel --filter ChromeMetricsDump 2>&1 | tee "$log"
if ! grep -Eq 'Test run with [1-9][0-9]* tests? .*passed' <(sed 's/\x1b\[[0-9;]*m//g' "$log"); then
  echo "parity-chrome-references: no passing 'Test run with N tests' line: the run ended early or failed" >&2
  exit 1
fi
[ -s "$target" ] || { echo "parity-chrome-references: the test passed but wrote no $target" >&2; exit 1; }
plutil -convert xml1 -o /dev/null "$target" || { echo "parity-chrome-references: wrote invalid JSON" >&2; exit 1; }
echo "parity-chrome-references: $(stat -f %z "$target") bytes in $target"

if [ "$check" = 1 ]; then
  [ -f "$committed" ] || { echo "parity-chrome-references: nothing committed to check against" >&2; exit 1; }
  if cmp -s "$committed" "$target"; then
    echo "parity-chrome-references: identical to $committed"
  else
    diff "$committed" "$target" | head -n 40 >&2 || true
    echo "parity-chrome-references: differs from the committed dump" >&2
    exit 1
  fi
fi
