#!/usr/bin/env bash
# Point the Homebrew cask at a freshly published release (TKZ-34).
#
#   scripts/bump-cask.sh <version> <sha256>
#
# Rewrites the `version` and `sha256` stanzas of $TAP_DIR/Casks/tkzmux.rb, commits
# "tkzmux <version>" and pushes. The cask's `url` is built from `#{version}`, so those two
# stanzas are the whole update — see Casks/tkzmux.rb in tkz0/homebrew-tap.
#
# Environment:
#   TAP_DIR         REQUIRED. An existing clone of tkz0/homebrew-tap with a push remote.
#                   This script never clones, never creates the remote, never taps.
#   BUMP_COMMIT     0 = rewrite the file and stop (implies no push). Default 1.
#   BUMP_PUSH       0 = commit but do not push. Default 1.
#   BUMP_REMOTE     git remote to push to. Default "origin".
#   BUMP_GIT_NAME   committer name/email, for CI where git has no identity configured.
#   BUMP_GIT_EMAIL  Defaults are generic; no personal names live in this repo.
#
# Called at the end of scripts/make-dist.sh (only when this file exists and TAP_DIR is set) and
# from .github/workflows/release.yml. Both paths can run for the same tag, so a bump that
# changes nothing is a success, not an error: re-running is a no-op.
set -euo pipefail

die() { echo "bump-cask: $*" >&2; exit 1; }

# ------------------------------------------------------------------------------------ arguments
(($# == 2)) || die "usage: bump-cask.sh <version> <sha256>
  version   1.2.3, or a prerelease such as 1.0.0-rc1 (a leading 'v' is stripped)
  sha256    64 hex characters — the shasum of the release zip"

VERSION="${1#v}"
SHA256="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"

# Semver without build metadata: `+` never appears in a released version. make-app.sh only emits
# a bare `<tag>` for a clean tag; every dev build carries `-dev.N+<sha>` and must never be
# published to the tap, so the `+` exclusion is the guard that catches that mistake.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
  || die "invalid version '$1' (want 1.2.3 or 1.2.3-rc1; dev builds with a +sha are not releasable)"
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid sha256 '$2' (want 64 hex characters)"

# ---------------------------------------------------------------------------------------- tap
[[ -n "${TAP_DIR:-}" ]] || die "TAP_DIR is not set — point it at a clone of tkz0/homebrew-tap"
[[ -d "$TAP_DIR" ]] || die "TAP_DIR '$TAP_DIR' is not a directory"
CASK="$TAP_DIR/Casks/tkzmux.rb"
[[ -f "$CASK" ]] || die "no Casks/tkzmux.rb under TAP_DIR '$TAP_DIR'"

# Both stanzas must exist and be unique, or the rewrite below would silently do nothing (or the
# wrong thing) and push a cask still pointing at the previous release.
for stanza in version sha256; do
  n="$(grep -cE "^[[:space:]]*$stanza \"[^\"]*\"" "$CASK" || true)"
  ((n == 1)) || die "expected exactly one '$stanza \"…\"' line in $CASK, found $n"
done

# ------------------------------------------------------------------------------------- rewrite
# perl, not `sed -i`: BSD sed wants an argument to -i and GNU sed does not, and this script runs
# both on a developer's Mac and on a runner. Anchored at line start so the `url` line's
# `#{version}` interpolation is untouched.
BUMP_VERSION="$VERSION" BUMP_SHA256="$SHA256" perl -pi -e '
  s/^(\s*version )"[^"]*"/$1"$ENV{BUMP_VERSION}"/;
  s/^(\s*sha256 )"[^"]*"/$1"$ENV{BUMP_SHA256}"/;
' "$CASK"

grep -qF "version \"$VERSION\"" "$CASK" || die "version rewrite did not take effect in $CASK"
grep -qF "sha256 \"$SHA256\"" "$CASK" || die "sha256 rewrite did not take effect in $CASK"

echo "==> $CASK -> version $VERSION"

if [[ "${BUMP_COMMIT:-1}" != "1" ]]; then
  echo "==> BUMP_COMMIT=0, leaving the change uncommitted"
  exit 0
fi

# ------------------------------------------------------------------------------ commit + push
git -C "$TAP_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "TAP_DIR '$TAP_DIR' is not a git repo"

# Idempotent: make dist and the release workflow can both call this for the same tag. Nothing to
# commit means the tap is already at this version — succeed quietly rather than failing the
# release on `git commit` with an empty index.
# `diff HEAD` and not a bare `diff`: the latter compares against the index, so a cask that was
# already staged in a dirty tap clone would read as "nothing to do" and be left uncommitted.
if git -C "$TAP_DIR" diff --quiet HEAD -- Casks/tkzmux.rb; then
  echo "==> tap already at $VERSION, nothing to commit"
  exit 0
fi

git -C "$TAP_DIR" add -- Casks/tkzmux.rb
git -C "$TAP_DIR" \
  -c "user.name=${BUMP_GIT_NAME:-tkzmux release}" \
  -c "user.email=${BUMP_GIT_EMAIL:-tkzmux-release@users.noreply.github.com}" \
  commit -q -m "tkzmux $VERSION"
echo "==> committed 'tkzmux $VERSION'"

if [[ "${BUMP_PUSH:-1}" != "1" ]]; then
  echo "==> BUMP_PUSH=0, not pushing (push with: git -C \"$TAP_DIR\" push)"
  exit 0
fi

REMOTE="${BUMP_REMOTE:-origin}"
git -C "$TAP_DIR" remote get-url "$REMOTE" >/dev/null 2>&1 \
  || die "no '$REMOTE' remote in $TAP_DIR — the commit is made but not pushed"
BRANCH="$(git -C "$TAP_DIR" rev-parse --abbrev-ref HEAD)"
# `push HEAD:HEAD` is not a thing; a detached tap checkout has to be named explicitly.
[[ "$BRANCH" != "HEAD" ]] \
  || die "TAP_DIR '$TAP_DIR' is on a detached HEAD — check out a branch (the commit is made but not pushed)"
echo "==> git push $REMOTE $BRANCH"
git -C "$TAP_DIR" push "$REMOTE" "HEAD:$BRANCH"
echo "==> tap updated to tkzmux $VERSION"
