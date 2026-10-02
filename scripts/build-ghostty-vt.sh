#!/usr/bin/env bash
# Vendor libghostty-vt as a prebuilt arm64 xcframework at a pinned commit (M1.1).
#
#   scripts/build-ghostty-vt.sh                              full vendor (macOS only)
#   scripts/build-ghostty-vt.sh --terminfo-only [--out DIR]  recompile terminfo only
#
#   GHOSTTY_COMMIT   full sha to vendor (default: vendor/ghostty-vt/COMMIT)
#   GHOSTTY_SRC      working checkout (default: $TMPDIR/ghostty-vt-src; zig caches are kept between runs)
#
# Writes: vendor/ghostty-vt/{ghostty-vt.xcframework,COMMIT,LICENSE,abi-types.json,ghostty.terminfo}
#         Sources/TkzTerminalCore/Resources/terminfo/{78,x}/xterm-ghostty and {67,g}/ghostty
#         (Resources/terminfo is a committed symlink to that directory and is never replaced)
#
# --terminfo-only recompiles the committed vendor/ghostty-vt/ghostty.terminfo with tic and does
# nothing else: no fetch, and no zig, xcodebuild, swift or lipo. The committed bytes come from
# macOS tic, so on any other OS it requires --out DIR (a new or empty directory) and is for
# verification only: `infocmp -x -d -A <committed dir> -B DIR xterm-ghostty xterm-ghostty`.
#
# Why not Ghostty's own xcframework step: with -Demit-lib-vt it always lipo's arm64+x86_64
# (-Dxcframework-target only affects GhosttyKit), and terminfo is only installed on the
# app-executable path, so this script builds the arm64 static archive, wraps it itself, and
# generates terminfo from src/terminfo/*.zig directly.
set -euo pipefail
CALLER_PWD="$PWD"
cd "$(dirname "$0")/.."
ROOT="$PWD"
VENDOR="$ROOT/vendor/ghostty-vt"
TERMINFO_DEST="$ROOT/Sources/TkzTerminalCore/Resources/terminfo"
SCRIPT_NAME="build-ghostty-vt.sh"
# shellcheck source=scripts/lib/ghostty-vt-common.sh
source "$ROOT/scripts/lib/ghostty-vt-common.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

