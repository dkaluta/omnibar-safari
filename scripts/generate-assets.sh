#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
asset_work="$(mktemp -d "${TMPDIR:-/tmp}/omnibar-assets.XXXXXX")"
trap 'rm -rf "$asset_work"' EXIT

xcrun clang "$project_root/scripts/generate-icons.m" -fobjc-arc -framework AppKit -o "$asset_work/generate-icons"
"$asset_work/generate-icons" "$asset_work"

icon_directory="$project_root/native/Omnibar/Omnibar/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 128 256 512; do
    cp "$asset_work/icon-$size.png" "$icon_directory/mac-icon-$size@1x.png"
    cp "$asset_work/icon-$((size * 2)).png" "$icon_directory/mac-icon-$size@2x.png"
done
cp "$asset_work/Toolbar.pdf" "$project_root/native/Omnibar/Omnibar Extension/Toolbar.pdf"
printf 'Generated native app and toolbar icons.\n'
