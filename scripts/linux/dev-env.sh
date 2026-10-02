#!/usr/bin/env bash
# dev-env.sh: check that this Linux host has everything the tkzmux Linux port builds and tests with.
#
# Read-only. It installs nothing, edits nothing and needs no root. Every gap is printed with the
# package to install (pacman on Arch/Omarchy, apt on Debian/Ubuntu) or the step in
# docs/linux/dev.md that fixes it, and the gaps are summed up in one install line at the end.
# The pins (Swift, zig, glslc, GTK floor) are read from the `pin` lines in docs/linux/dev.md,
# so that file stays the only place they are written down.
#
# Usage:
#   scripts/linux/dev-env.sh [options]
#
#   --smoke        also build and run a `--static-swift-stdlib` hello world with both SwiftPM
#                  build systems, in a temporary directory that is removed afterwards
#   --container    also check the container route: podman, or docker with docker-group access
#   --dev-md FILE  read the pins from FILE instead of docs/linux/dev.md
#   -q, --quiet    print only gaps, warnings and the verdict
#   -h, --help     show this help
#
# Env: DEV_ENV_SYSROOT prefixes every absolute file probe (headers, Vulkan ICD and layer
# manifests); it exists so the script itself can be tested against a fake tree.
#
# Exit status: 0 = no gaps (warnings allowed), 1 = at least one gap, 2 = usage or pin error.
set -uo pipefail
export LC_ALL=C

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dev_md="$script_dir/../../docs/linux/dev.md"
sysroot="${DEV_ENV_SYSROOT:-}"
smoke=0
container=0
quiet=0

usage() { sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }
die() { echo "dev-env: $*" >&2; exit 2; }
say() { [ "$quiet" -eq 1 ] || printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) smoke=1; shift ;;
    --container) container=1; shift ;;
    --dev-md) [ $# -ge 2 ] || die "--dev-md needs a file"; dev_md="$2"; shift 2 ;;
    --dev-md=*) dev_md="${1#--dev-md=}"; shift ;;
    -q|--quiet) quiet=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -r "$dev_md" ] || die "pin file not readable: $dev_md"
pin() { awk -v k="$1" '$1 == "pin" && $2 == k { print $3; exit }' "$dev_md"; }
swift_pin="$(pin swift)"
zig_pin="$(pin zig)"
glslc_pin="$(pin glslc)"
gtk_floor="$(pin gtk4)"
for v in swift_pin zig_pin glslc_pin gtk_floor; do
  [ -n "${!v}" ] || die "no '${v%_*}' pin line in $dev_md"
done

# --------------------------------------------------------------------------- distro
pm=both
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  os_ids="$(. /etc/os-release; printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
  case " $os_ids " in
    *" arch "*) pm=pacman ;;
    *" debian "*|*" ubuntu "*) pm=apt ;;
  esac
fi

# --------------------------------------------------------------------------- reporting
gaps=0
warns=0
pac_missing=()
apt_missing=()
manual_steps=()

ok() { say "  ok    $1${2:+  ($2)}"; }
warn() { printf '  warn  %s\n' "$1"; warns=$((warns + 1)); }
# gap <what> <pacman pkg or -> <apt pkg or -> <needed by> [manual fix]
gap() {
  local what="$1" pac="$2" deb="$3" by="$4" fix="${5:-}" how=""
  case "$pm" in
    pacman) [ "$pac" != "-" ] && how="pacman -S $pac" ;;
    apt) [ "$deb" != "-" ] && how="apt install $deb" ;;
    *) [ "$pac" != "-" ] && how="pacman -S $pac / apt install $deb" ;;
  esac
  [ -n "$fix" ] && how="${how:+$how; }$fix"
  printf '  GAP   %s  [needed by %s]\n        fix: %s\n' "$what" "$by" "${how:-see docs/linux/dev.md}"
  gaps=$((gaps + 1))
  [ "$pac" != "-" ] && pac_missing+=("$pac")
  [ "$deb" != "-" ] && apt_missing+=("$deb")
  [ -n "$fix" ] && manual_steps+=("$fix")
  return 0
}

# version_ge A B: true when version A >= B (dot-separated numbers)
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# --------------------------------------------------------------------------- swift
say "Host: $(uname -sm), glibc $(ldd --version 2>/dev/null | sed -n '1s/.* //p'), package manager: $pm"
say "Pins (docs/linux/dev.md): swift $swift_pin, zig $zig_pin.x, glslc $glslc_pin, gtk4 >= $gtk_floor"
say ""
say "Swift toolchain"

