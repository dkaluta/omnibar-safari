#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || "$1" != --run ]]; then
    printf 'Opt-in integration test: %s --run\n' "$0" >&2
    printf 'Uses an Apple Development signed, sandboxed helper and one temporary TEST_ONLY Keychain item.\n' >&2
    exit 2
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_root/native/Omnibar/Omnibar Extension"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/omnibar-keychain-integration.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
test_bundle="$test_dir/Omnibar Keychain Tests.app"
signing_identity="${KEYCHAIN_TEST_SIGNING_IDENTITY:-Apple Development}"
expected_team="${DEVELOPMENT_TEAM:-$(plutil -extract objects.4225A17B305694F600A739B8.buildSettings.DEVELOPMENT_TEAM raw -o - "$project_root/native/Omnibar/Omnibar.xcodeproj/project.pbxproj")}"
mkdir -p "$test_bundle/Contents/MacOS"

cat > "$test_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.dkaluta.omnibar.tests.keychain</string>
<key>CFBundleExecutable</key><string>KeychainIntegrationTests</string>
<key>CFBundleName</key><string>Omnibar Keychain Tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

cat > "$test_dir/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST

xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -mmacosx-version-min=13.0 \
    -framework Foundation -framework Security -I "$source_dir" \
    "$source_dir/OmnibarURLResolver.m" "$source_dir/OmnibarSearchSettings.m" \
    "$project_root/tests/KeychainIntegrationTests.m" \
    -o "$test_bundle/Contents/MacOS/KeychainIntegrationTests"

codesign --force --options runtime --timestamp=none --sign "$signing_identity" \
    --entitlements "$test_dir/entitlements.plist" "$test_bundle"
codesign --verify --deep --strict --test-requirement='=anchor apple generic' "$test_bundle"
signature="$(codesign --display --verbose=2 "$test_bundle" 2>&1)"
actual_team="$(awk -F= '$1 == "TeamIdentifier" { print $2 }' <<< "$signature")"
leaf_authority="$(awk -F= '$1 == "Authority" { print $2; exit }' <<< "$signature")"
if [[ -z "$expected_team" || "$actual_team" != "$expected_team" || "$leaf_authority" != 'Apple Development: '* ]]; then
    printf 'Test helper must use the project’s Apple Development signing team.\n' >&2
    exit 1
fi

printf 'Running sandboxed real Keychain integration checks for team %s.\n' "$actual_team"
"$test_bundle/Contents/MacOS/KeychainIntegrationTests" --run
