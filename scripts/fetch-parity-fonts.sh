#!/usr/bin/env bash
# fetch-parity-fonts.sh: download the pinned parity test fonts and verify every SHA-256 (WOR-312 S4).
#
#   scripts/fetch-parity-fonts.sh [--lock FILE] [--check] [DEST]
#
#   --lock FILE   the lockfile (default: Tests/Parity/Fonts/fonts.lock.json)
#   --check       download nothing: fail unless DEST already holds exactly the locked files
#   DEST          where the fonts go (default: $TKZMUX_PARITY_FONTS, else
#                 ${XDG_CACHE_HOME:-$HOME/.cache}/tkzmux/parity-fonts, the directory
#                 FontconfigConfiguration.defaultParityFontDirectory reads)
#
# Parity mode's private FcConfig sees the bundled fonts and DEST, nothing else, so CI (Ubuntu and
# Arch) and every desktop resolve the same fallback faces. The fonts (Noto Sans Mono, Noto Sans
# CJK SC, Noto Color Emoji at pinned upstream tags) are fetched rather than committed: together
# they are far over the committed-reference budget. CI caches DEST keyed on the lockfile's hash.
#
# Every download goes to a temporary name and is renamed into place only when its SHA-256 equals
# the lockfile's, so a wrong or truncated file never lands. A file already in DEST is kept when its
# hash matches and fetched again when it does not. Font files the lockfile does not list are
# removed from DEST, so the directory is exactly the locked set.
#
# The lockfile is JSON with one font object per line, each carrying "file", "sha256" and "url";
# this script reads it with sed (no jq or python on the CI images) and refuses any other layout.
#
# Exit status: 0 = DEST holds exactly the locked fonts, 1 = a hash mismatch, a failed download or
#              (with --check) a missing file, 2 = usage or lockfile error.
set -euo pipefail
export LC_ALL=C

die() { echo "fetch-parity-fonts: $*" >&2; exit 2; }
fail() { echo "fetch-parity-fonts: $*" >&2; status=1; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock="$root/Tests/Parity/Fonts/fonts.lock.json"
check=0
dest=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lock) [ $# -ge 2 ] || die "--lock needs a file"; lock="$2"; shift 2 ;;
    --check) check=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "unknown option '$1' (try --help)" ;;
    *) [ -z "$dest" ] || die "more than one DEST"; dest="$1"; shift ;;
  esac
done

if [ -z "$dest" ]; then
  if [[ "${TKZMUX_PARITY_FONTS:-}" == /* ]]; then
    dest="$TKZMUX_PARITY_FONTS"
  else
    # An unset, empty or relative XDG_CACHE_HOME counts as unset (XDG Base Directory spec).
    cache="${XDG_CACHE_HOME:-}"
    [[ "$cache" == /* ]] || cache="$HOME/.cache"
    dest="$cache/tkzmux/parity-fonts"
  fi
fi

[ -f "$lock" ] || die "no lockfile at $lock"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# One line per font: file, sha256, url (tab-separated).
field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" <<< "$2"; }
entries=()
while IFS= read -r line; do
  file="$(field file "$line")"; sum="$(field sha256 "$line")"; url="$(field url "$line")"
  [ -n "$file" ] && [ -n "$sum" ] && [ -n "$url" ] || die "a font line lacks file, sha256 or url: $line"
  [[ "$file" =~ ^[A-Za-z0-9._-]+$ ]] || die "not a plain file name: $file"
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || die "not a SHA-256: $sum ($file)"
  entries+=("$file"$'\t'"$sum"$'\t'"$url")
done < <(grep '"file":' "$lock")
[ "${#entries[@]}" -gt 0 ] || die "no fonts in $lock"

mkdir -p "$dest"
status=0
listed=" "
for entry in "${entries[@]}"; do
  IFS=$'\t' read -r file sum url <<< "$entry"
  listed+="$file "
  target="$dest/$file"
  if [ -f "$target" ] && [ "$(sha256 "$target")" = "$sum" ]; then
    echo "ok       $file"
    continue
  fi
  if [ "$check" = 1 ]; then
    fail "$file: missing or wrong hash in $dest"
    continue
  fi
  part="$dest/.$file.part"
  rm -f "$part"
  if ! curl -fsSL --retry 3 -o "$part" "$url"; then
    rm -f "$part"
    fail "$file: download failed ($url)"
    continue
  fi
  got="$(sha256 "$part")"
  if [ "$got" != "$sum" ]; then
    rm -f "$part"
    fail "$file: SHA-256 $got, the lockfile pins $sum ($url)"
    continue
  fi
  mv -f "$part" "$target"
  echo "fetched  $file"
done

# The directory is exactly the locked set: a font left from an older lockfile would join the
# fallback lists.
for path in "$dest"/*; do
  [ -f "$path" ] || continue
  name="$(basename "$path")"
  case "$listed" in *" $name "*) continue ;; esac
  case "$name" in
    *.ttf|*.otf|*.ttc|*.TTF|*.OTF|*.TTC)
      if [ "$check" = 1 ]; then fail "$name: not in the lockfile"; else rm -f "$path"; echo "removed  $name"; fi ;;
  esac
done

exit "$status"
