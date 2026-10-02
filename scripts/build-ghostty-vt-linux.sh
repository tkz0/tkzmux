#!/usr/bin/env bash
# Vendor libghostty-vt for Linux as an SE-0482 static-library artifact bundle (x86_64, glibc 2.35).
#
#   scripts/build-ghostty-vt-linux.sh                   build at vendor/ghostty-vt/COMMIT (Linux x86_64 only)
#   scripts/build-ghostty-vt-linux.sh --update-lists    also rewrite the two symbol lists below
#
#   GHOSTTY_COMMIT   must equal vendor/ghostty-vt/COMMIT; this script never moves the pin
#   GHOSTTY_SRC      working checkout (default: $TMPDIR/ghostty-vt-src; zig caches are kept between runs)
#   GLIBC_LIBDIR     directory holding the host's libc.so.6 and libm.so.6 (default: probed)
#
# Writes: vendor/ghostty-vt/ghostty-vt-linux.artifactbundle/{info.json,BUILDINFO,include/**,
#           x86_64-unknown-linux-gnu/libghostty-vt.a}
#         with --update-lists also vendor/ghostty-vt/{linux-localize-symbols,linux-expected-undefined}.txt
#
# Bump order: the macOS `make vendor` moves COMMIT and writes the headers first; this script then
# rebuilds the Linux archive at that same COMMIT and fails if its headers differ from the
# xcframework's. A second run at the same COMMIT reproduces the archive bit for bit.
#
# Post-processing of zig's archive, all of it gated:
#   - Zig's member names carry directories, and compiler_rt.o's is an absolute path into the
#     build machine's ~/.cache/zig, so GNU ar/objcopy/strip cannot edit the archive in place and
#     the name is personal data. llvm-ar extracts the members; GNU ar re-archives them under their
#     basenames, in the original order, with deterministic headers (`ar rcsD`).
#   - compiler_rt.o defines libc/libm names (memcpy, memmove, memset, strlen, exp, log, sin, ...)
#     as weak hidden globals. Left global, they would win over glibc for every object in the final
#     executable, Swift code included. `objcopy --localize-symbols=linux-localize-symbols.txt`
#     makes them local in each member that defines one, so only that member's own calls use them.
#     That is compiler_rt.o plus libghostty-vt-static_zcu.o, whose quirks_memset.zig exports a
#     second weak hidden memset; left global it takes every memset in the executable away from
#     glibc. The run fails if any member defines a libc/libm name that is not on the list.
#   - `strip -S`: zig bakes absolute cache and source paths into the DWARF (see
#     build-ghostty-vt.sh), then `strings -a` must not find a build-machine path.
#   - The archive's external undefined symbols must be a subset of linux-expected-undefined.txt,
#     which may never name the C++ runtime (_Znw*, __cxa_*), arc4random* or __isoc23_* (glibc
#     > 2.35). No .debug_* section and no R_X86_64_32/32S relocation may survive. At most 5 MiB.
#
# --update-lists regenerates both lists from this build: the localize list is every member's
# defined globals intersected with `nm -D --defined-only` of libc.so.6 and libm.so.6, the
# expected list is the archive's undefined symbols minus the ones it defines itself. Review the
# diff before committing it; the forbidden-name gates apply either way.
set -euo pipefail
export LC_ALL=C   # one sort order for the committed lists and every comm(1) below
cd "$(dirname "$0")/.."
ROOT="$PWD"
VENDOR="$ROOT/vendor/ghostty-vt"
BUNDLE="$VENDOR/ghostty-vt-linux.artifactbundle"
XCF_HEADERS="$VENDOR/ghostty-vt.xcframework/macos-arm64/Headers"
LOCALIZE_LIST="$VENDOR/linux-localize-symbols.txt"
EXPECTED_UNDEFINED="$VENDOR/linux-expected-undefined.txt"
SCRIPT_NAME="build-ghostty-vt-linux.sh"
# shellcheck source=scripts/lib/ghostty-vt-common.sh
source "$ROOT/scripts/lib/ghostty-vt-common.sh"

TRIPLE="x86_64-unknown-linux-gnu"
GLIBC_FLOOR="2.35"
ZIG_TARGET="x86_64-linux-gnu.$GLIBC_FLOOR"
ZIG_CPU="x86_64_v3"             # not znver5/native: GitHub's x64 fleet is mixed, AVX-512 would SIGILL
ZIG_OPTIMIZE="ReleaseFast"
MAX_BYTES=$((5 * 1024 * 1024))
# Undefined references the archive may never carry: the C++ runtime (SE-0482 bundles are
# libc-only), and glibc symbols newer than the 2.35 floor.
FORBIDDEN_UNDEFINED='^(_Znw|_Zna|_Zdl|_Zda|_ZNSt3__1|__cxa_|__gxx_personality|arc4random|__isoc23_)'

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

