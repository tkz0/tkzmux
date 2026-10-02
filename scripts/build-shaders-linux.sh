#!/usr/bin/env bash
# build-shaders-linux.sh: compile the GLSL port of Terminal.metal to SPIR-V and regenerate the
# committed C arrays in Sources/TkzShadersSPIRV (WOR-313 S2). tkzmux never compiles a shader at
# runtime and links no shader compiler; this script is the only place glslc runs.
#
#   scripts/build-shaders-linux.sh                 regenerate in place
#   scripts/build-shaders-linux.sh --check         regenerate into a scratch dir and fail on any byte
#                                                  difference from the committed files (CI drift check)
#   scripts/build-shaders-linux.sh --fetch [...]   use the pinned packages below (downloaded once,
#                                                  sha256-checked, cached) instead of glslc on PATH
#
#   GLSLC, SPIRV_VAL   the tools to run (default: from PATH, or the fetched packages with --fetch)
#   SHADERC_CACHE      where --fetch unpacks the packages
#                      (default: ${XDG_CACHE_HOME:-$HOME/.cache}/tkzmux/shaderc-<pin>)
#
# Reads:  Sources/TkzShadersSPIRV/glsl/*.glsl, the `pin glslc` line in docs/linux/dev.md
# Writes: Sources/TkzShadersSPIRV/generated/<entry>.spv.inc   `glslc -mfmt=c` output, one per entry
#         Sources/TkzShadersSPIRV/include/TkzShadersSPIRV.h   arrays, sizes, module table, versions
#         Sources/TkzShadersSPIRV/TkzShadersSPIRV.c           the arrays (#include of the .inc files)
# Everything under Sources/TkzShadersSPIRV except glsl/ is generated: edit glsl/, then rerun.
#
# Why a pin: SPIR-V bytes differ between glslc releases (and between the shaderc, SPIRV-Tools and
# glslang builds behind one glslc), so the drift check only means something when every machine
# runs the same compiler. Arch's `shaderc` moves with the distro, noble's is years old, and upstream
# shaderc publishes no versioned binaries. The pin is therefore the exact Arch package set below,
# fetched from the Arch Linux Archive by URL and sha256 with --fetch (CI does that in the Arch
# full-build job) or, on a host that already has these package versions installed, found on PATH.
# Either way `glslc --version` must print exactly the pinned lines, or the script refuses to run.
# The shaderc version itself is the `pin glslc` line in docs/linux/dev.md; the package list must
# agree with it.
#
# Per entry point: `glslc -O --target-env=vulkan1.3 -fshader-stage=<stage> -Werror` twice, as a
# binary for `spirv-val --target-env vulkan1.3` and as `-mfmt=c` for the committed .inc; the two
# must hold the same words. Both run from glsl/ with relative paths and without -g, so no path
# reaches the output.
#
# Exit status: 0 = generated (or, with --check, no drift), 1 = drift or a failing compile/validate,
#              2 = usage, pin or tool error.
set -euo pipefail
export LC_ALL=C

die() { echo "build-shaders-linux: $*" >&2; exit 2; }
fail() { echo "build-shaders-linux: $*" >&2; exit 1; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_dir="$root/Sources/TkzShadersSPIRV"
glsl_dir="$target_dir/glsl"
dev_md="$root/docs/linux/dev.md"

check=0
fetch=0
for arg in "$@"; do
  case "$arg" in
    --check) check=1 ;;
    --fetch) fetch=1 ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument '$arg' (try --help)" ;;
  esac
done

# MARK: - Pins

[ -r "$dev_md" ] || die "pin file not readable: $dev_md"
glslc_pin="$(awk '$1 == "pin" && $2 == "glslc" { print $3; exit }' "$dev_md")"
[ -n "$glslc_pin" ] || die "no 'glslc' pin line in $dev_md"

# The Arch package set behind the pin, as `name|version|sha256` of the x86_64 .pkg.tar.zst.
spirv_tools_version="1:1.4.357.0"
glslang_version="1:1.4.357.0"
pinned_packages=(
  "shaderc|$glslc_pin-1|4b8c63f7e5074aa3551507d38da77584d017fac8085d6d057af0e08cc0ca1b1b"
  "spirv-tools|$spirv_tools_version-1|aee9b717cfd61aa74ca85d7e5608d7f8914e57e965a2cda982a922728b4772bb"
  "glslang|$glslang_version-1|c8417ab41fcccb7ce1f6f9da447733ad612d918c0d530484227e7af95ed735d1"
)
archive="https://archive.archlinux.org/packages"
# Bump: change `pin glslc` in dev.md and the versions and hashes above together, then rerun this
# script (without --check) and commit the regenerated files. The sha256 is of the package file as
# served by $archive/<initial>/<name>/<name>-<version>-x86_64.pkg.tar.zst.

