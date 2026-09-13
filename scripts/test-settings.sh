#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_root/native/Omnibar/Omnibar Extension"
output_dir="$project_root/build/tests"
mkdir -p "$output_dir"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -framework Foundation -framework Security -I "$source_dir" \
  "$source_dir/OmnibarURLResolver.m" "$source_dir/OmnibarSearchSettings.m" \
  "$project_root/tests/SearchSettingsTests.m" -o "$output_dir/SearchSettingsTests"
"$output_dir/SearchSettingsTests"
