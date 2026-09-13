#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/omnibar-keyboard-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT

xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -framework Foundation -framework AppKit -framework SafariServices -framework Security \
  -I "$project_root/native/Omnibar/Omnibar Extension" \
  "$project_root/native/Omnibar/Omnibar Extension/OmnibarURLResolver.m" \
  "$project_root/native/Omnibar/Omnibar Extension/AddressPopoverController.m" \
  "$project_root/native/Omnibar/Omnibar Extension/OmnibarSearchSettings.m" \
  "$project_root/native/Omnibar/Omnibar Extension/SearchSettingsController.m" \
  "$project_root/tests/KeyboardTests.m" \
  -o "$test_directory/KeyboardTests"
"$test_directory/KeyboardTests"