# `glslc --version` lines 1-3: shaderc, SPIRV-Tools, glslang. Arch's build prints bare versions.
expected_version="$(printf '%s\n%s\n%s' "$glslc_pin" "$spirv_tools_version" "$glslang_version")"

# MARK: - Tools

tool_lib=""
run() { if [ -n "$tool_lib" ]; then LD_LIBRARY_PATH="$tool_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$@"; else "$@"; fi; }

fetch_pinned() {
  [ "$(uname -m)" = "x86_64" ] || die "--fetch: the pinned packages are x86_64 only"
  command -v curl >/dev/null || die "--fetch needs curl"
  command -v sha256sum >/dev/null || die "--fetch needs sha256sum"
  tar --zstd --version >/dev/null 2>&1 || die "--fetch needs GNU tar with zstd (pacman: zstd)"

  local cache="${SHADERC_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/tkzmux/shaderc-$glslc_pin}"
  mkdir -p "$cache/pkg"
  local stamp="$cache/.unpacked" want="" entry name version sum file url
  for entry in "${pinned_packages[@]}"; do want+="$entry"$'\n'; done
  if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$want" ]; then
    rm -rf "$cache/root" && mkdir -p "$cache/root"
    for entry in "${pinned_packages[@]}"; do
      IFS='|' read -r name version sum <<<"$entry"
      file="$cache/pkg/$name-${version//:/_}-x86_64.pkg.tar.zst"
      url="$archive/${name:0:1}/$name/$name-${version//:/%3A}-x86_64.pkg.tar.zst"
      if [ ! -f "$file" ] || ! echo "$sum  $file" | sha256sum --check --status; then
        echo "build-shaders-linux: fetching $name $version" >&2
        curl -fsSL --retry 3 -o "$file.part" "$url" || die "download failed: $url"
        mv "$file.part" "$file"
      fi
      echo "$sum  $file" | sha256sum --check --status \
        || { rm -f "$file"; die "sha256 mismatch for $name $version (want $sum)"; }
      tar --zstd -xf "$file" -C "$cache/root" usr/bin usr/lib
    done
    printf '%s' "$want" >"$stamp"
  fi
  GLSLC="$cache/root/usr/bin/glslc"
  SPIRV_VAL="$cache/root/usr/bin/spirv-val"
  tool_lib="$cache/root/usr/lib"
}

if [ "$fetch" = 1 ]; then
  fetch_pinned
else
  GLSLC="${GLSLC:-$(command -v glslc || true)}"
  SPIRV_VAL="${SPIRV_VAL:-$(command -v spirv-val || true)}"
  [ -n "$GLSLC" ] || die "glslc not found; install shaderc $glslc_pin or use --fetch"
  [ -n "$SPIRV_VAL" ] || die "spirv-val not found; install spirv-tools or use --fetch"
fi
[ -x "$GLSLC" ] || die "not executable: $GLSLC"
[ -x "$SPIRV_VAL" ] || die "not executable: $SPIRV_VAL"

actual_version="$(run "$GLSLC" --version 2>/dev/null | head -n 3)" || die "'$GLSLC --version' failed"
if [ "$actual_version" != "$expected_version" ]; then
  {
    echo "build-shaders-linux: refusing $GLSLC: its --version does not match the pin."
    echo "  expected:"; echo "    ${expected_version//$'\n'/$'\n'    }"
    got="${actual_version:-<no output>}"
    echo "  got:"; echo "    ${got//$'\n'/$'\n'    }"
    echo "  Use --fetch for the pinned build, or see docs/linux/dev.md (glslc pin)."
  } >&2
  exit 2
fi

# MARK: - Entry points

# `<file stem> <stage>`, in TKZ_FN_* order; the stem is the Metal function the module ports.
entries=(
  "tkz_bg_vertex vert"
  "tkz_bg_fragment frag"
  "tkz_rect_vertex vert"
  "tkz_rect_fragment frag"
  "tkz_glyph_vertex vert"
  "tkz_glyph_fragment frag"
)
glslc_flags=(-O --target-env=vulkan1.3 -Werror)

