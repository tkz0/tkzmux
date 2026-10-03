#!/usr/bin/env bash
# parity-font-references.sh: write the Mac font references (WOR-312 S1; ADR-0003 §3 L1 and L4, §5).
#
#   scripts/parity-font-references.sh [--check] [--out DIR] [--regenerate] [--unofficial]
#
#   --check        write into a temporary directory and fail unless it equals the committed set
#                  byte for byte, the manifest's provenance line aside (the determinism check;
#                  nothing in the tree changes)
#   --out DIR      where the set goes (default: Tests/Parity/References/fonts)
#   --regenerate   allow a runner image other than the one the committed manifest names
#   --unofficial   run outside a hosted runner; needs --out, so such a set never lands in the tree
#
# The release `tkzmux-vtdump` (FontDumpCommands.swift, RenderCommands.swift) writes, over CoreText:
#
#   fontmetrics.json               CellMetrics of JetBrains Mono at 11, 12.5, 13, 14, 16 pt at 1.6x
#                                  and 2x, and 40 pt at 2x (L1)
#   shaping.json                   the shaping corpus in four styles at 14 pt, 2x
#   symbols.json                   the symbol inventory: coverage, CoreText fallback, advances
#   atlas-<pt>pt-<s>x-thicken<t>   .json + -grayscale.png + -color.png: the default sample at the
#                                  two gated sizes, 12.5 and 14 pt, at 1.6x and 2x, thicken 0 and 1;
#                                  a five-glyph sample at 40 pt (80 px), 2x (L4). The other metrics
#                                  sizes are left out for the budget (ADR-0003 §5): each atlas costs
#                                  about 160 KB, and `atlas --json` writes any of them on demand
#   manifest.json                  the machine (runner image, macOS build, Xcode, hw.model,
#                                  AppleFontSmoothing, display profile), the commands, a sha256 per
#                                  file, and a provenance line (commit, run)
#
# macOS only, and only on the reference runner (ADR-0003 §5): the GitHub-hosted macos-26 image
# with Xcode 26.1, through .github/workflows/font-references.yml. The Linux side reads the set in
# Tests/TkzFontsFTTests. WOR-322 S2's `make parity-references` calls this script unchanged.
# Exit status: 0 = written (or, with --check, identical), 1 = a build, dump or comparison failure,
# 2 = usage or refused.
set -euo pipefail
export LC_ALL=C

die() { echo "parity-font-references: $*" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
committed="$root/Tests/Parity/References/fonts"
out="$committed"
out_given=0
check=0
regenerate=0
unofficial=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1; shift ;;
    --out) [ $# -ge 2 ] || die "--out needs a directory"; out="$2"; out_given=1; shift 2 ;;
    --regenerate) regenerate=1; shift ;;
    --unofficial) unofficial=1; shift ;;
    *) die "unknown argument $1" ;;
  esac
done

[ "$(uname -s)" = Darwin ] || die "macOS only: the font references are CoreText's (ADR-0003 §5)"
if [ -z "${CI:-}" ] || [ -z "${ImageOS:-}" ]; then
  [ "$unofficial" = 1 ] || die "refusing outside a hosted runner (CI and ImageOS unset); --unofficial --out DIR writes a set to look at"
  [ "$out_given" = 1 ] && [ "$check" = 0 ] || die "--unofficial needs --out DIR and no --check: an unofficial set never replaces $committed"
fi
manifest_image() { sed -n 's/^ *"ImageVersion": "\(.*\)",\{0,1\}$/\1/p' "$1" | head -n 1; }
if [ -f "$committed/manifest.json" ] && [ "$regenerate" = 0 ] && [ "$unofficial" = 0 ]; then
  pinned="$(manifest_image "$committed/manifest.json")"
  if [ -n "$pinned" ] && [ "$pinned" != "${ImageVersion:-}" ]; then
    die "the committed set comes from image $pinned, this is ${ImageVersion:-unset}; pass --regenerate to replace it"
  fi
fi

