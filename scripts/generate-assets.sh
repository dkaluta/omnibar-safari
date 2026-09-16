#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
asset_work="$(mktemp -d "${TMPDIR:-/tmp}/omnibar-assets.XXXXXX")"
trap 'rm -rf "$asset_work"' EXIT

xcrun clang "$project_root/scripts/generate-toolbar-icon.m" -fobjc-arc -framework AppKit -o "$asset_work/generate-toolbar-icon"
"$asset_work/generate-toolbar-icon" "$asset_work"

cp "$asset_work/Toolbar.pdf" "$project_root/native/Omnibar/Omnibar Extension/Toolbar.pdf"
printf 'Generated Safari toolbar icon. Edit the app icon in native/Omnibar/Omnibar/AppIcon.icon using Icon Composer.\n'
