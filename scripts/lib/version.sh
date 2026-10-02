# shellcheck shell=bash
# The version stamp, shared by scripts/make-app.sh (the macOS Info.plist) and
# scripts/linux-version-plist.sh (the Linux version.plist, WOR-303 S4). Sourced, never executed.
#
# The caller runs from the repo root: `git` and vendor/ghostty-vt/COMMIT are read relative to it.
#
#   VERSION   override the derived marketing version verbatim (see version_from_describe).
#
# Portable between macOS (bash 3.2, BSD userland) and Linux (GNU userland).

# ---------------------------------------------------------------------------- version
#
# The single source of truth for the marketing version is `git describe --tags --match 'v*'
# --dirty`. It is parsed RIGHT-TO-LEFT, because a prerelease tag (`v1.0.0-rc1`) contains dashes
# of its own and splitting on the first `-` would mangle it. The complete rule set:
#
#   describe output            ->  CFBundleShortVersionString
#   ------------------------------------------------------------------------------------------
#   (empty: no reachable tag)  ->  0.0.0-dev+<sha>          e.g. 0.0.0-dev+72e78a1
#   (empty, dirty tree)        ->  0.0.0-dev+<sha>.dirty
#   v1.2.3                     ->  1.2.3                    (clean, exactly on the tag)
#   v1.2.3-dirty               ->  1.2.3-dev.0+<sha>.dirty  (on the tag, tree modified)
#   v1.2.3-4-gabc1234          ->  1.2.3-dev.4+abc1234      (4 commits past the tag)
#   v1.2.3-4-gabc1234-dirty    ->  1.2.3-dev.4+abc1234.dirty
#   v1.0.0-rc1-2-gdeadbee      ->  1.0.0-rc1-dev.2+deadbee  (prerelease tags survive intact)
#
# In words: strip a trailing `-dirty`; strip a trailing `-<N>-g<hex>` to get the commit distance
# N and the abbreviated sha; strip the leading `v` from what is left to get the tag. A clean
# exact tag is released verbatim; everything else is `<tag>-dev.<N>+<sha>[.dirty]`, where a dirty
# exact tag uses N=0 and `git rev-parse --short HEAD` for the sha (describe gives no sha there).
# Only the exact-clean-tag form is a real release; every other form carries `-dev.` and is a
# semver prerelease, so it sorts below the release it is built on.
#
# The Swift mirror is `AppVersion.marketingVersion(fromGitDescribe:)` (Sources/TkzCore), and
# Tests/TkzCoreTests/AppVersionTests.swift runs this function against the same table.
#
# `git describe` EXITS NON-ZERO when no tag matches, hence the `|| true` in version_stamp.
version_from_describe() {
  local raw="$1" dirty=0 tag n sha out
  if [[ "$raw" == *-dirty ]]; then dirty=1; raw="${raw%-dirty}"; fi

  if [[ -z "$raw" ]]; then
    # No reachable v* tag: describe failed, so it could not report dirtiness either. Ask git
    # directly, matching describe's own definition (tracked files only, untracked ignored).
    if ! git diff --quiet HEAD -- 2>/dev/null; then dirty=1; fi
    out="0.0.0-dev+$(git rev-parse --short HEAD)"
    if ((dirty)); then out="$out.dirty"; fi
    printf '%s\n' "$out"
    return
  fi

  n=""; sha=""
  if [[ "$raw" =~ ^(.+)-([0-9]+)-g([0-9a-f]+)$ ]]; then
    tag="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"; sha="${BASH_REMATCH[3]}"
  else
    tag="$raw"
  fi
  tag="${tag#v}"

  if [[ -z "$n" ]]; then
    if ((dirty)); then n=0; sha="$(git rev-parse --short HEAD)"; else printf '%s\n' "$tag"; return; fi
  fi
  out="$tag-dev.$n+$sha"
  if ((dirty)); then out="$out.dirty"; fi
  printf '%s\n' "$out"
}

# Sets the three stamped values, in the caller's shell:
#
#   VERSION         CFBundleShortVersionString: $VERSION if set and non-empty, else derived above
#   BUILD_NUMBER    CFBundleVersion
#   GHOSTTY_COMMIT  TkzGhosttyCommit
# shellcheck disable=SC2034  # the globals are this function's output
version_stamp() {
  VERSION_RAW="$(git describe --tags --match 'v*' --dirty 2>/dev/null || true)"
  VERSION="${VERSION:-$(version_from_describe "$VERSION_RAW")}"
  # CFBundleVersion must increase monotonically for every build the user might see. The commit
  # count does exactly that and needs no state outside the repo.
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
  # Which libghostty-vt this binary was linked against, surfaced in the app's About box / bug
  # reports. `tr -d` because the file ends in a newline.
  GHOSTTY_COMMIT="$(tr -d '[:space:]' < vendor/ghostty-vt/COMMIT)"
}