# Every tkz_*.<stage>.glsl must be listed, and every listed one must exist.
listed=""
for entry in "${entries[@]}"; do read -r stem stage <<<"$entry"; listed+="$stem.$stage.glsl"$'\n'; done
on_disk="$(cd "$glsl_dir" && shopt -s nullglob && printf '%s\n' tkz_*.vert.glsl tkz_*.frag.glsl | sort)"
[ "$on_disk" = "$(printf '%s' "$listed" | sort)" ] \
  || die "entry points in $glsl_dir differ from the list in this script:
  on disk: $(tr '\n' ' ' <<<"$on_disk")
  listed:  $(tr '\n' ' ' <<<"$listed")"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
out="$scratch/out"
mkdir -p "$out/generated" "$out/include" "$scratch/bin"

# SPIR-V words of a binary module, one lowercase 8-digit hex word per line.
binary_words() { od -An -v -tx4 "$1" | tr -s ' ' '\n' | sed '/^$/d'; }
# The words of a `glslc -mfmt=c` array, same format.
c_words() { tr -c '0-9a-fx' '\n' <"$1" | sed -n 's/^0x//p'; }

for entry in "${entries[@]}"; do
  read -r stem stage <<<"$entry"
  src="$stem.$stage.glsl"
  bin="$scratch/bin/$stem.spv"
  inc="$out/generated/$stem.spv.inc"
  (cd "$glsl_dir" && run "$GLSLC" "${glslc_flags[@]}" -fshader-stage="$stage" -o "$bin" "$src") \
    || fail "glslc failed on $src"
  run "$SPIRV_VAL" --target-env vulkan1.3 "$bin" || fail "spirv-val rejected $src"
  (cd "$glsl_dir" && run "$GLSLC" "${glslc_flags[@]}" -fshader-stage="$stage" -mfmt=c -o "$inc" "$src") \
    || fail "glslc -mfmt=c failed on $src"
  [ "$(binary_words "$bin")" = "$(c_words "$inc")" ] || fail "$src: -mfmt=c and binary output differ"
  echo "build-shaders-linux: $src -> generated/$stem.spv.inc ($(wc -c <"$bin") bytes, spirv-val ok)" >&2
done

# MARK: - Header and arrays

upper() { tr '[:lower:]' '[:upper:]' <<<"${1#tkz_}"; }
stage_enum() { [ "$1" = vert ] && echo TKZ_SPIRV_STAGE_VERTEX || echo TKZ_SPIRV_STAGE_FRAGMENT; }

{
  cat <<EOF
// TkzShadersSPIRV.h — GENERATED by scripts/build-shaders-linux.sh. Do not edit: change
// Sources/TkzShadersSPIRV/glsl/ and rerun the script.
//
// SPIR-V for the three terminal pipelines (WOR-313), one module per Terminal.metal function and
// named after it, compiled offline with the pinned glslc so that tkzmux links no shader compiler.
// Binding contract and layout: glsl/TkzShaderTypes.glsl (the GLSL mirror of TkzShaderTypes.h).

#ifndef TKZ_SHADERS_SPIRV_H
#define TKZ_SHADERS_SPIRV_H

#include <stddef.h>
#include <stdint.h>

/// The compiler that produced the arrays: \`glslc --version\` lines 1-3 and the flags.
#define TKZ_SPIRV_SHADERC_VERSION "$glslc_pin"
#define TKZ_SPIRV_SPIRV_TOOLS_VERSION "$spirv_tools_version"
#define TKZ_SPIRV_GLSLANG_VERSION "$glslang_version"
#define TKZ_SPIRV_GLSLC_FLAGS "${glslc_flags[*]}"

/// Every module's only entry point.
#define TKZ_SPIRV_ENTRY_POINT "main"

/// Shader stages, numerically equal to \`VkShaderStageFlagBits\` so they can be passed through.
enum {
    TKZ_SPIRV_STAGE_VERTEX = 0x1,
    TKZ_SPIRV_STAGE_FRAGMENT = 0x10
};

/// Index into the module table, in \`TKZ_FN_*\` order.
typedef uint32_t TkzSPIRVShader;
enum {
EOF
  i=0
  for entry in "${entries[@]}"; do
    read -r stem stage <<<"$entry"
    echo "    TKZ_SPIRV_$(upper "$stem") = $i,"
    i=$((i + 1))
  done
  cat <<EOF
    TKZ_SPIRV_SHADER_COUNT = $i
};

typedef struct TkzSPIRVModule {
    /// The Terminal.metal function this module ports (a \`TKZ_FN_*\` value).
    const char *metalFunction;
    /// \`TKZ_SPIRV_ENTRY_POINT\`.
    const char *entryPoint;
    /// \`TKZ_SPIRV_STAGE_*\`.
    uint32_t stage;
    /// SPIR-V words, for \`VkShaderModuleCreateInfo.pCode\`.
    const uint32_t *code;
    /// In bytes, for \`VkShaderModuleCreateInfo.codeSize\`.
    size_t codeSize;
} TkzSPIRVModule;

/// The module for \`shader\`, or NULL when \`shader >= TKZ_SPIRV_SHADER_COUNT\`.
const TkzSPIRVModule *tkz_spirv_module(TkzSPIRVShader shader);

/// The arrays themselves, and their sizes in bytes, for C callers.
EOF
  for entry in "${entries[@]}"; do
    read -r stem stage <<<"$entry"
    echo "extern const uint32_t tkz_spirv_${stem#tkz_}[];"
    echo "extern const size_t tkz_spirv_${stem#tkz_}_size;"
  done
  cat <<EOF

#endif /* TKZ_SHADERS_SPIRV_H */
EOF
} >"$out/include/TkzShadersSPIRV.h"