toolchain_bin=""
if ! command -v swift >/dev/null 2>&1; then
  gap "swift $swift_pin not on PATH" - - "all" "install the swift.org tarball (dev.md, Toolchain)"
else
  toolchain_bin="$(dirname "$(readlink -f "$(command -v swift)")")"
  swift_line="$(swift --version 2>&1 | grep -m1 'Swift version')"
  if [[ "$swift_line" == *"(swift-$swift_pin-RELEASE)"* ]]; then
    ok "swift $swift_pin" "$toolchain_bin"
  else
    gap "swift --version is '${swift_line:-<no output>}', pin is swift-$swift_pin-RELEASE" - - "all" \
      "put the pinned toolchain first on PATH (dev.md, Toolchain)"
  fi
fi

if [ -n "$toolchain_bin" ]; then
  # Libraries the toolchain needs from the host. Checked twice: with the current environment
  # (what `--build-system native` sees), and with LD_LIBRARY_PATH unset, which is what the
  # swiftbuild backend gives the compiler and linker it spawns.
  # missing_libs BIN [clean]: sonames BIN cannot load; with `clean`, as seen with LD_LIBRARY_PATH unset
  missing_libs() {
    if [ "${2:-}" = clean ]; then env -u LD_LIBRARY_PATH ldd "$1" 2>/dev/null; else ldd "$1" 2>/dev/null; fi \
      | awk '/=> not found/ { print $1 }' | sort -u | tr '\n' ' '
  }
  # toolchain_gap <what> <missing sonames> <needed by>: libxml2.so.2 is a package on both distros,
  # the ncurses sonames are links into the toolchain (dev.md, Compat libraries)
  toolchain_gap() {
    local pac=- deb=- fix=""
    case " $2 " in *" libxml2.so.2 "*) pac=libxml2-legacy deb=libxml2 ;; esac
    case " $2 " in *" libncurses.so.6 "*|*" libform.so.6 "*|*" libpanel.so.6 "*|*" libicu"*)
      fix="link the compat libraries into the toolchain (dev.md, Compat libraries)" ;; esac
    gap "$1" "$pac" "$deb" "$3" "$fix"
  }
  tools=(swift-frontend swift-driver swift-package swift-build)
  for tool in "${tools[@]}"; do
    [ -x "$toolchain_bin/$tool" ] || { gap "toolchain file $tool missing" - - "all" "reinstall the toolchain"; continue; }
    m="$(missing_libs "$toolchain_bin/$tool")"
    [ -n "$m" ] && toolchain_gap "$tool cannot load: $m" "$m" "all"
  done
  m=""
  for tool in "${tools[@]}"; do
    [ -x "$toolchain_bin/$tool" ] && m+="$(missing_libs "$toolchain_bin/$tool" clean)"
  done
  m="$(printf '%s' "$m" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ')"
  if [ -n "$m" ]; then
    toolchain_gap "without LD_LIBRARY_PATH the toolchain cannot load $m(--build-system swiftbuild drops it)" \
      "$m" "WOR-300 S4, WOR-303 S1"
  else
    ok "toolchain libraries resolve without LD_LIBRARY_PATH" "both build systems"
  fi
  static_core="$toolchain_bin/../lib/swift_static/linux/libswiftCore.a"
  if [ -f "$static_core" ]; then ok "static Swift runtime" "--static-swift-stdlib"
  else gap "static Swift runtime missing ($static_core)" - - "all" "reinstall the toolchain"; fi
  # The toolchain's own lldb is built for Ubuntu (libedit.so.2, libpython3.12). It is a convenience,
  # never a gate.
  if [ ! -x "$toolchain_bin/lldb" ]; then warn "toolchain lldb missing (Swift-aware debugging unavailable; dev.md, Debugging)"
  elif m="$(missing_libs "$toolchain_bin/lldb")"; [ -n "$m" ]; then
    warn "toolchain lldb cannot load: $m(Swift-aware debugging unavailable; dev.md, Debugging)"
  else ok "toolchain lldb"; fi
fi

