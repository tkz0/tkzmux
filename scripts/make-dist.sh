#!/usr/bin/env bash
# Cut a release (TKZ-39 / M6.3): signed + notarized build/tkzmux.app -> a zip and a sha256 under
# build/dist -> a GitHub release on the tag HEAD already carries -> optionally a Homebrew cask
# bump. Driven by `make dist`; see docs/release.md for the manual prerequisites.
#
#   SIGN_IDENTITY   required, must not be "-" (Gatekeeper rejects an ad-hoc signature elsewhere)
#   NOTARY_PROFILE  notarytool keychain profile; passed straight through to `make notarize`
#   DIST_DRAFT=1    create the GitHub release as a draft
#   TAP_DIR         if set and scripts/bump-cask.sh exists, bump the cask in that tap checkout
#
# The published asset URL is a hard contract with the Homebrew cask:
#   https://github.com/tkz0/tkzmux/releases/download/v<version>/tkzmux-<version>-arm64.zip
# Renaming the zip breaks every previously published cask, so the name is built in one place
# (below) from the version stamped into the built app, never from a second derivation.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-tkzmux-notary}"
DIST_DRAFT="${DIST_DRAFT:-}"
TAP_DIR="${TAP_DIR:-}"
REPO_SLUG="tkz0/tkzmux"

# ------------------------------------------------------------------- preflight (before a build)
# All three guards are evaluated and reported together. Stopping at the first one turns fixing a
# release into three round trips of a multi-minute build.
echo "==> preflight"
problems=0
note() { echo "    FAIL $1"; problems=$((problems + 1)); }

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  note "SIGN_IDENTITY is \"-\" (ad-hoc). A distributed build needs a Developer ID:"
  echo "         SIGN_IDENTITY=\"Developer ID Application: NAME (TEAMID)\" make dist"
  echo "         (available identities: security find-identity -v -p codesigning)"
else
  echo "    ok   SIGN_IDENTITY = $SIGN_IDENTITY"
fi

# Deliberately STRICTER than the version stamp's notion of dirty. `make-app.sh` follows git's own
# definition (`git describe --dirty` = modified tracked files, untracked ignored) because that is
# what the version string means. A release guard has to mean something else: `swift build`
# compiles every Sources/**/*.swift that is on disk, so an *untracked* new file would end up in
# the notarized binary while being absent from the tag. `git status --porcelain` honours
# .gitignore, so build/ and .build/ do not trip it.
if [[ -n "$(git status --porcelain)" ]]; then
  note "working tree is not clean — a release must contain nothing that is not in the tag:"
  git status --short | sed 's/^/         /'
else
  echo "    ok   working tree clean (no modified or untracked files)"
fi

TAG="$(git describe --exact-match --tags --match 'v*' HEAD 2>/dev/null || true)"
if [[ -z "$TAG" ]]; then
  note "HEAD carries no v* tag. Tag the release commit first:"
  echo "         git tag -a v0.1.0 -m 'tkzmux 0.1.0' && git push origin v0.1.0"
else
  echo "    ok   HEAD is tagged $TAG"
  # `gh release create <tag>` happily invents a tag on the remote, pointing at the default
  # branch head rather than at this commit, if the tag was never pushed. Catch that here.
  if [[ -z "$(git ls-remote --tags origin "refs/tags/$TAG" 2>/dev/null || true)" ]]; then
    note "tag $TAG is not on origin (or origin is unreachable). Push it first:"
    echo "         git push origin $TAG"
  else
    echo "    ok   $TAG exists on origin"
  fi
fi

if ((problems)); then
  echo "==> refusing to build a release ($problems problem(s) above)"
  exit 1
fi

# ------------------------------------------------------------------------------ build + notarize
echo "==> make app (signed)"
SIGN_IDENTITY="$SIGN_IDENTITY" make app

echo "==> make notarize"
SIGN_IDENTITY="$SIGN_IDENTITY" NOTARY_PROFILE="$NOTARY_PROFILE" make notarize

# Read the version back out of the artifact instead of deriving it a second time, so the asset
# name and the app's own About box can never disagree.
APP="build/tkzmux.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$VERSION" != "${TAG#v}" ]]; then
  echo "==> stamped version '$VERSION' does not match tag '$TAG' — aborting"
  exit 1
