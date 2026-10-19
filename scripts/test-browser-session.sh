#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_root/native/Omnibar/Omnibar Extension"
output_dir="$project_root/build/tests"
mkdir -p "$output_dir"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -framework Foundation -framework SafariServices -I "$source_dir" \
  "$source_dir/OmnibarBrowserSession.m" "$project_root/tests/BrowserSessionTests.m" \
  -o "$output_dir/BrowserSessionTests"
"$output_dir/BrowserSessionTests"
