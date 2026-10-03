#!/usr/bin/env bash
# parity-export-mac.sh: write the Mac parity references (WOR-322 S2; ADR-0003 §5). `make
# parity-references` runs it.
#
#   scripts/parity-export-mac.sh [--check] [--regenerate] [--unofficial --out DIR]
#
#   --check        write everything again into temporary locations and fail unless it equals the
#                  committed set byte for byte, the manifests' provenance lines aside (the
#                  determinism check; nothing in the tree changes)
#   --regenerate   allow a runner image other than the one the committed manifest names
#   --unofficial   run outside a hosted runner; needs --out, so such a set never lands in the tree
#   --out DIR      with --unofficial: where the set goes, laid out as Tests/Parity/References/
#
# One run, at 1.6 and 2.0, writes Tests/Parity/References/:
#
#   fonts/            WOR-312's font and chrome dumps, through its own scripts, called unchanged:
#                     scripts/parity-font-references.sh (`atlas --json`, `fontmetrics`, `shaping`,
#                     `symbols`) and scripts/parity-chrome-references.sh (the NSFont chrome metrics)
#   (conformance)     WOR-313 S3's L3 references (`TKZMUX_WRITE_CONFORMANCE_REFS`): WOR-313 S3 adds
#                     the step below; until then it is skipped, and the skip is logged and recorded
#   framebuilder/     the L2 FrameBuilder instance buffers and the atlas glyph table they reference,
#                     through scripts/parity-framebuilder-references.sh
#   terminal/         <name>@<scale>.png: the final screen of each recording below, drawn by the
#                     release `tkzmux-vtdump render --scale` through the Metal pipelines into an
#                     offscreen texture and read back as bytes (never a screenshot)
#   manifest.json     the machine (the WOR-312 fields: runner image, macOS build, Xcode, Swift,
#                     hw.model, CoreText, AppleFontSmoothing, display profile), every command, a
#                     sha256 per reference file, WOR-307's goldens in Tests/TkzAppTests/
#                     ComponentSnapshots/ by path and sha256 (listed, never copied), the skipped
#                     steps, and a separate provenance block (commit, run). The trees' own
#                     manifest.json files are not listed: each has a provenance block of its own,
#                     which a rerun changes, and their reference files are listed one by one
#
# The terminal recordings: Tests/Parity/Fixtures/golden-screen.tkzrec (GoldenScreen of
# TerminalRendererTests), the four Tests/TkzTerminalCoreTests/Fixtures recordings and
# Tests/Parity/Fixtures/glyph-sheet.tkzrec (GlyphSheet of TkzParityRunnerTests: ASCII in four
# styles, box and block characters, Claude Code's symbols, CJK, emoji and ZWJ sequences).
#
# macOS only, and only on the reference runner (ADR-0003 §5): the GitHub-hosted macos-26 image
# with Xcode 26.1, through .github/workflows/parity-references.yml, which runs this script and then
# `--check`. It refuses on Linux, outside a hosted runner (`CI` and `ImageOS` unset), and on an
# image other than the one the committed manifest names unless --regenerate is passed. A person
# commits the uploaded set in a reviewed PR. docs/linux/parity.md, "Regenerating the references".
# Exit status: 0 = written (or, with --check, identical), 1 = a build, dump or comparison failure,
# 2 = usage or refused.
set -euo pipefail
export LC_ALL=C