cd "$root"
swift build -c release --product tkzmux-vtdump
vtdump="$(swift build -c release --product tkzmux-vtdump --show-bin-path)/tkzmux-vtdump"

if [ "$check" = 1 ]; then
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
fi
mkdir -p "$out"
find "$out" -maxdepth 1 -type f \( -name '*.json' -o -name '*.png' \) -delete

# Every command line, as the manifest records it: relative to the repo, output in the committed
# directory.
commands=()
run() {
  local -a argv=("$@")
  commands+=("tkzmux-vtdump ${argv[*]}")
  for i in "${!argv[@]}"; do argv[i]="${argv[$i]//@OUT@/$out}"; done
  "$vtdump" "${argv[@]}" > /dev/null
}
dir="@OUT@"

run fontmetrics --json --out "$dir/fontmetrics.json"
run shaping --json --out "$dir/shaping.json"
run symbols --json --out "$dir/symbols.json"
for size in 12.5 14; do
  for scale in 1.6 2; do
    for thicken in 0 1; do
      run atlas --json --point-size "$size" --scale "$scale" --thicken "$thicken" \
        --out "$dir/atlas-${size}pt-${scale}x-thicken${thicken}"
    done
  done
done
# Above 72 ppem, where the Linux dilation stops: a few glyphs are enough to measure it.
for thicken in 0 1; do
  run atlas --json --point-size 40 --scale 2 --thicken "$thicken" --sample HOgx@ \
    --out "$dir/atlas-40pt-2x-thicken${thicken}"
done

# MARK: the manifest
json_string() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}
environment() { plutil -extract "environment.$1" raw -o - "$out/fontmetrics.json"; }
{
  echo '{'
  echo '  "schema": 1,'
  echo '  "about": "The Mac font references of WOR-312 S1, written by scripts/parity-font-references.sh on the reference runner (ADR-0003 section 5) and read by Tests/TkzFontsFTTests. The provenance line is the only one two runs on one image may differ in.",'
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
  echo '  "commands": ['
  echo "    $(json_string "swift build -c release --product tkzmux-vtdump"),"
  last=$((${#commands[@]} - 1))
  for i in "${!commands[@]}"; do
    line="    $(json_string "${commands[$i]//@OUT@/Tests/Parity/References/fonts}")"
    [ "$i" -lt "$last" ] && line="$line,"
    echo "$line"
  done
  echo '  ],'
  echo '  "files": {'
  files=()
  while IFS= read -r name; do files+=("$name"); done < <(cd "$out" && find . -maxdepth 1 -type f ! -name manifest.json | sed 's|^\./||' | sort)
  last=$((${#files[@]} - 1))
  for i in "${!files[@]}"; do
    sum="$(shasum -a 256 "$out/${files[$i]}" | cut -d ' ' -f 1)"
    line="    $(json_string "${files[$i]}"): $(json_string "$sum")"
    [ "$i" -lt "$last" ] && line="$line,"
    echo "$line"
  done
  echo '  },'
  echo "  \"provenance\": {\"commit\": $(json_string "${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"), \"run\": $(json_string "${GITHUB_RUN_ID:-local}")}"
  echo '}'
} > "$out/manifest.json"
plutil -convert xml1 -o /dev/null "$out/manifest.json" || { echo "parity-font-references: wrote an invalid manifest" >&2; exit 1; }

bytes="$(find "$out" -maxdepth 1 -type f -exec stat -f %z {} + | awk '{ s += $1 } END { print s }')"
echo "parity-font-references: ${#files[@]} files + manifest, $bytes bytes in $out"

if [ "$check" = 1 ]; then
  status=0
  diff -rq -x manifest.json "$committed" "$out" >&2 || status=1
  diff <(grep -v '"provenance":' "$committed/manifest.json") <(grep -v '"provenance":' "$out/manifest.json") >&2 || status=1
  if [ "$status" = 0 ]; then
    echo "parity-font-references: identical to $committed"
  else
    echo "parity-font-references: differs from the committed set" >&2
    exit 1
  fi
fi
