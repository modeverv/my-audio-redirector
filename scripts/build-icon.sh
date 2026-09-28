#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Package the generated artwork without changing its transparent silhouette.
icon_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/my-redirector-icon.XXXXXX")"
trap 'rm -rf "$icon_work_dir"' EXIT
icon_set="$icon_work_dir/AppIcon.iconset"
mkdir -p "$icon_set"

for icon_size in 16 32 128 256 512; do
    sips -z "$icon_size" "$icon_size" resources/AppIcon.png \
        --out "$icon_set/icon_${icon_size}x${icon_size}.png" >/dev/null
    icon_retina_size=$((icon_size * 2))
    sips -z "$icon_retina_size" "$icon_retina_size" resources/AppIcon.png \
        --out "$icon_set/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_set" -o resources/AppIcon.icns
printf '%s\n' "$PWD/resources/AppIcon.icns"
