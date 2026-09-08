#!/usr/bin/env bash
# Assemble build/tkzmux.app from a release SwiftPM build. No Xcode project involved.
#   SIGN_IDENTITY   codesign identity; default "-" (ad-hoc). Developer ID later = one variable.
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

echo "==> swift build -c release"
swift build -c release --product tkzmux
BIN="$(swift build -c release --product tkzmux --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN/tkzmux" "$CONTENTS/MacOS/tkzmux"
cp Resources/Info.plist "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

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

echo "==> codesign --sign '$SIGN_IDENTITY'"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)=' || true

# Self-check. Every one of these has silently regressed at least once during M1, and a broken
# .app is invisible until someone double-clicks it, so `make app` asserts its own output.
echo "==> verifying"
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "    ok   $1"; else echo "    FAIL $1"; fail=1; fi; }
check "codesign --verify --deep --strict"   "codesign --verify --deep --strict '$APP'"
check "Contents/MacOS/tkzmux is executable" "[[ -x '$CONTENTS/MacOS/tkzmux' ]]"
check "ATSApplicationFontsPath = Fonts" \
  "[[ \"\$(/usr/libexec/PlistBuddy -c 'Print :ATSApplicationFontsPath' '$CONTENTS/Info.plist')\" == Fonts ]]"
check "4 dereferenced .ttf + OFL.txt in Resources/Fonts" \
  "[[ \$(ls '$CONTENTS/Resources/Fonts'/*.ttf 2>/dev/null | wc -l) -eq 4 && -s '$CONTENTS/Resources/Fonts/OFL.txt' ]]"
check "terminfo/78/xterm-ghostty resolves" \
  "TERMINFO='$CONTENTS/Resources/terminfo' infocmp xterm-ghostty"
check "default.metallib present"           "[[ -s '$CONTENTS/Resources/default.metallib' ]]"
check "no unsealed contents at app root"   "[[ \$(ls -A '$APP' | grep -cv '^Contents\$') -eq 0 ]]"
if ((fail)); then echo "==> $APP is NOT usable (see FAIL above)"; exit 1; fi

echo "==> $APP ready (open $APP)"