UPDATE_LISTS=0
while (($#)); do
  case "$1" in
    --update-lists) UPDATE_LISTS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

# Symbol names of a list file: objcopy's own format, one per line, `#` comments.
list_names() { grep -v -e '^#' -e '^[[:space:]]*$' "$1" | sort -u; }

glibc_libdir() {
  local d
  for d in ${GLIBC_LIBDIR:-} /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
    if [[ -f "$d/libc.so.6" && -f "$d/libm.so.6" ]]; then echo "$d"; return; fi
  done
  die "libc.so.6/libm.so.6 not found; set GLIBC_LIBDIR"
}

echo "==> preflight"
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] \
  || die "Linux x86_64 only (this is $(uname -s) $(uname -m)); the macOS archive comes from build-ghostty-vt.sh"
need zig "Arch: pacman -S zig (0.16.x)"
need git
need llvm-ar "ships with the Swift toolchain"
for tool in ar nm objcopy strip readelf strings; do need "$tool" "GNU binutils"; done
need sha256sum "coreutils"
ghostty_check_zig
ghostty_check_commit
[[ -s "$VENDOR/COMMIT" ]] || die "missing $VENDOR/COMMIT"
PINNED="$(cat "$VENDOR/COMMIT")"
[[ "$GHOSTTY_COMMIT" == "$PINNED" ]] \
  || die "GHOSTTY_COMMIT=$GHOSTTY_COMMIT but COMMIT pins $PINNED; bump with the macOS \`make vendor\` first (docs/linux/vendoring.md)"
[[ -f "$XCF_HEADERS/module.modulemap" ]] || die "missing $XCF_HEADERS; the bundle's headers are checked against the xcframework's"
if ((!UPDATE_LISTS)); then
  [[ -s "$LOCALIZE_LIST" ]] || die "missing ${LOCALIZE_LIST#"$ROOT/"} (generate it with --update-lists)"
  [[ -s "$EXPECTED_UNDEFINED" ]] || die "missing ${EXPECTED_UNDEFINED#"$ROOT/"} (generate it with --update-lists)"
fi
LIBC_DIR="$(glibc_libdir)"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-vt-linux-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

ghostty_fetch

echo "==> zig build -Demit-lib-vt ($ZIG_TARGET, $ZIG_CPU, $ZIG_OPTIMIZE)"
# Never -fsys=simdutf/highway: the vendored copies build without libc++, Arch's system simdutf
# needs it.
build_start=$SECONDS
rm -rf "$GHOSTTY_SRC/zig-out"
( cd "$GHOSTTY_SRC" && zig build -Demit-lib-vt -Demit-xcframework=false \
    -Dtarget="$ZIG_TARGET" -Dcpu="$ZIG_CPU" -Doptimize="$ZIG_OPTIMIZE" )
build_seconds=$((SECONDS - build_start))
RAW="$GHOSTTY_SRC/zig-out/lib/libghostty-vt.a"
[[ -f "$RAW" ]] || die "expected $RAW after zig build"

echo "==> extract members (llvm-ar: zig's member names carry directories)"
OBJS="$STAGE/objs"
mkdir -p "$OBJS"
MEMBERS=()
while IFS= read -r member; do
  MEMBERS+=("${member##*/}")