# --------------------------------------------------------------------------- probes
# cmd_outside_toolchain NAME: NAME on PATH, ignoring the Swift toolchain's bin directory (which
# also ships ld.lld and lldb, so a bare `command -v` would hide a missing system package).
cmd_outside_toolchain() {
  local d IFS=:
  for d in $PATH; do
    [ -n "$toolchain_bin" ] && [ "$(readlink -f "$d" 2>/dev/null)" = "$toolchain_bin" ] && continue
    [ -x "$d/$1" ] && { printf '%s\n' "$d/$1"; return 0; }
  done
  return 1
}
# file_glob PATTERN...: the first existing file under $sysroot matching any pattern
file_glob() {
  local p f
  for p in "$@"; do
    for f in $sysroot$p; do [ -e "$f" ] && { printf '%s\n' "$f"; return 0; }; done
  done
  return 1
}

# check_cmd <name> <pacman> <apt> <needed by> [cmd...]: any listed command present (system copies only)
check_cmd() {
  local name="$1" pac="$2" deb="$3" by="$4" c p
  shift 4
  for c in "$@"; do
    if p="$(cmd_outside_toolchain "$c")"; then ok "$name" "$p"; return 0; fi
  done
  gap "$name: no $* on PATH" "$pac" "$deb" "$by"
}
# check_file <name> <pacman> <apt> <needed by> <glob>...
check_file() {
  local name="$1" pac="$2" deb="$3" by="$4" f
  shift 4
  if f="$(file_glob "$@")"; then ok "$name" "$f"; else gap "$name: none of $*" "$pac" "$deb" "$by"; fi
}
# check_pc <name> <pacman> <apt> <needed by> <module> [min version]
check_pc() {
  local name="$1" pac="$2" deb="$3" by="$4" mod="$5" min="${6:-}" v
  if ! v="$(pkg-config --modversion "$mod" 2>/dev/null)"; then
    gap "$name (pkg-config $mod)" "$pac" "$deb" "$by"
  elif [ -n "$min" ] && ! version_ge "$v" "$min"; then
    gap "$name $v is below the floor $min" "$pac" "$deb" "$by"
  else
    ok "$name" "$mod $v"
  fi
}

say ""
say "Build tools"
if v="$(zig version 2>/dev/null)"; then
  if [[ "$v" == "$zig_pin".* ]]; then ok "zig $zig_pin.x" "$v"
  else gap "zig $v, pin is $zig_pin.x" zig - "WOR-302" "apt: ziglang.org tarball (dev.md)"; fi
else
  gap "zig $zig_pin.x" zig - "WOR-302" "apt: ziglang.org tarball (dev.md)"
fi
check_cmd "pkg-config" pkgconf pkg-config "all" pkg-config pkgconf
check_cmd "binutils (readelf, objcopy, objdump, nm)" binutils binutils "WOR-299, WOR-302" readelf
for t in objcopy objdump nm strings; do
  cmd_outside_toolchain "$t" >/dev/null || gap "binutils ($t)" binutils binutils "WOR-302"
done
check_cmd "ld.gold (toolchain default linker)" binutils binutils "all" ld.gold
check_cmd "lld (system ld.lld)" lld lld "WOR-300 S4" ld.lld
# First line: "shaderc v2026.3 v2026.3-…" upstream, plain "2026.3" in Arch's build.
if v="$(glslc --version 2>/dev/null | head -n1 | grep -oE '[0-9]{4}\.[0-9]+' | head -n1)"; [ -n "$v" ]; then
  if [ "$v" = "$glslc_pin" ]; then ok "glslc $glslc_pin" "shaderc"
  else gap "glslc $v, pin is $glslc_pin (SPIR-V drift check)" shaderc glslc "WOR-313 S2" \
    "install shaderc $glslc_pin (dev.md, glslc pin)"; fi
else
  gap "glslc $glslc_pin" shaderc glslc "WOR-313 S2"
fi
check_cmd "valgrind" valgrind valgrind "WOR-314" valgrind
check_cmd "lldb (system)" lldb lldb "debugging" lldb

say ""
say "Libraries (headers + pkg-config)"
check_pc "gtk4" gtk4 libgtk-4-dev "WOR-314" gtk4 "$gtk_floor"
check_pc "pangoft2" pango libpango1.0-dev "WOR-317" pangoft2
check_pc "freetype2" freetype2 libfreetype-dev "WOR-312" freetype2
check_pc "harfbuzz" harfbuzz libharfbuzz-dev "WOR-312" harfbuzz
check_pc "fontconfig" fontconfig libfontconfig-dev "WOR-312" fontconfig
check_pc "libxkbcommon" libxkbcommon libxkbcommon-dev "WOR-315 S1 (tests only)" xkbcommon
check_pc "Vulkan loader" vulkan-icd-loader libvulkan-dev "WOR-301, WOR-313" vulkan
check_file "vulkan-headers" vulkan-headers libvulkan-dev "WOR-301, WOR-313" \
  /usr/include/vulkan/vulkan.h
