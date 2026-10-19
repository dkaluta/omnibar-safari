#!/bin/bash
set -euo pipefail

# This changes only the existing local development product. It does not open
# the app, install it in Applications, or restart Safari. No release upload.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
identifier=com.dkaluta.omnibar.development
derived_data="$project_root/build"
app_path="$derived_data/Build/Products/Release/Omnibar.app"
if [[ $# != 0 || ! -d "$app_path" ]]; then
    printf 'Build the standard local development app first, then run this script without arguments.\n' >&2
    exit 2
fi
if [[ "$(plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")" != "$identifier" ]]; then
    printf 'Refusing to replace a product that is not the isolated development app.\n' >&2
    exit 2
fi
codesign --verify --deep --strict --test-requirement '=anchor apple generic' "$app_path"
signature="$(codesign --display --verbose=2 "$app_path" 2>&1)"
authority="$(awk -F= '$1 == "Authority" { print $2; exit }' <<< "$signature")"
team="$(awk -F= '$1 == "TeamIdentifier" { print $2 }' <<< "$signature")"
if [[ "$authority" != 'Apple Development: '* || ! "$team" =~ ^[A-Z0-9]+$ ]]; then
    printf 'The source product must have an Apple Development signature and team.\n' >&2
    exit 2
fi

mkdir -p "$project_root/build/diagnostics"
diagnostics_root="$(mktemp -d "$project_root/build/diagnostics/startup.XXXXXX")"
# A ZIP avoids registering a duplicate .app with the same development identity.
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$diagnostics_root/pre-diagnostic-app.zip"
ditto "$project_root/native/Omnibar" "$diagnostics_root/Omnibar"
resources="$diagnostics_root/Omnibar/Omnibar Commands/Resources"
node "$project_root/scripts/bundle-webextension.mjs" --diagnostics --outdir "$resources"
printf 'Diagnostic project and backup: %s\n' "$diagnostics_root"

xcodebuild \
    -project "$diagnostics_root/Omnibar/Omnibar.xcodeproj" \
    -scheme Omnibar \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    'CODE_SIGN_IDENTITY=Apple Development' \
    'OTHER_CFLAGS=$(inherited) -DOMNIBAR_SETTINGS_ROUTE_DIAGNOSTICS=1' \
    "DEVELOPMENT_TEAM=$team" \
    "OMNIBAR_APP_BUNDLE_IDENTIFIER=$identifier" \
    build 2>&1 | tee "$diagnostics_root/build.log"

codesign --verify --deep --strict --test-requirement '=anchor apple generic' "$app_path"
if [[ "$(plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")" != "$identifier" ]]; then
    printf 'Diagnostic product identity mismatch.\n' >&2
    exit 1
fi
node "$project_root/scripts/bundle-webextension.mjs" --diagnostics --outdir "$resources" --check \
    --resources "$app_path/Contents/PlugIns/Omnibar Commands.appex/Contents/Resources"
printf '\nDiagnostic app built at the existing local path: %s\nBackup: %s\nNo application was launched and Safari was not restarted.\n' \
    "$app_path" "$diagnostics_root/pre-diagnostic-app.zip"
printf 'Return to the regular development build with ./scripts/build-macos.sh after measuring.\n'
