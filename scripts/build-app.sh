#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in release|debug) ;; *) echo 'Usage: scripts/build-app.sh [release|debug]' >&2; exit 2;; esac
swift build -c "$configuration" --product MyRedirector
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_path="$PWD/dist/My Redirector.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/MyRedirector" "$app_path/Contents/MacOS/MyRedirector"
cp resources/Info.plist "$app_path/Contents/Info.plist"
cp resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp Vendor/CSamplerate/COPYING "$app_path/Contents/Resources/libsamplerate-LICENSE.txt"
# Set CODESIGN_IDENTITY for a persistent local Developer ID / signing certificate.
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier jp.seijiro.my-redirector "$app_path"
codesign --verify --strict "$app_path"
printf '%s\n' "$app_path"
