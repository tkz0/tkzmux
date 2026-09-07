#!/usr/bin/env bash
# Assemble build/tkzmux.app from a release SwiftPM build. No Xcode project involved.
#   SIGN_IDENTITY   codesign identity; default "-" (ad-hoc). Developer ID later = one variable.
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

# SwiftPM resource bundles (Bundle.module) live next to the executable inside the bundle.
shopt -s nullglob
bundles=("$BIN"/*.bundle)
if ((${#bundles[@]})); then
  echo "==> copying ${#bundles[@]} resource bundle(s)"
  cp -R "${bundles[@]}" "$CONTENTS/Resources/"
fi

# terminfo (xterm-ghostty) is produced by `make vendor` (M1.1).
if [[ -d Resources/terminfo ]]; then
  echo "==> copying terminfo"
  cp -R Resources/terminfo "$CONTENTS/Resources/terminfo"
fi

# Metal shaders → default.metallib (M1.5 adds Resources/Shaders/Terminal.metal).
shaders=(Resources/Shaders/*.metal)
if ((${#shaders[@]})); then
  echo "==> compiling ${#shaders[@]} Metal shader(s)"
  rm -rf build/air && mkdir -p build/air
  for f in "${shaders[@]}"; do
    name="$(basename "${f%.metal}")"
    xcrun -sdk macosx metal -c "$f" -I Sources/TkzShaderTypes/include -o "build/air/$name.air"
  done
  xcrun -sdk macosx metallib build/air/*.air -o "$CONTENTS/Resources/default.metallib"
fi
shopt -u nullglob

echo "==> codesign --sign '$SIGN_IDENTITY'"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)=' || true
echo "==> $APP ready (open $APP)"
