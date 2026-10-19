#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_root/native/Omnibar/Omnibar Extension"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/omnibar-palette-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT

xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -framework Foundation -I "$source_dir" \
  "$source_dir/OmnibarURLResolver.m" "$source_dir/OmnibarPaletteModel.m" \
  "$project_root/tests/PaletteModelTests.m" -o "$test_directory/PaletteModelTests"
"$test_directory/PaletteModelTests"
