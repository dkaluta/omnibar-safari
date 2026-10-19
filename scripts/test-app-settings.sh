#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_root/native/Omnibar/Omnibar Extension"
app_dir="$project_root/native/Omnibar/Omnibar"
test_bundle="$project_root/build/tests/Omnibar Settings Tests.app"
mkdir -p "$test_bundle/Contents/MacOS"
cat > "$test_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.dkaluta.omnibar.settings-tests</string>
<key>CFBundleExecutable</key><string>AppSettingsTests</string>
<key>CFBundleName</key><string>Omnibar Settings Tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -mmacosx-version-min=13.0 \
  -framework AppKit -framework SafariServices -framework Security -I "$source_dir" -I "$app_dir" \
  "$source_dir/OmnibarURLResolver.m" "$source_dir/OmnibarSearchSettings.m" "$source_dir/SearchSettingsController.m" \
  "$app_dir/ViewController.m" "$app_dir/AppDelegate.m" "$project_root/tests/AppSettingsTests.m" \
  -o "$test_bundle/Contents/MacOS/AppSettingsTests"
"$test_bundle/Contents/MacOS/AppSettingsTests"
python3 "$project_root/tests/SettingsRouteDiagnosticsTests.py"
python3 "$project_root/tests/SettingsRouteSandboxTests.py"
