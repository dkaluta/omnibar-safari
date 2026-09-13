#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/omnibar-tests.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT

xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
  -I "$project_root/native/Omnibar/Omnibar Extension" \
  "$project_root/native/Omnibar/Omnibar Extension/OmnibarURLResolver.m" \
  "$project_root/tests/URLResolverTests.m" \
  -o "$test_directory/URLResolverTests"
"$test_directory/URLResolverTests"
