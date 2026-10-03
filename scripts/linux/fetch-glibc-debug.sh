#!/usr/bin/env bash
# fetch-glibc-debug.sh — unpack Arch's current glibc and its debug symbols for Valgrind (WOR-314 S2).
#
#   scripts/linux/fetch-glibc-debug.sh <dest>
#   TKZMUX_VALGRIND_GLIBC=<dest>/usr/lib scripts/linux/asan-valgrind.sh valgrind
#
# Valgrind refuses to start without symbols for the dynamic loader (it must redirect ld.so's memcmp
# and strlen), and Arch strips them into `glibc-debug`, in the [core-debug] repository, which keeps
# only the current version. A pinned image (the CI snapshot) or a machine that has not upgraded
# yet therefore has no matching debug package, and debuginfod.archlinux.org answers 404 for it.
# This takes the current glibc and glibc-debug of one version from an Arch mirror instead, checks
# their signatures when pacman-key is set up (it is in the CI image), and unpacks both into <dest>
# without installing anything; asan-valgrind.sh then runs the program through that loader.
#
# ARCH_MIRROR overrides the mirror (default https://geo.mirror.pkgbuild.com).
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <dest>" >&2
  exit 64
fi
dest="$1"
mirror="${ARCH_MIRROR:-https://geo.mirror.pkgbuild.com}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The version both repositories carry now, from their databases.
version_in() {
  curl -fsSL --retry 3 "$mirror/$1/os/x86_64/$1.db" | tar -tz \
    | sed -n "s|^$2-\([0-9][^/]*\)/\$|\1|p" | head -n 1
}
version="$(version_in core glibc)"
debug_version="$(version_in core-debug glibc-debug)"
if [ -z "$version" ] || [ "$version" != "$debug_version" ]; then
  echo "fetch-glibc-debug.sh: core has glibc '$version', core-debug has glibc-debug '$debug_version'; retry later" >&2
  exit 1
fi

mkdir -p "$dest"
for package in "core glibc" "core-debug glibc-debug"; do
  read -r repo name <<< "$package"
  file="$name-$version-x86_64.pkg.tar.zst"
  url="$mirror/$repo/os/x86_64/${file//+/%2B}"
  curl -fsSL --retry 3 -o "$work/$file" "$url"
  curl -fsSL --retry 3 -o "$work/$file.sig" "$url.sig"
  if command -v pacman-key > /dev/null && pacman-key --list-keys > /dev/null 2>&1; then
    pacman-key --verify "$work/$file.sig" "$work/$file"
  else
    echo "fetch-glibc-debug.sh: pacman-key is not set up; $file is not signature-checked" >&2
  fi
  # usr/lib/getconf holds hard links into usr/bin, which is not unpacked.
  tar --zstd -xf "$work/$file" -C "$dest" --exclude usr/lib/getconf usr/lib
done

loader="$dest/usr/lib/ld-linux-x86-64.so.2"
build_id="$(readelf -n "$loader" | sed -n 's/.*Build ID: \([0-9a-f]*\)/\1/p')"
if [ ! -e "$dest/usr/lib/debug/.build-id/${build_id:0:2}/${build_id:2}.debug" ]; then
  echo "fetch-glibc-debug.sh: no debug file for $loader (build id $build_id)" >&2
  exit 1
fi
echo "glibc $version with debug symbols in $dest/usr/lib"
