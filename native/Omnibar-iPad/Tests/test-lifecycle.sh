#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/../../.." && pwd)"
source_dir="$project_root/native/Omnibar/Omnibar Extension"
mobile_dir="$project_root/native/Omnibar-iPad"
output_dir="${LIFECYCLE_TEST_OUTPUT_DIR:-$project_root/build/tests/ipad-lifecycle}"
app_path="$output_dir/OmnibarLifecycleTests.app"
bundle_identifier=com.dkaluta.omnibar.tests.lifecycle
simulator="${SIMULATOR_UDID:-booted}"
architecture="${SIMULATOR_ARCH:-$(uname -m)}"
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p "$app_path" "$output_dir/objects" "$output_dir/ModuleCache" "$output_dir/TemporaryItems"

compile_options=(-target "$architecture-apple-ios17.0-simulator" -isysroot "$sdk_path"
  -fobjc-arc -fmodules -fmodules-cache-path="$output_dir/ModuleCache"
  -Wall -Wextra -Werror -Wno-unused-parameter
  -I "$source_dir" -I "$mobile_dir/Shared" -I "$mobile_dir/Omnibar-iPad")

TMPDIR="$output_dir/TemporaryItems" xcrun --sdk iphonesimulator clang "${compile_options[@]}" \
  -DOmnibarMobileSearchSettings=OMLifecycleTestSettings \
  -c "$mobile_dir/Omnibar-iPad/SceneDelegate.m" -o "$output_dir/objects/SceneDelegate.o"

TMPDIR="$output_dir/TemporaryItems" xcrun --sdk iphonesimulator clang "${compile_options[@]}" \
  -framework UIKit -framework Foundation -framework Security \
  "$mobile_dir/Omnibar-iPad/AppDelegate.m" "$mobile_dir/Tests/LifecycleTests.m" \
  "$mobile_dir/Shared/OmnibarMobileSettings.m" \
  "$source_dir/OmnibarSearchSettings.m" "$source_dir/OmnibarURLResolver.m" \
  "$output_dir/objects/SceneDelegate.o" -o "$app_path/OmnibarLifecycleTests"

cat > "$app_path/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_identifier</string>
<key>CFBundleExecutable</key><string>OmnibarLifecycleTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>OmnibarLifecycleTests</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UIDeviceFamily</key><array><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict>
<key>UIApplicationSupportsMultipleScenes</key><false/>
<key>UISceneConfigurations</key><dict>
<key>UIWindowSceneSessionRoleApplication</key><array><dict>
<key>UISceneConfigurationName</key><string>Lifecycle Tests</string>
<key>UISceneClassName</key><string>UIWindowScene</string>
<key>UISceneDelegateClassName</key><string>OMLifecycleSceneDelegate</string>
</dict></array></dict></dict>
</dict></plist>
PLIST
codesign --force --sign - "$app_path"

if [[ "${1:-}" == --build-only ]]; then
  printf 'Built isolated UIKit lifecycle harness: %s\n' "$app_path"
  exit 0
fi
if [[ $# -gt 0 ]]; then
  printf 'Usage: %s [--build-only]\nSet SIMULATOR_UDID to an already booted iPad simulator.\n' "$0" >&2
  exit 2
fi

xcrun simctl install "$simulator" "$app_path"
xcrun simctl launch --terminate-running-process --console "$simulator" "$bundle_identifier" 2>&1 | tee "$output_dir/results.log"
rg -q '^[0-9]+ iPad scene lifecycle checks passed$' "$output_dir/results.log"
