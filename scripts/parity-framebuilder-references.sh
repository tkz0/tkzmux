#!/usr/bin/env bash
# parity-framebuilder-references.sh: write the L2 parity references (WOR-322 S3; ADR-0003 §3, L2).
#
#   scripts/parity-framebuilder-references.sh [--check] [--out DIR]
#
#   --check     write into a temporary directory and fail unless it equals the committed set byte
#               for byte (the determinism check; nothing in the tree changes)
#   --out DIR   where the set goes (default: Tests/Parity/References/framebuilder)
#
# For each fixture L2 replays (the four Tests/TkzTerminalCoreTests/Fixtures recordings and
# Tests/Parity/Fixtures/l2-features.tkzrec) and each gated scale (1.6, 2.0), the release
# `tkzmux-vtdump framedump` writes <fixture>@<scale>.json (cell metrics and atlas glyph table) and
# <fixture>@<scale>.bin (FrameBuilder's instance buffers) over the platform's font stack:
#
#   macOS   CoreText. This is the reference set: WOR-322 S2's `make parity-references` runs this
#           script on the reference runner (ADR-0003 §5) and the set is committed from there.
#   Linux   FreeType with the pinned parity fonts (scripts/fetch-parity-fonts.sh). Only the
#           bootstrap set that enforces L2 until S2 lands; the dumps record which platform made them.
#
# Either way the Linux runner (Tests/TkzParityRunnerTests) replays every dump from its glyph table
# and requires the same buffers. Exit status: 0 = written (or, with --check, identical), 1 = a
# build, dump or comparison failure, 2 = usage.
set -euo pipefail
export LC_ALL=C

die() { echo "parity-framebuilder-references: $*" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
committed="$root/Tests/Parity/References/framebuilder"
out="$committed"
check=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1; shift ;;
    --out) [ $# -ge 2 ] || die "--out needs a directory"; out="$2"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done

cd "$root"
build=(swift build -c release --product tkzmux-vtdump)
fonts=()
case "$(uname -s)" in
  Darwin) ;;
  Linux) build+=(--build-system native); fonts=(--fonts parity) ;;
  *) die "macOS or Linux only" ;;
esac
"${build[@]}"
vtdump="$("${build[@]}" --show-bin-path)/tkzmux-vtdump"

recordings=(
  Tests/TkzTerminalCoreTests/Fixtures/claude-boot.tkzrec
  Tests/TkzTerminalCoreTests/Fixtures/claude-tool-run.tkzrec
  Tests/TkzTerminalCoreTests/Fixtures/synthetic-basic.tkzrec
  Tests/TkzTerminalCoreTests/Fixtures/zsh-ls-color.tkzrec
  Tests/Parity/Fixtures/l2-features.tkzrec
)

if [ "$check" = 1 ]; then
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
fi
mkdir -p "$out"
find "$out" -maxdepth 1 -type f \( -name '*@*.json' -o -name '*@*.bin' \) -delete
# `${fonts[@]+"${fonts[@]}"}`: on macOS `fonts` is empty, and expanding an empty array is an
# unbound-variable error under `set -u` in bash 3.2 (/bin/bash there).
for scale in 1.6 2.0; do
  "$vtdump" framedump ${fonts[@]+"${fonts[@]}"} --scale "$scale" --out "$out" "${recordings[@]}"
done

if [ "$check" = 1 ]; then
  if diff -r "$committed" "$out" > /dev/null; then
    echo "parity-framebuilder-references: identical to $committed"
  else
    diff -rq "$committed" "$out" >&2 || true
    echo "parity-framebuilder-references: differs from the committed set" >&2
    exit 1
  fi
fi
