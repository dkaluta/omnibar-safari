#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../../.." && pwd)"
source_dir="$project_root/native/Omnibar/Omnibar Extension"
mobile_dir="$project_root/native/Omnibar-iPad"
output_dir="$project_root/build/tests"
mkdir -p "$output_dir"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -framework Foundation -framework Security -framework SafariServices \
  -I "$source_dir" -I "$mobile_dir/Shared" -I "$mobile_dir/Omnibar-iPad Extension" -I "$project_root/tests" \
  "$source_dir/OmnibarURLResolver.m" "$source_dir/OmnibarSearchSettings.m" \
  "$mobile_dir/Shared/OmnibarMobileSettings.m" "$mobile_dir/Omnibar-iPad Extension/SafariWebExtensionHandler.m" \
  "$mobile_dir/Tests/MobileBridgeTests.m" -o "$output_dir/MobileBridgeTests"
"$output_dir/MobileBridgeTests"