done < <(llvm-ar t "$RAW")
((${#MEMBERS[@]})) || die "$RAW has no members"
dupes="$(printf '%s\n' "${MEMBERS[@]}" | sort | uniq -d)"
[[ -z "$dupes" ]] || die "two archive members share a basename: $dupes"
( cd "$OBJS" && llvm-ar x "$RAW" )
for member in "${MEMBERS[@]}"; do
  [[ -f "$OBJS/$member" ]] || die "llvm-ar x did not write $member"
done
[[ -f "$OBJS/compiler_rt.o" ]] || die "no compiler_rt.o member; the localization below assumes zig bundles it"

echo "==> localize compiler_rt's libc/libm symbols"
{ nm -D --defined-only "$LIBC_DIR/libc.so.6"; nm -D --defined-only "$LIBC_DIR/libm.so.6"; } \
  | awk 'NF >= 3 { sub(/@.*/, "", $3); print $3 }' | sort -u > "$STAGE/libc-names"
: > "$STAGE/shadowing"
for member in "${MEMBERS[@]}"; do
  nm -g --defined-only "$OBJS/$member" | awk 'NF == 3 { print $3 }' | sort -u \
    | comm -12 - "$STAGE/libc-names" > "$STAGE/shadow.$member"
  cat "$STAGE/shadow.$member" >> "$STAGE/shadowing"
done
sort -u -o "$STAGE/shadowing" "$STAGE/shadowing"
if ((UPDATE_LISTS)); then
  {
    echo "# libc/libm names that libghostty-vt's archive members define (compiler_rt.o, and the"
    echo "# quirks memset in libghostty-vt-static_zcu.o). build-ghostty-vt-linux.sh localizes them"
    echo "# with \`objcopy --localize-symbols\` so the final executable binds these names to glibc."
    echo "# Generated by \`scripts/build-ghostty-vt-linux.sh --update-lists\`; see docs/linux/vendoring.md."
    cat "$STAGE/shadowing"
  } > "$LOCALIZE_LIST"
  echo "    wrote ${LOCALIZE_LIST#"$ROOT/"} ($(wc -l < "$STAGE/shadowing") names)"
fi
unlisted="$(comm -23 "$STAGE/shadowing" <(list_names "$LOCALIZE_LIST"))"
[[ -z "$unlisted" ]] \
  || die "archive members define libc/libm names missing from ${LOCALIZE_LIST#"$ROOT/"}: $(echo "$unlisted" | tr '\n' ' ')(review, then --update-lists)"
localized=()
for member in "${MEMBERS[@]}"; do
  if [[ -s "$STAGE/shadow.$member" ]]; then
    objcopy --localize-symbols="$LOCALIZE_LIST" "$OBJS/$member"
    localized+=("$member")
  fi
done

echo "==> strip -S + re-archive under basenames (ar rcsD)"
for member in "${MEMBERS[@]}"; do
  strip -S "$OBJS/$member"
done
LIB="$STAGE/libghostty-vt.a"
( cd "$OBJS" && ar rcsD "$LIB" "${MEMBERS[@]}" )

echo "==> check the archive"
leaked="$(nm -g --defined-only "$LIB" 2>/dev/null | awk 'NF == 3 { print $3 }' | sort -u \
  | comm -12 - <(list_names "$LOCALIZE_LIST"))"
[[ -z "$leaked" ]] || die "still global after localization: $(echo "$leaked" | tr '\n' ' ')"
debug_sections="$(readelf -SW "$LIB" | grep -c ' \.debug_' || true)"
((debug_sections == 0)) || die "$debug_sections .debug_* section(s) survived strip -S"
# Absolute 32-bit relocations cannot be resolved in a PIE. Section-relative ones (the symbol
# column is a section name) appear only in debug info, which is gone, so any named target fails.
abs32="$(readelf -rW "$LIB" | awk '($3 == "R_X86_64_32" || $3 == "R_X86_64_32S") && $5 !~ /^\./' | head -5)"
[[ -z "$abs32" ]] || die "R_X86_64_32/32S relocations against symbols: $abs32"
nm -g --defined-only "$LIB" 2>/dev/null | awk 'NF == 3 { print $3 }' | sort -u > "$STAGE/defined"
nm -u "$LIB" 2>/dev/null | awk 'NF == 2 { print $2 }' | sort -u | comm -23 - "$STAGE/defined" > "$STAGE/undefined"
forbidden="$(grep -E "$FORBIDDEN_UNDEFINED" "$STAGE/undefined" || true)"
[[ -z "$forbidden" ]] || die "forbidden undefined symbols (C++ runtime or glibc > $GLIBC_FLOOR): $(echo "$forbidden" | tr '\n' ' ')"
if ((UPDATE_LISTS)); then
  {
    echo "# External symbols the Linux libghostty-vt archive may reference: its undefined symbols minus"
    echo "# the ones it defines itself. glibc's libc/libm only; never the C++ runtime (_Znw*, __cxa_*),"
    echo "# arc4random* or __isoc23_* (both newer than the glibc $GLIBC_FLOOR floor)."
    echo "# Generated by \`scripts/build-ghostty-vt-linux.sh --update-lists\`; see docs/linux/vendoring.md."
    cat "$STAGE/undefined"
  } > "$EXPECTED_UNDEFINED"
  echo "    wrote ${EXPECTED_UNDEFINED#"$ROOT/"} ($(wc -l < "$STAGE/undefined") names)"
fi
listed_forbidden="$(list_names "$EXPECTED_UNDEFINED" | grep -E "$FORBIDDEN_UNDEFINED" || true)"
[[ -z "$listed_forbidden" ]] || die "${EXPECTED_UNDEFINED#"$ROOT/"} names forbidden symbols: $(echo "$listed_forbidden" | tr '\n' ' ')"
unexpected="$(comm -23 "$STAGE/undefined" <(list_names "$EXPECTED_UNDEFINED"))"
[[ -z "$unexpected" ]] \
  || die "undefined symbols missing from ${EXPECTED_UNDEFINED#"$ROOT/"}: $(echo "$unexpected" | tr '\n' ' ')(review, then --update-lists)"
# C++ __FILE__ strings can survive strip -S in .rodata, so look at every byte.
path_patterns=(-e ".cache/zig" -e "/home/" -e "$STAGE" -e "$GHOSTTY_SRC")
[[ -n "${HOME:-}" && "$HOME" != / ]] && path_patterns+=(-e "$HOME")
src_physical="$(cd "$GHOSTTY_SRC" && pwd -P)"
[[ "$src_physical" != "$GHOSTTY_SRC" ]] && path_patterns+=(-e "$src_physical")
paths="$(strings -a "$LIB" | grep -F "${path_patterns[@]}" | sort -u | head -5 || true)"
[[ -z "$paths" ]] || die "libghostty-vt.a contains build-machine paths: $paths"
lib_bytes="$(stat -c%s "$LIB")"
((lib_bytes <= MAX_BYTES)) || die "libghostty-vt.a is $lib_bytes bytes, over the $MAX_BYTES-byte budget"
lib_sha="$(sha256sum "$LIB" | cut -d' ' -f1)"

echo "==> assemble ${BUNDLE#"$ROOT/"}"
OUT="$STAGE/bundle"
mkdir -p "$OUT/include" "$OUT/$TRIPLE"
cp "$LIB" "$OUT/$TRIPLE/libghostty-vt.a"
cp -R "$GHOSTTY_SRC/include/ghostty" "$OUT/include/ghostty"
find "$OUT/include" -type f ! -name '*.h' -delete
# Same module map as the xcframework's (build-ghostty-vt.sh). libm is linked by the package
# manifest (`.linkedLibrary("m")`), not here, so the two header trees stay byte-identical.
cat > "$OUT/include/module.modulemap" <<'EOF'
module GhosttyVt {
    umbrella header "ghostty/vt.h"
    export *
}
EOF
diff -r "$XCF_HEADERS" "$OUT/include" >"$STAGE/headers.diff" \
  || { cat "$STAGE/headers.diff" >&2; die "headers differ from the xcframework's; run the macOS \`make vendor\` at this COMMIT first"; }
# SE-0482 static-library artifact bundle. `version` is informational; the pin is the commit.
cat > "$OUT/info.json" <<EOF
{
  "schemaVersion": "1.0",
  "artifacts": {
    "GhosttyVt": {
      "type": "staticLibrary",
      "version": "$GHOSTTY_COMMIT",
      "variants": [
        {
          "path": "$TRIPLE/libghostty-vt.a",
          "supportedTriples": ["$TRIPLE"],
          "staticLibraryMetadata": {
            "headerPaths": ["include"],
            "moduleMapPath": "include/module.modulemap"
          }
        }
      ]
    }
  }
}
EOF
cat > "$OUT/BUILDINFO" <<EOF
commit=$GHOSTTY_COMMIT
zig=$ZIG_VERSION
target=$ZIG_TARGET
cpu=$ZIG_CPU
optimize=$ZIG_OPTIMIZE
glibc_floor=$GLIBC_FLOOR
sha256=$lib_sha
EOF
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
cp -R "$OUT/." "$BUNDLE/"

cxx_undefined="$(grep -c -E '^(_ZNSt3__1|_Znwm)' "$STAGE/undefined" || true)"
echo "==> vendored libghostty-vt (Linux)"
echo "    commit          $GHOSTTY_COMMIT"
echo "    zig build       ${build_seconds}s (zig $ZIG_VERSION, $ZIG_TARGET, $ZIG_CPU)"
echo "    libghostty-vt.a $lib_bytes bytes ($(( lib_bytes / 1024 / 1024 )) MiB), ${#MEMBERS[@]} members"
echo "    sha256          $lib_sha"
echo "    localized       $(list_names "$LOCALIZE_LIST" | wc -l) names in ${localized[*]}"
echo "    undefined       $(wc -l < "$STAGE/undefined") external symbols, _ZNSt3__1/_Znwm: $cxx_undefined"
echo "    bundle          $(du -sh "$BUNDLE" | cut -f1)"