TERMINFO_ONLY=0
TERMINFO_OUT=""
while (($#)); do
  case "$1" in
    --terminfo-only) TERMINFO_ONLY=1 ;;
    --out) [[ $# -ge 2 ]] || die "--out needs a directory"; TERMINFO_OUT="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[[ -z "$TERMINFO_OUT" || "$TERMINFO_ONLY" == 1 ]] || die "--out only applies to --terminfo-only"
[[ -z "$TERMINFO_OUT" || "$TERMINFO_OUT" == /* ]] || TERMINFO_OUT="$CALLER_PWD/$TERMINFO_OUT"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-vt-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Compile <source.terminfo> with `tic -x` into a staging database, mirror it into both directory
# layouts, then install it into <dest>. macOS ncurses names an entry's directory after the hex
# of its first byte (78/xterm-ghostty); Linux ncurses uses the letter itself (x/xterm-ghostty)
# and does not find the hex layout at all. Whichever one the host tic wrote, the other is a copy
# of the same bytes, so the two layouts can never disagree (GhosttyVtTests.terminfoLayoutsByteIdentical).
install_terminfo() {
  local src="$1" dest="$2" db="$STAGE/terminfo-db" file entry letter hex dir
  rm -rf "$db"
  mkdir -p "$db"
  tic -x -o "$db" "$src" 2>"$STAGE/tic.log" \
    || { cat "$STAGE/tic.log" >&2; die "tic failed"; }
  for file in "$db"/*/*; do
    [[ -f "$file" ]] || die "tic wrote nothing into $db"
    entry="${file##*/}"
    letter="${entry:0:1}"
    hex="$(printf '%02x' "'$letter")"
    for dir in "$letter" "$hex"; do
      if [[ ! -f "$db/$dir/$entry" ]]; then
        mkdir -p "$db/$dir"
        cp "$file" "$db/$dir/$entry"
      fi
    done
  done
  for entry in 78/xterm-ghostty x/xterm-ghostty 67/ghostty g/ghostty; do
    [[ -f "$db/$entry" ]] || die "tic did not produce terminfo/$entry"
  done
  # Only ever the real directory. `rm -rf Resources/terminfo` would delete the committed symlink
  # itself, and the `mkdir` after it would leave a plain directory where the symlink was.
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -R "$db/." "$dest/"
}

# Checked before anything is written into the tree. A plain directory here was left by an older
# version of this script, which ran `rm -rf` on the symlink.
require_terminfo_symlink() {
  [[ -L "$ROOT/Resources/terminfo" ]] \
    || die "Resources/terminfo is not a symlink; restore it with: git checkout -- Resources/terminfo"
}

if [[ "$TERMINFO_ONLY" == 1 ]]; then
  echo "==> preflight (terminfo only)"
  need tic "ncurses"
  [[ -s "$VENDOR/ghostty.terminfo" ]] || die "missing $VENDOR/ghostty.terminfo"
  if [[ -n "$TERMINFO_OUT" ]]; then
    if [[ -e "$TERMINFO_OUT" ]]; then
      [[ -d "$TERMINFO_OUT" && -z "$(ls -A "$TERMINFO_OUT")" ]] || die "--out $TERMINFO_OUT must be a new or empty directory"
    fi
    dest="$TERMINFO_OUT"
  else
    [[ "$(uname -s)" == Darwin ]] \
      || die "the committed terminfo comes from macOS tic; on $(uname -s) pass --out DIR to verify instead"
    require_terminfo_symlink
    dest="$TERMINFO_DEST"
  fi
  echo "==> terminfo (vendor/ghostty-vt/ghostty.terminfo → tic → $dest)"
  install_terminfo "$VENDOR/ghostty.terminfo" "$dest"
  echo "    terminfo        $(cd "$dest" && echo */*)"
  exit 0
fi

echo "==> preflight"
need zig "brew install zig"
need xcodebuild "Xcode"
need tic "macOS ncurses"
need git
need swift "Xcode toolchain"
need lipo "Xcode"
require_terminfo_symlink
ghostty_check_zig
ghostty_check_commit

ghostty_fetch

echo "==> zig build -Demit-lib-vt (arm64, ReleaseFast)"
build_start=$SECONDS
( cd "$GHOSTTY_SRC" && zig build -Demit-lib-vt -Demit-xcframework=false -Dtarget=aarch64-macos -Doptimize=ReleaseFast )
build_seconds=$((SECONDS - build_start))
LIB="$GHOSTTY_SRC/zig-out/lib/libghostty-vt.a"
[[ -f "$LIB" ]] || die "expected $LIB after zig build"

# Strip debug info before vendoring (M6.5). Zig bakes absolute paths from its build
# cache into the DWARF of every object — on this machine `/Users/<name>/.cache/zig/b/<hash>` —
# and this archive is COMMITTED, so those paths would ship in a public repo. `strings` over the
# archive is how they were found; `git grep` never sees them because it skips binaries.
# `strip -S` removes only debug symbols, not the external symbols the linker resolves against,
# and it takes the archive from ~10.5 MiB to ~2.6 MiB. scripts/scan-personal-data.sh has a
# strings-based pass over vendor/ that fails the build if this ever regresses.
echo "==> strip -S (debug info carries build-machine paths)"
strip -S "$LIB"
if strings -a "$LIB" | grep -q "$HOME"; then
  die "libghostty-vt.a still contains build-machine paths after strip -S"
fi

echo "==> xcodebuild -create-xcframework"
mkdir -p "$STAGE/headers"
cp -R "$GHOSTTY_SRC/include/ghostty" "$STAGE/headers/ghostty"
find "$STAGE/headers" -type f ! -name '*.h' -delete
# Same module map Ghostty writes for its own lib-vt xcframework (src/build/GhosttyLibVt.zig).
cat > "$STAGE/headers/module.modulemap" <<'EOF'
module GhosttyVt {
    umbrella header "ghostty/vt.h"
    export *
}
EOF
mkdir -p "$VENDOR"
rm -rf "$VENDOR/ghostty-vt.xcframework"
xcodebuild -create-xcframework \
  -library "$LIB" -headers "$STAGE/headers" \
  -output "$VENDOR/ghostty-vt.xcframework" >"$STAGE/xcodebuild.log" 2>&1 \
  || { cat "$STAGE/xcodebuild.log" >&2; die "xcodebuild -create-xcframework failed"; }

echo "==> terminfo (src/terminfo/*.zig → tic)"
mkdir -p "$STAGE/terminfo"
cp "$GHOSTTY_SRC"/src/terminfo/*.zig "$STAGE/terminfo/"
# Mirrors the `terminfo` action of Ghostty's src/main_build_data.zig, which is not
# reachable from `zig build` in lib-vt mode.
cat > "$STAGE/terminfo/gen.zig" <<'EOF'
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &stdout_writer.interface;
    try @import("ghostty.zig").ghostty.encode(writer);
    try stdout_writer.end();
}
EOF
( cd "$STAGE/terminfo" && zig run gen.zig ) > "$VENDOR/ghostty.terminfo"
[[ -s "$VENDOR/ghostty.terminfo" ]] || die "terminfo source is empty"
install_terminfo "$VENDOR/ghostty.terminfo" "$TERMINFO_DEST"
require_terminfo_symlink

cp "$GHOSTTY_SRC/LICENSE" "$VENDOR/LICENSE"

echo "==> swift build tkzmux-vtdump → abi-types.json"
swift build --product tkzmux-vtdump
BIN="$(swift build --product tkzmux-vtdump --show-bin-path)"
"$BIN/tkzmux-vtdump" abi > "$VENDOR/abi-types.json"
VERSION_LINE="$("$BIN/tkzmux-vtdump" version)"

# Written last so a failed run never advances the pin.
echo "$GHOSTTY_COMMIT" > "$VENDOR/COMMIT"

lib_bytes="$(stat -f%z "$LIB")"
cxx_undefined="$(nm -u "$LIB" 2>/dev/null | grep -c '__ZNSt3__1' || true)"
echo "==> vendored libghostty-vt"
echo "    commit          $GHOSTTY_COMMIT"
echo "    zig build       ${build_seconds}s"
echo "    libghostty-vt.a $lib_bytes bytes ($(( lib_bytes / 1024 / 1024 )) MiB), $(lipo -info "$LIB" | sed 's/.*: //')"
echo "    xcframework     $(du -sh "$VENDOR/ghostty-vt.xcframework" | cut -f1)"
echo "    std::__1 undefined symbols in .a: $cxx_undefined"
echo "    terminfo        $(cd "$TERMINFO_DEST" && echo */*)"
echo "    $VERSION_LINE"
