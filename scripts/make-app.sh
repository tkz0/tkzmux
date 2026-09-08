#!/usr/bin/env bash
# Assemble build/tkzmux.app from a release SwiftPM build. No Xcode project involved.
#   SIGN_IDENTITY   codesign identity; default "-" (ad-hoc). Developer ID later = one variable.
#                   Anything other than "-" also turns on the hardened runtime and a secure
#                   timestamp (`--options runtime --timestamp`), which notarization requires.
#                   `--timestamp` talks to Apple's timestamp server, so a signed build needs
#                   network; the ad-hoc default does not.
#   VERSION         override the derived marketing version verbatim (see version_from_describe).
#
# The script verifies its own output (see "==> verifying" at the end), but it cannot prove the
# app *runs* without a GUI session. The launch smoke test — which is the only way to catch a
# resource that resolves from the source tree instead of from inside the .app — is:
#
#   B=.build/arm64-apple-macosx/release
#   for b in "$B"/*.bundle; do mv "$b" "$b.hidden"; done        # hide SwiftPM's absolute fallback
#   TKZMUX_DEV_SNAPSHOT_DIR=$(mktemp -d) TKZMUX_DEV_AUTOQUIT_MS=2500 build/tkzmux.app/Contents/MacOS/tkzmux
#   for b in "$B"/*.bundle.hidden; do mv "$b" "${b%.hidden}"; done
#
# A `TKZMUX_DEV sessions=1 …` line means the bundle is self-contained; a
# "could not load resource bundle" fatal error means it is not.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/tkzmux.app"
CONTENTS="$APP/Contents"

# ---------------------------------------------------------------------------- version (TKZ-37)
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
# `git describe` EXITS NON-ZERO when no tag matches, hence the `|| true`.
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

VERSION_RAW="$(git describe --tags --match 'v*' --dirty 2>/dev/null || true)"
VERSION="${VERSION:-$(version_from_describe "$VERSION_RAW")}"
# CFBundleVersion must increase monotonically for every build the user might see. The commit
# count does exactly that and needs no state outside the repo.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
# Which libghostty-vt this binary was linked against, surfaced in the app's About box / bug
# reports. `tr -d` because the file ends in a newline.
GHOSTTY_COMMIT="$(tr -d '[:space:]' < vendor/ghostty-vt/COMMIT)"
echo "==> version $VERSION (build $BUILD_NUMBER, ghostty-vt ${GHOSTTY_COMMIT:0:7})"

echo "==> swift build -c release"
swift build -c release --product tkzmux
swift build -c release --product tkzmux-hook
BIN="$(swift build -c release --product tkzmux --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN/tkzmux" "$CONTENTS/MacOS/tkzmux"
# tkzmux-hook (TKZ-23): ShimInstaller.standardHookBinary() looks for it next to `tkzmux` in both
# the .app and `swift run`, and ShimInstaller copies it on into ~/Library/Application
# Support/tkzmux/bin at install time -- this is only the source copy.
cp "$BIN/tkzmux-hook" "$CONTENTS/MacOS/tkzmux-hook"
cp Resources/Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Stamp the COPY only (TKZ-37). Resources/Info.plist keeps its committed placeholders, so a
# build never dirties the working tree — which matters because `make dist` refuses a dirty tree
# and because the version itself is derived from the tree's git state.
# This has to happen BEFORE codesign: Info.plist is part of the signed seal.
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $VERSION" \
  -c "Set :CFBundleVersion $BUILD_NUMBER" \
  -c "Add :TkzGhosttyCommit string $GHOSTTY_COMMIT" \
  "$CONTENTS/Info.plist" >/dev/null

