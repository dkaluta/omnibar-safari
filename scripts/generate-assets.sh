#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
asset_work="$(mktemp -d "${TMPDIR:-/tmp}/omnibar-assets.XXXXXX")"
trap 'rm -rf "$asset_work"' EXIT

xcrun clang "$project_root/scripts/generate-toolbar-icon.m" -fobjc-arc -framework AppKit -o "$asset_work/generate-toolbar-icon"
"$asset_work/generate-toolbar-icon" "$asset_work"

cp "$asset_work/Toolbar.pdf" "$project_root/native/Omnibar/Omnibar Extension/Toolbar.pdf"
icon_tool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$icon_tool" ]]; then
  printf 'Icon Composer is required to export PaletteIcon.icon. Select a current Xcode installation.\n' >&2
  exit 1
fi
for size in 48 128; do
  "$icon_tool" "$project_root/native/Omnibar/Omnibar Commands/PaletteIcon.icon" \
    --export-image --output-file "$asset_work/icon$size.png" \
    --platform macOS --rendition Default --width "$size" --height "$size" --scale 1
  cp "$asset_work/icon$size.png" "$project_root/native/Omnibar/Omnibar Commands/Resources/icon$size.png"
done
printf 'Generated native Safari toolbar and palette settings icons. Edit AppIcon.icon or PaletteIcon.icon using Icon Composer.\n'
