#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
node "$project_root/scripts/bundle-webextension.mjs" --check
source_dir="$project_root/native/Omnibar/Omnibar Extension"
commands_dir="$project_root/native/Omnibar/Omnibar Commands"
output_dir="$project_root/build/tests"
mkdir -p "$output_dir"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -framework Foundation -framework AppKit -framework Security -framework SafariServices \
  -I "$source_dir" -I "$commands_dir" \
  "$source_dir/OmnibarURLResolver.m" "$source_dir/OmnibarSearchSettings.m" \
  "$commands_dir/SafariWebExtensionHandler.m" "$project_root/tests/WebExtensionHandlerTests.m" \
  -o "$output_dir/WebExtensionHandlerTests"
"$output_dir/WebExtensionHandlerTests"
node --test "$project_root"/tests/webextension/*.test.mjs