# SwiftPM resource bundles (`Bundle.module`) go into Contents/Resources.
#
# NOTE (M1.9 / TKZ-15, verified): SwiftPM's generated `resource_bundle_accessor.swift` looks for
# `Bundle.main.bundleURL/<name>.bundle`, i.e. the *root* of the .app — and `codesign --strict`
# rejects anything but `Contents` at a bundle root ("unsealed contents present in the bundle
# root"; also true for a symlink, and for a bundle carrying its own Info.plist). Those two rules
# are irreconcilable, so the app code must not rely on the generated `Bundle.module` accessor:
# each module resolves its bundle through `Bundle.main.resourceURL` first and falls back to
# `Bundle.module` only outside an .app. `cp -RL` because a `.copy(...)`d resource that is a
# symlink in the source tree is reproduced verbatim into the .bundle.
shopt -s nullglob
bundles=("$BIN"/*.bundle)
if ((${#bundles[@]})); then
  echo "==> copying ${#bundles[@]} resource bundle(s)"
  cp -RL "${bundles[@]}" "$CONTENTS/Resources/"
fi

# Bundled JetBrains Mono (M1.4). ATSApplicationFontsPath = Fonts in Info.plist makes AppKit
# register these process-scoped at launch, without installing into the user's font library.
if [[ -d Resources/Fonts ]]; then
  echo "==> copying fonts"
  cp -RL Resources/Fonts "$CONTENTS/Resources/Fonts"
fi

# terminfo (xterm-ghostty) is produced by `make vendor` (M1.1).
if [[ -d Resources/terminfo ]]; then
  echo "==> copying terminfo"
  cp -RL Resources/terminfo "$CONTENTS/Resources/terminfo"
fi

# Metal shaders → default.metallib (M1.5 adds Resources/Shaders/Terminal.metal).
shaders=(Resources/Shaders/*.metal)
if ((${#shaders[@]})); then
  echo "==> compiling ${#shaders[@]} Metal shader(s)"
  rm -rf build/air && mkdir -p build/air
  for f in "${shaders[@]}"; do
    name="$(basename "${f%.metal}")"
    # Xcode 26 needs the separately downloaded Metal Toolchain for this
    # (`xcodebuild -downloadComponent MetalToolchain`); without it the app still runs, via
    # TerminalRenderer's device.makeLibrary(source:) fallback, but slower to start.
    xcrun -sdk macosx metal -c "$f" -I Sources/TkzShaderTypes/include -o "build/air/$name.air"
  done
  xcrun -sdk macosx metallib build/air/*.air -o "$CONTENTS/Resources/default.metallib"
  rm -rf build/air
fi
shopt -u nullglob

# Signing (TKZ-38). Two rules that are easy to get wrong:
#
# 1. INSIDE-OUT, never `--deep`. Contents/MacOS/tkzmux-hook is a second Mach-O inside the
#    bundle. `codesign --verify --deep --strict` passes on an unsigned helper there because it
#    is sealed as a plain resource — but the notary service *does* inspect every Mach-O it
#    finds and rejects an unsigned one. So each nested executable is signed first, with its own
#    `--identifier`, and the bundle is signed last (which re-seals over the signed helper).
#    `--deep` signing is deprecated by Apple and would give the helper the app's identifier.
# 2. `--options runtime --timestamp` ONLY for a real identity. `--timestamp` fails outright
#    against an ad-hoc ("-") signature, and the hardened runtime is meaningless without one.
#    The ad-hoc default path therefore stays exactly what it has always been.
SIGN_FLAGS=()
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_FLAGS=(--options runtime --timestamp)
fi

# `${a[@]+"${a[@]}"}` and not `"${a[@]}"`: expanding an empty array is an unbound-variable error
# under `set -u` in bash 3.2 (/bin/bash on macOS), and `"${a[@]:-}"` would pass an empty argument.
echo "==> codesign --sign '$SIGN_IDENTITY' ${SIGN_FLAGS[*]-}"
codesign --force --sign "$SIGN_IDENTITY" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} \
  --identifier se.tkz.tkzmux.hook "$CONTENTS/MacOS/tkzmux-hook"
codesign --force --sign "$SIGN_IDENTITY" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$APP"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)=' || true

# Self-check. Every one of these has silently regressed at least once during M1, and a broken
# .app is invisible until someone double-clicks it, so `make app` asserts its own output.
echo "==> verifying"
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "    ok   $1"; else echo "    FAIL $1"; fail=1; fi; }
check "codesign --verify --deep --strict"   "codesign --verify --deep --strict '$APP'"
# The bundle check above passes even when the helper is unsigned (it is sealed as a resource);
# notarization would not. Verify the nested Mach-O in its own right.
check "tkzmux-hook carries its own signature" \
  "codesign --verify --strict '$CONTENTS/MacOS/tkzmux-hook'"
check "Contents/MacOS/tkzmux is executable" "[[ -x '$CONTENTS/MacOS/tkzmux' ]]"
check "Contents/MacOS/tkzmux-hook is executable" "[[ -x '$CONTENTS/MacOS/tkzmux-hook' ]]"
check "CFBundleShortVersionString = $VERSION" \
  "[[ \"\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '$CONTENTS/Info.plist')\" == '$VERSION' ]]"
check "CFBundleVersion = $BUILD_NUMBER" \
  "[[ \"\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' '$CONTENTS/Info.plist')\" == '$BUILD_NUMBER' ]]"
check "TkzGhosttyCommit = ${GHOSTTY_COMMIT:0:7}…" \
  "[[ \"\$(/usr/libexec/PlistBuddy -c 'Print :TkzGhosttyCommit' '$CONTENTS/Info.plist')\" == '$GHOSTTY_COMMIT' ]]"
check "ATSApplicationFontsPath = Fonts" \
  "[[ \"\$(/usr/libexec/PlistBuddy -c 'Print :ATSApplicationFontsPath' '$CONTENTS/Info.plist')\" == Fonts ]]"
check "4 dereferenced .ttf + OFL.txt in Resources/Fonts" \
  "[[ \$(ls '$CONTENTS/Resources/Fonts'/*.ttf 2>/dev/null | wc -l) -eq 4 && -s '$CONTENTS/Resources/Fonts/OFL.txt' ]]"
check "terminfo/78/xterm-ghostty resolves" \
  "TERMINFO='$CONTENTS/Resources/terminfo' infocmp xterm-ghostty"
check "default.metallib present"           "[[ -s '$CONTENTS/Resources/default.metallib' ]]"
check "no unsealed contents at app root"   "[[ \$(ls -A '$APP' | grep -cv '^Contents\$') -eq 0 ]]"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  # Notarization rejects a bundle without the hardened runtime or without a secure timestamp,
  # and it checks the nested helper too. Cheaper to find out here than after a 5-minute upload.
  check "hardened runtime flag on tkzmux" \
    "codesign --display --verbose=2 '$APP' 2>&1 | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\\(.*runtime'"
  check "hardened runtime flag on tkzmux-hook" \
    "codesign --display --verbose=2 '$CONTENTS/MacOS/tkzmux-hook' 2>&1 | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\\(.*runtime'"
  check "secure timestamp on tkzmux" "codesign --display --verbose=4 '$APP' 2>&1 | grep -q '^Timestamp='"
fi
if ((fail)); then echo "==> $APP is NOT usable (see FAIL above)"; exit 1; fi

echo "==> $APP ready (open $APP)"