fi

# ------------------------------------------------------------------------------------- artifacts
# Re-zip AFTER stapling: `make notarize` rewrote the bundle to embed the ticket, so the zip that
# was submitted for notarization is stale and would ship unstapled (= a Gatekeeper round trip to
# Apple on first launch, and a hard failure offline).
DIST_DIR="build/dist"
ZIP="$DIST_DIR/tkzmux-$VERSION-arm64.zip"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "==> ditto -c -k --keepParent $APP $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> shasum -a 256"
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )
SHA256="$(awk '{print $1}' < "$ZIP.sha256")"

# --------------------------------------------------------------------------------- release notes
# `git describe --tags --abbrev=0 HEAD^` fails on the very first release — there is no earlier
# tag, and if HEAD *is* the root commit there is no HEAD^ either — so `|| true` and fall back to
# the whole history. `git rev-list --max-parents=0 HEAD` names the root commit; `<root>..HEAD`
# would exclude the root commit itself, and for a first release we want it, so the fallback range
# is plain `HEAD` (root-inclusive by definition).
PREV_TAG="$(git describe --tags --abbrev=0 --match 'v*' "$TAG^" 2>/dev/null || true)"
LOG_RANGE="HEAD"
if [[ -n "$PREV_TAG" ]]; then LOG_RANGE="$PREV_TAG..HEAD"; fi
NOTES="$DIST_DIR/notes.md"
{
  if [[ -n "$PREV_TAG" ]]; then
    echo "### Changes since $PREV_TAG"
  else
    echo "### Changes (first release: everything since $(git rev-list --max-parents=0 HEAD | tail -1 | cut -c1-7))"
  fi
  echo
  git log --oneline --no-decorate "$LOG_RANGE"
  echo
  echo "### Install"
  echo
  echo '```sh'
  # `brew trust` is not optional on Homebrew 6: a third-party tap's cask is refused outright
  # ("Refusing to load cask … from untrusted tap") until the tap is trusted, and the refusal
  # surfaces as "Cannot tap …: invalid syntax in tap!", which reads like a broken cask.
  echo "brew tap tkz0/tap"
  echo "brew trust tkz0/tap          # Homebrew 6 refuses untrusted third-party casks"
  echo "brew install --cask tkzmux"
  echo '```'
  echo
  echo "SHA-256 \`$(basename "$ZIP")\`: \`$SHA256\`"
} > "$NOTES"

echo
echo "    version   $VERSION"
echo "    tag       $TAG"
echo "    zip       $ZIP"
echo "    sha256    $SHA256"
echo "    url       https://github.com/$REPO_SLUG/releases/download/$TAG/$(basename "$ZIP")"
echo

# --------------------------------------------------------------------------------- gh release
# --verify-tag is gh's own "the tag must already exist on the remote" check, and it is the
# authoritative one: without it gh silently creates $TAG on the default branch head. The
# ls-remote preflight above is the early warning; this is the interlock at the point of use.
GH_ARGS=(release create "$TAG" "$ZIP" "$ZIP.sha256"
         --repo "$REPO_SLUG"
         --verify-tag
         --title "tkzmux $VERSION"
         --notes-file "$NOTES")
if [[ -n "$DIST_DRAFT" ]]; then GH_ARGS+=(--draft); fi

echo "==> gh ${GH_ARGS[*]}"
gh "${GH_ARGS[@]}"

# ------------------------------------------------------------------------------------ cask bump
# Owned by another script (TKZ-40); `make dist` only invokes it when the tap checkout is on hand.
if [[ -n "$TAP_DIR" && -x scripts/bump-cask.sh ]]; then
  echo "==> scripts/bump-cask.sh $VERSION $SHA256"
  TAP_DIR="$TAP_DIR" scripts/bump-cask.sh "$VERSION" "$SHA256"
elif [[ -n "$TAP_DIR" ]]; then
  echo "==> TAP_DIR set but scripts/bump-cask.sh is missing or not executable — skipping cask bump"
fi

echo "==> released $TAG"