die() { echo "parity-export-mac: $*" >&2; exit 2; }
say() { echo "parity-export-mac: $*"; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
committed="$root/Tests/Parity/References"
goldens_rel="Tests/TkzAppTests/ComponentSnapshots"
out="$committed"
out_given=0
check=0
regenerate=0
unofficial=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1; shift ;;
    --regenerate) regenerate=1; shift ;;
    --unofficial) unofficial=1; shift ;;
    --out) [ $# -ge 2 ] || die "--out needs a directory"; out="$2"; out_given=1; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done

case "$out" in /*) ;; *) out="$PWD/$out" ;; esac  # before the cd below

[ "$(uname -s)" = Darwin ] || die "macOS only: the parity references are the Mac's (ADR-0003 §5)"
if [ -z "${CI:-}" ] || [ -z "${ImageOS:-}" ]; then
  [ "$unofficial" = 1 ] || die "refusing outside a hosted runner (CI and ImageOS unset); --unofficial --out DIR writes a set to look at"
fi
if [ "$unofficial" = 1 ]; then
  [ "$out_given" = 1 ] && [ "$check" = 0 ] || die "--unofficial needs --out DIR and no --check: an unofficial set never replaces $committed"
elif [ "$out_given" = 1 ]; then
  die "--out is for --unofficial only: the official set is $committed"
fi
manifest_image() { sed -n 's/^ *"ImageVersion": "\(.*\)",\{0,1\}$/\1/p' "$1" | head -n 1; }
if [ -f "$committed/manifest.json" ] && [ "$regenerate" = 0 ] && [ "$unofficial" = 0 ]; then
  pinned="$(manifest_image "$committed/manifest.json")"
  if [ -n "$pinned" ] && [ "$pinned" != "${ImageVersion:-}" ]; then
    die "the committed set comes from image $pinned, this is ${ImageVersion:-unset}; pass --regenerate to replace it"
  fi
fi

cd "$root"

# MARK: the producers this script calls
# Each keeps its own flags, refusals and --check. With --check every one of them runs, so one
# report names every tree that differs.
status=0
commands=()
call() {
  commands+=("$*")
  say "==> $*"
  if [ "$check" = 1 ]; then
    "$@" || { echo "parity-export-mac: $1 failed" >&2; status=1; }
  else
    "$@"
  fi
}
flags=()
[ "$check" = 1 ] && flags+=(--check)
[ "$regenerate" = 1 ] && flags+=(--regenerate)
fonts_out=() chrome_out=() framebuilder_out=()
if [ "$unofficial" = 1 ]; then
  fonts_out=(--unofficial --out "$out/fonts")
  chrome_out=(--unofficial --out "$out/fonts/chrome-metrics.json")
  framebuilder_out=(--out "$out/framebuilder")
fi
# `${a[@]+"${a[@]}"}`: expanding an empty array is an unbound-variable error under `set -u` in
# bash 3.2 (/bin/bash on macOS).
call scripts/parity-font-references.sh ${flags[@]+"${flags[@]}"} ${fonts_out[@]+"${fonts_out[@]}"}
call scripts/parity-chrome-references.sh ${flags[@]+"${flags[@]}"} ${chrome_out[@]+"${chrome_out[@]}"}

# WOR-313 S3 replaces this skip with its conformance step (TKZMUX_WRITE_CONFORMANCE_REFS), writing
# Tests/Parity/References/conformance/ the same way, with --check honoured.
skipped=("conformance: the L3 references of WOR-313 S3 (TKZMUX_WRITE_CONFORMANCE_REFS), not added yet")
say "skipped: ${skipped[0]}"

check_flag=()
[ "$check" = 1 ] && check_flag=(--check)
call scripts/parity-framebuilder-references.sh ${check_flag[@]+"${check_flag[@]}"} \
  ${framebuilder_out[@]+"${framebuilder_out[@]}"}

# MARK: the terminal frames
swift build -c release --product tkzmux-vtdump
vtdump="$(swift build -c release --product tkzmux-vtdump --show-bin-path)/tkzmux-vtdump"

recordings=(
  Tests/Parity/Fixtures/golden-screen.tkzrec
  Tests/TkzTerminalCoreTests/Fixtures/claude-boot.tkzrec
  Tests/TkzTerminalCoreTests/Fixtures/claude-tool-run.tkzrec
  Tests/TkzTerminalCoreTests/Fixtures/synthetic-basic.tkzrec
  Tests/TkzTerminalCoreTests/Fixtures/zsh-ls-color.tkzrec
  Tests/Parity/Fixtures/glyph-sheet.tkzrec
)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
terminal="$out/terminal"
[ "$check" = 1 ] && terminal="$work/terminal"
mkdir -p "$terminal"
find "$terminal" -maxdepth 1 -type f -name '*@*.png' -delete
for recording in "${recordings[@]}"; do
  name="$(basename "$recording" .tkzrec)"
  for scale in 1.6 2.0; do
    commands+=("tkzmux-vtdump render --scale $scale --out Tests/Parity/References/terminal/$name@$scale.png $recording")
    "$vtdump" render --scale "$scale" --out "$terminal/$name@$scale.png" "$recording"
  done
done
if [ "$check" = 1 ]; then
  if diff -r "$committed/terminal" "$terminal" > /dev/null; then
    say "terminal: identical to $committed/terminal"
  else
    diff -rq "$committed/terminal" "$terminal" >&2 || true
    echo "parity-export-mac: terminal: differs from the committed frames" >&2
    status=1
  fi
fi

# MARK: the manifest
json_string() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}
# `"<prefix><path>": "<sha256>"` for every regular file under a directory, sorted, one per line;
# manifests aside (above).
hashes() {
  local dir="$1" prefix="$2"; shift 2
  [ -d "$dir" ] || return 0
  (cd "$dir" && find . -type f ! -name .DS_Store ! -name manifest.json "$@" | sed 's|^\./||' | sort) | while IFS= read -r name; do
    echo "$(json_string "$prefix$name"): $(json_string "$(shasum -a 256 "$dir/$name" | cut -d ' ' -f 1)")"
  done
}
# Comma-joins stdin's lines at an indent.
join_lines() { sed "s/^/$1/" | sed '$!s/$/,/'; }

# The references the manifest lists: every file under Tests/Parity/References/ but the manifests.
# With --check the trees other scripts own are the committed ones (their own --check has just
# compared them), and terminal/ is the one written above.
set_root="$out"
[ "$check" = 1 ] && set_root="$committed"
reference_hashes() {
  hashes "$set_root" "" ! -path './terminal/*'
  hashes "$terminal" "terminal/"
}
fontmetrics="$set_root/fonts/fontmetrics.json"
environment() { plutil -extract "environment.$1" raw -o - "$fontmetrics"; }
manifest="$out/manifest.json"
[ "$check" = 1 ] && manifest="$work/manifest.json"
{
  echo '{'
  echo '  "schema": 1,'
  echo '  "about": "The Mac parity references of WOR-322 S2, written by scripts/parity-export-mac.sh (make parity-references) on the reference runner (ADR-0003 section 5) and checked by ReferenceManifestTests (Tests/TkzParityTests). The provenance line is the only one two runs on one image may differ in.",'
  echo '  "reference": {'
  echo "    \"ImageOS\": $(json_string "${ImageOS:-unset}"),"
  echo "    \"ImageVersion\": $(json_string "${ImageVersion:-unset}"),"
  echo "    \"macOSBuild\": $(json_string "$(environment macOSBuild)"),"
  echo "    \"macOSVersion\": $(json_string "$(environment macOSVersion)"),"
  echo "    \"xcode\": $(json_string "$(xcodebuild -version 2>/dev/null | paste -sd ' ' - || echo unknown)"),"
  echo "    \"swift\": $(json_string "$(swift --version 2>&1 | head -n 1)"),"
  echo "    \"hwModel\": $(json_string "$(sysctl -n hw.model)"),"
  echo "    \"coreTextVersion\": $(json_string "$(environment coreTextVersion)"),"
  echo "    \"AppleFontSmoothing\": $(json_string "$(environment AppleFontSmoothing)"),"
  echo "    \"displayProfile\": $(json_string "$(environment displayProfile)")"
  echo '  },'
  echo '  "scales": [1.6, 2.0],'
  echo '  "commands": ['
  {
    echo "swift build -c release --product tkzmux-vtdump"
    for line in "${commands[@]}"; do echo "$line"; done
  } | sed -e "s|$out|Tests/Parity/References|g" -e 's/ --check//; s/ --regenerate//; s/ --unofficial//' \
    | while IFS= read -r line; do json_string "$line"; echo; done | join_lines '    '
  echo '  ],'
  echo '  "skipped": ['
  for line in "${skipped[@]}"; do json_string "$line"; echo; done | join_lines '    '
  echo '  ],'
  echo '  "files": {'
  reference_hashes | sort | join_lines '    '
  echo '  },'
  echo '  "componentSnapshots": {'
  hashes "$root/$goldens_rel" "$goldens_rel/" ! -name README.md | join_lines '    '
  echo '  },'
  echo "  \"provenance\": {\"commit\": $(json_string "${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"), \"run\": $(json_string "${GITHUB_RUN_ID:-local}")}"
  echo '}'
} > "$manifest"
plutil -convert xml1 -o /dev/null "$manifest" || { echo "parity-export-mac: wrote an invalid manifest" >&2; exit 1; }

if [ "$check" = 1 ]; then
  if diff <(grep -v '"provenance":' "$committed/manifest.json") <(grep -v '"provenance":' "$manifest") >&2; then
    say "manifest: identical to $committed/manifest.json, provenance aside"
  else
    echo "parity-export-mac: manifest: differs from the committed one" >&2
    status=1
  fi
  if [ "$status" = 0 ]; then
    say "identical to $committed"
  else
    echo "parity-export-mac: differs from the committed set" >&2
    exit 1
  fi
else
  bytes="$(find "$out" -type f -print0 | xargs -0 stat -f %z | awk '{ s += $1 } END { print s }')"
  say "$(reference_hashes | wc -l | tr -d ' ') files + manifest, $bytes bytes in $out"
fi
