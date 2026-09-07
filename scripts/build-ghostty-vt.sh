#!/usr/bin/env bash
# Vendor libghostty-vt as a prebuilt arm64 xcframework at a pinned commit (M1.1 / TKZ-7).
# See docs/design.md → Terminal engine → Packaging.
#
#   GHOSTTY_COMMIT   full sha to vendor (default: vendor/ghostty-vt/COMMIT)
#   GHOSTTY_SRC      working checkout (default: $TMPDIR/ghostty-vt-src; zig caches are kept between runs)
#
# Writes: vendor/ghostty-vt/{ghostty-vt.xcframework,COMMIT,LICENSE,abi-types.json,ghostty.terminfo}
#         Resources/terminfo/{78/xterm-ghostty,67/ghostty}
#
# Why not Ghostty's own xcframework step: with -Demit-lib-vt it always lipo's arm64+x86_64
# (-Dxcframework-target only affects GhosttyKit), and terminfo is only installed on the
# app-executable path, so this script builds the arm64 static archive, wraps it itself, and
# generates terminfo from src/terminfo/*.zig directly.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VENDOR="$ROOT/vendor/ghostty-vt"
DEFAULT_COMMIT="82232ecde55405559dec29c5466cb9e39938cb41"
GHOSTTY_COMMIT="${GHOSTTY_COMMIT:-$(cat "$VENDOR/COMMIT" 2>/dev/null || echo "$DEFAULT_COMMIT")}"
GHOSTTY_SRC="${GHOSTTY_SRC:-${TMPDIR:-/tmp}/ghostty-vt-src}"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"

die()  { echo "build-ghostty-vt.sh: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1${2:+ ($2)}"; }

echo "==> preflight"
need zig "brew install zig"
need xcodebuild "Xcode"
need tic "macOS ncurses"
need git
need swift "Xcode toolchain"
need lipo "Xcode"
ZIG_VERSION="$(zig version)"
[[ "$ZIG_VERSION" == 0.16.* ]] || die "zig 0.16.x required, found $ZIG_VERSION"
[[ "$GHOSTTY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "GHOSTTY_COMMIT must be a full 40-char sha (got '$GHOSTTY_COMMIT')"

echo "==> fetching ghostty@${GHOSTTY_COMMIT:0:12} into $GHOSTTY_SRC"
mkdir -p "$GHOSTTY_SRC"
if [[ ! -d "$GHOSTTY_SRC/.git" ]]; then
  git -C "$GHOSTTY_SRC" init -q
  git -C "$GHOSTTY_SRC" remote add origin "$GHOSTTY_REPO"
fi
git -C "$GHOSTTY_SRC" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
git -C "$GHOSTTY_SRC" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$GHOSTTY_SRC" rev-parse HEAD)" == "$GHOSTTY_COMMIT" ]] || die "checkout is not $GHOSTTY_COMMIT"
for h in include/ghostty/vt.h include/ghostty/vt/render.h include/ghostty/vt/snapshot.h; do
  [[ -f "$GHOSTTY_SRC/$h" ]] || die "$h missing at this commit"
done

echo "==> zig build -Demit-lib-vt (arm64, ReleaseFast)"
build_start=$SECONDS
( cd "$GHOSTTY_SRC" && zig build -Demit-lib-vt -Demit-xcframework=false -Dtarget=aarch64-macos -Doptimize=ReleaseFast )
build_seconds=$((SECONDS - build_start))
LIB="$GHOSTTY_SRC/zig-out/lib/libghostty-vt.a"
[[ -f "$LIB" ]] || die "expected $LIB after zig build"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-vt-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

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
rm -rf "$ROOT/Resources/terminfo"
mkdir -p "$ROOT/Resources/terminfo"
tic -x -o "$ROOT/Resources/terminfo" "$VENDOR/ghostty.terminfo" 2>"$STAGE/tic.log" \
  || { cat "$STAGE/tic.log" >&2; die "tic failed"; }
[[ -f "$ROOT/Resources/terminfo/78/xterm-ghostty" ]] || die "tic did not produce Resources/terminfo/78/xterm-ghostty"

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
echo "    terminfo        $(ls "$ROOT/Resources/terminfo"/*/ | tr '\n' ' ')"
echo "    $VERSION_LINE"
