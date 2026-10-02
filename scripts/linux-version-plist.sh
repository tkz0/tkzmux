#!/usr/bin/env bash
# Write the Linux version.plist: the three values make-app.sh stamps into the Mac's Info.plist,
# as an XML property list that `AppVersion.current` reads from <prefix>/lib/tkzmux/version.plist
# (WOR-303 S4; WOR-324 installs it). No PlistBuddy or plutil: plain text, so it runs on Linux.
#
#   scripts/linux-version-plist.sh [OUT]   write OUT (directories created), or stdout without one
#   VERSION                                override the derived marketing version verbatim
#
# The values come from scripts/lib/version.sh, so the Mac and Linux stamps cannot drift:
#
#   CFBundleShortVersionString  from `git describe --tags --match 'v*' --dirty`
#   CFBundleVersion             `git rev-list --count HEAD`
#   TkzGhosttyCommit            vendor/ghostty-vt/COMMIT, which must be a full 40-char sha
set -euo pipefail

out="${1:-}"
if [[ -n "$out" && "$out" != /* ]]; then out="$PWD/$out"; fi
cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/version.sh
source scripts/lib/version.sh
version_stamp

die() { echo "linux-version-plist.sh: $*" >&2; exit 1; }
[[ "$GHOSTTY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "vendor/ghostty-vt/COMMIT is not a 40-char sha: '$GHOSTTY_COMMIT'"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "build number is not a number: '$BUILD_NUMBER'"

# Only a VERSION override can carry markup characters, but escape every value anyway. sed, not
# ${s//&/&amp;}: bash 5.2's patsub_replacement turns an unquoted `&` in the replacement into the
# match.
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleShortVersionString</key>
	<string>$(xml_escape "$VERSION")</string>
	<key>CFBundleVersion</key>
	<string>$(xml_escape "$BUILD_NUMBER")</string>
	<key>TkzGhosttyCommit</key>
	<string>$(xml_escape "$GHOSTTY_COMMIT")</string>
</dict>
</plist>
EOF
}

if [[ -z "$out" ]]; then
  plist
  exit 0
fi

# Write beside the target and rename, so a reader never sees half a file.
mkdir -p "$(dirname "$out")"
tmp="$(mktemp "$out.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
plist > "$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$out"
trap - EXIT
echo "==> $out: version $VERSION (build $BUILD_NUMBER, ghostty-vt ${GHOSTTY_COMMIT:0:7})" >&2
