#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${CONFIGURATION:-Debug}"
derived_data="${DERIVED_DATA_PATH:-$project_root/build/ipad}"
ipad_platform="${IPAD_PLATFORM:-simulator}"
app_bundle_identifier="${OMNIBAR_APP_BUNDLE_IDENTIFIER:-com.dkaluta.omnibar.development.ios}"

if [[ ! "$app_bundle_identifier" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    printf 'Use a reverse-DNS OMNIBAR_APP_BUNDLE_IDENTIFIER.\n' >&2
    exit 2
fi

case "$ipad_platform" in
    simulator)
        destination="${DESTINATION:-generic/platform=iOS Simulator}"
        product_suffix=iphonesimulator
        # Simulator App Groups and shared Keychain still need embedded entitlements.
        # Ad hoc signing is local and does not require a provisioning profile.
        signing_options=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-)
        ;;
    device)
        destination="${DESTINATION:-generic/platform=iOS}"
        product_suffix=iphoneos
        signing_options=(-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic 'CODE_SIGN_IDENTITY=Apple Development')
        ;;
    *)
        printf 'Unknown IPAD_PLATFORM: %s. Use simulator or device.\n' "$ipad_platform" >&2
        exit 2
        ;;
esac
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then signing_options+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"); fi

node "$project_root/scripts/bundle-webextension.mjs" --check

xcodebuild \
    -project "$project_root/native/Omnibar-iPad/Omnibar-iPad.xcodeproj" \
    -scheme Omnibar-iPad \
    -configuration "$configuration" \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    "${signing_options[@]}" \
    "$@" \
    "OMNIBAR_APP_BUNDLE_IDENTIFIER=$app_bundle_identifier" \
    build

app_path="$derived_data/Build/Products/$configuration-$product_suffix/Omnibar.app"
python3 "$project_root/scripts/verify-ipad-bundle.py" "$app_path" "$app_bundle_identifier"
codesign --verify --deep --strict "$app_path"
printf '\nBuilt and verified iPad %s bundle: %s\n' "$ipad_platform" "$app_path"
