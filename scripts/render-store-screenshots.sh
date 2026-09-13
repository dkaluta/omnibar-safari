#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_root/native/Omnibar/Omnibar Extension"
output_dir="$project_root/build/app-store/screenshots"
binary="$project_root/build/tests/StoreScreenshots"
mkdir -p "$output_dir/native" "$project_root/build/tests"
xcrun clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=13.0 \
  -framework AppKit -framework SafariServices -framework Security -I "$source_dir" -I "$project_root/tests" \
  "$source_dir/OmnibarURLResolver.m" "$source_dir/AddressPopoverController.m" \
  "$source_dir/OmnibarSearchSettings.m" "$source_dir/SearchSettingsController.m" \
  "$project_root/tests/StoreScreenshots.m" -o "$binary"
"$binary" "$output_dir"
