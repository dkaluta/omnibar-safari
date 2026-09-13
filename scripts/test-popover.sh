#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$project_root/build/tests"
source_dir="$project_root/native/Omnibar/Omnibar Extension"
test_bundle="$output_dir/Omnibar Preview.app"
mkdir -p "$test_bundle/Contents/MacOS"
cat > "$test_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.dkaluta.omnibar.preview</string>
<key>CFBundleExecutable</key><string>PopoverTests</string>
<key>CFBundleName</key><string>Omnibar Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -fobjc-arc -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=13.0 \
  -framework AppKit -framework SafariServices -framework Security -I "$source_dir" \
  "$source_dir/OmnibarURLResolver.m" "$source_dir/AddressPopoverController.m" \
  "$source_dir/OmnibarSearchSettings.m" "$source_dir/SearchSettingsController.m" \
  "$project_root/tests/PopoverTests.m" -o "$test_bundle/Contents/MacOS/PopoverTests"
"$test_bundle/Contents/MacOS/PopoverTests" "$output_dir" "$@"