check_file "Vulkan validation layers" vulkan-validation-layers vulkan-validationlayers "WOR-301, WOR-313" \
  '/usr/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json' \
  '/etc/vulkan/explicit_layer.d/VkLayer_khronos_validation.json'
check_file "lavapipe (software Vulkan)" vulkan-swrast mesa-vulkan-drivers "WOR-301, WOR-313" \
  '/usr/share/vulkan/icd.d/lvp_icd*.json' '/etc/vulkan/icd.d/lvp_icd*.json'

say ""
say "Runtime tools"
check_cmd "vulkan-tools (vulkaninfo)" vulkan-tools vulkan-tools "WOR-301" vulkaninfo
check_cmd "wayland-utils (wayland-info)" wayland-utils wayland-utils "WOR-301" wayland-info
check_cmd "sway (headless compositor)" sway sway "WOR-314 S2/S5, WOR-300 S3" sway
check_cmd "dbus-daemon" dbus dbus-daemon "WOR-320 S1" dbus-daemon
check_cmd "zsh" zsh zsh "WOR-305, WOR-306" zsh
check_cmd "fish" fish fish "WOR-305, WOR-306" fish
check_cmd "podman (pinned CI images, rootless)" podman podman "WOR-303" podman

if [ "$container" -eq 1 ]; then
  say ""
  say "Container route"
  if cmd_outside_toolchain podman >/dev/null; then
    ok "podman" "rootless, no group needed"
  elif cmd_outside_toolchain docker >/dev/null; then
    if id -nG | tr ' ' '\n' | grep -qx docker; then ok "docker" "user is in the docker group"
    else gap "docker: user is not in the docker group (socket is root:docker 0660)" - - "container route" \
      "sudo usermod -aG docker \"\$USER\", then log in again; or use podman"; fi
  else
    gap "no container runtime" podman podman "container route"
  fi
fi

# --------------------------------------------------------------------------- smoke
if [ "$smoke" -eq 1 ] && [ -n "$toolchain_bin" ]; then
  say ""
  say "Smoke: --static-swift-stdlib hello world"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/Sources/hello"
  cat > "$tmp/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "hello", targets: [.executableTarget(name: "hello")])
EOF
  printf 'print("hello from static stdlib")\n' > "$tmp/Sources/hello/main.swift"
  for bs in native swiftbuild; do
    rm -rf "$tmp/.build"
    if ! out="$(cd "$tmp" && swift build --build-system "$bs" --static-swift-stdlib 2>&1)"; then
      gap "--build-system $bs --static-swift-stdlib build failed: $(printf '%s' "$out" | grep -m1 -iE 'error' | cut -c1-160)" \
        - - "WOR-300 S4, WOR-303" "see dev.md, Compat libraries"
      continue
    fi
    exe="$(find "$tmp/.build" -type f -name hello -perm -u+x | head -n1)"
    if [ -n "$exe" ] && [ "$("$exe")" = "hello from static stdlib" ]; then
      ok "--build-system $bs --static-swift-stdlib" "built and ran"
    else
      gap "--build-system $bs: the static hello world did not run" - - "WOR-300 S4, WOR-303"
    fi
  done
fi

# --------------------------------------------------------------------------- verdict
say ""
if [ "$gaps" -eq 0 ]; then
  echo "dev-env: OK, no gaps ($warns warning(s))"
  exit 0
fi
echo "dev-env: $gaps gap(s), $warns warning(s)"
dedup() { printf '%s\n' "$@" | awk 'NF && !seen[$0]++' | paste -sd' ' -; }
if [ "${#pac_missing[@]}" -gt 0 ] && [ "$pm" != apt ]; then
  echo "  pacman: sudo pacman -S --needed $(dedup "${pac_missing[@]}")"
fi
if [ "${#apt_missing[@]}" -gt 0 ] && [ "$pm" != pacman ]; then
  echo "  apt:    sudo apt install $(dedup "${apt_missing[@]}")"
fi
if [ "${#manual_steps[@]}" -gt 0 ]; then
  printf '%s\n' "${manual_steps[@]}" | awk '!seen[$0]++ { print "  then:   " $0 }'
fi
exit 1
