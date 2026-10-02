# shellcheck shell=bash
# Shared by the libghostty-vt vendor scripts: scripts/build-ghostty-vt.sh (macOS xcframework)
# and scripts/build-ghostty-vt-linux.sh (Linux artifact bundle). Sourced, never executed.
#
# The caller sets VENDOR (vendor/ghostty-vt) and SCRIPT_NAME (prefix for error messages) first.
#
#   GHOSTTY_COMMIT   full sha to vendor (default: vendor/ghostty-vt/COMMIT)
#   GHOSTTY_SRC      working checkout (default: $TMPDIR/ghostty-vt-src; zig caches are kept between runs)
#
# Portable between macOS (bash 3.2, BSD userland) and Linux (GNU userland).

: "${VENDOR:?set VENDOR before sourcing ghostty-vt-common.sh}"
: "${SCRIPT_NAME:?set SCRIPT_NAME before sourcing ghostty-vt-common.sh}"

GHOSTTY_DEFAULT_COMMIT="82232ecde55405559dec29c5466cb9e39938cb41"
GHOSTTY_COMMIT="${GHOSTTY_COMMIT:-$(cat "$VENDOR/COMMIT" 2>/dev/null || echo "$GHOSTTY_DEFAULT_COMMIT")}"
GHOSTTY_SRC="${GHOSTTY_SRC:-${TMPDIR:-/tmp}/ghostty-vt-src}"
GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"

die()  { echo "$SCRIPT_NAME: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1${2:+ ($2)}"; }

# zig 0.16.x: Ghostty's build.zig at the pinned commit does not build with any other minor.
ghostty_check_zig() {
  ZIG_VERSION="$(zig version)"
  [[ "$ZIG_VERSION" == 0.16.* ]] || die "zig 0.16.x required, found $ZIG_VERSION"
}

ghostty_check_commit() {
  [[ "$GHOSTTY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "GHOSTTY_COMMIT must be a full 40-char sha (got '$GHOSTTY_COMMIT')"
}

# Shallow-fetch exactly $GHOSTTY_COMMIT into $GHOSTTY_SRC, check out it detached and verify both
# the sha and the lib-vt headers this repo builds against.
ghostty_fetch() {
  echo "==> fetching ghostty@${GHOSTTY_COMMIT:0:12} into $GHOSTTY_SRC"
  mkdir -p "$GHOSTTY_SRC"
  if [[ ! -d "$GHOSTTY_SRC/.git" ]]; then
    git -C "$GHOSTTY_SRC" init -q
    git -C "$GHOSTTY_SRC" remote add origin "$GHOSTTY_REPO"
  fi
  git -C "$GHOSTTY_SRC" fetch -q --depth 1 origin "$GHOSTTY_COMMIT"
  git -C "$GHOSTTY_SRC" checkout -q --detach FETCH_HEAD
  [[ "$(git -C "$GHOSTTY_SRC" rev-parse HEAD)" == "$GHOSTTY_COMMIT" ]] || die "checkout is not $GHOSTTY_COMMIT"
  local h
  for h in include/ghostty/vt.h include/ghostty/vt/render.h include/ghostty/vt/snapshot.h; do
    [[ -f "$GHOSTTY_SRC/$h" ]] || die "$h missing at this commit"
  done
}