{
  cat <<EOF
// TkzShadersSPIRV.c — GENERATED by scripts/build-shaders-linux.sh. Do not edit.
// The arrays are the verbatim \`glslc -mfmt=c\` output in generated/.

#include "TkzShadersSPIRV.h"
EOF
  for entry in "${entries[@]}"; do
    read -r stem stage <<<"$entry"
    name="tkz_spirv_${stem#tkz_}"
    cat <<EOF

const uint32_t ${name}[] =
#include "generated/$stem.spv.inc"
;
const size_t ${name}_size = sizeof($name);
EOF
  done
  cat <<EOF

static const TkzSPIRVModule modules[TKZ_SPIRV_SHADER_COUNT] = {
EOF
  for entry in "${entries[@]}"; do
    read -r stem stage <<<"$entry"
    name="tkz_spirv_${stem#tkz_}"
    echo "    { \"$stem\", TKZ_SPIRV_ENTRY_POINT, $(stage_enum "$stage"), $name, sizeof($name) },"
  done
  cat <<EOF
};

const TkzSPIRVModule *tkz_spirv_module(TkzSPIRVShader shader) {
    return shader < TKZ_SPIRV_SHADER_COUNT ? &modules[shader] : NULL;
}
EOF
} >"$out/TkzShadersSPIRV.c"

# MARK: - Install or compare

# The generated files present under $1, sorted, relative to it.
generated_files() {
  (cd "$1" && shopt -s nullglob \
    && for f in TkzShadersSPIRV.c include/TkzShadersSPIRV.h generated/*.spv.inc; do
         [ -f "$f" ] && echo "$f"
       done | sort)
}

if [ "$check" = 1 ]; then
  drift=0
  if [ "$(generated_files "$out")" != "$(generated_files "$target_dir")" ]; then
    echo "build-shaders-linux: generated file set differs:" >&2
    diff <(generated_files "$target_dir") <(generated_files "$out") >&2 || true
    drift=1
  fi
  while read -r f; do
    if ! cmp -s "$out/$f" "$target_dir/$f"; then
      echo "build-shaders-linux: drift in Sources/TkzShadersSPIRV/$f" >&2
      drift=1
    fi
  done < <(generated_files "$out")
  [ "$drift" = 0 ] || fail "committed SPIR-V is stale or was built by another compiler; rerun scripts/build-shaders-linux.sh"
  echo "build-shaders-linux: no drift (${#entries[@]} modules, glslc $glslc_pin)" >&2
else
  mkdir -p "$target_dir/generated" "$target_dir/include"
  rm -f "$target_dir"/generated/*.spv.inc
  cp "$out"/generated/*.spv.inc "$target_dir/generated/"
  cp "$out/include/TkzShadersSPIRV.h" "$target_dir/include/"
  cp "$out/TkzShadersSPIRV.c" "$target_dir/"
  echo "build-shaders-linux: wrote Sources/TkzShadersSPIRV (${#entries[@]} modules, glslc $glslc_pin)" >&2
fi
