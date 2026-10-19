#!/bin/bash
set -euo pipefail

action="${1:-archive}"
if [[ $# -gt 1 || ! "$action" =~ ^(archive|export|upload)$ ]]; then
    printf 'Usage: %s [archive|export|upload]\n' "$0" >&2
    exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="$project_root/native/Omnibar-iPad/Omnibar-iPad.xcodeproj"
settings_key=objects.F226C9BB93B953546368B460.buildSettings
version="$(plutil -extract "$settings_key.MARKETING_VERSION" raw -o - "$project_path/project.pbxproj")"
build_number="$(plutil -extract "$settings_key.CURRENT_PROJECT_VERSION" raw -o - "$project_path/project.pbxproj")"
team="${DEVELOPMENT_TEAM:-3W55472NF6}"
identifier=com.dkaluta.omnibar
provisioning_options=(-allowProvisioningUpdates)
if [[ -n "${ASC_API_KEY_PATH:-}${ASC_API_KEY_ID:-}${ASC_API_ISSUER_ID:-}" ]]; then
    if [[ ! -f "${ASC_API_KEY_PATH:-}" || -z "${ASC_API_KEY_ID:-}" || -z "${ASC_API_ISSUER_ID:-}" ]]; then
        printf 'Set ASC_API_KEY_PATH to an existing key file and provide ASC_API_KEY_ID and ASC_API_ISSUER_ID.\n' >&2
        exit 2
    fi
    provisioning_options+=(-authenticationKeyPath "$ASC_API_KEY_PATH"
        -authenticationKeyID "$ASC_API_KEY_ID" -authenticationKeyIssuerID "$ASC_API_ISSUER_ID")
fi
distribution_dir="${DISTRIBUTION_DIR:-$project_root/build/distribution-ipad}"
archive_path="${ARCHIVE_PATH:-$distribution_dir/Omnibar-iPad-$version-$build_number.xcarchive}"
export_path="$distribution_dir/$action-$version-$build_number"
mkdir -p "$distribution_dir/logs"
log_path="$distribution_dir/logs/$action-$(date -u +%Y%m%dT%H%M%SZ).log"
node "$project_root/scripts/bundle-webextension.mjs" --check

if [[ "$action" == archive ]]; then
    xcodebuild \
        -project "$project_path" -scheme Omnibar-iPad -configuration Release \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$distribution_dir/DerivedData" -archivePath "$archive_path" \
        "${provisioning_options[@]}" CODE_SIGN_STYLE=Automatic 'CODE_SIGN_IDENTITY=Apple Development' \
        "DEVELOPMENT_TEAM=$team" "OMNIBAR_APP_BUNDLE_IDENTIFIER=$identifier" \
        archive 2>&1 | tee "$log_path"
elif [[ ! -d "$archive_path" ]]; then
    printf 'Archive not found: %s. Run %s archive first.\n' "$archive_path" "$0" >&2
    exit 1
fi
app_path="$archive_path/Products/Applications/Omnibar.app"
codesign --verify --deep --strict --test-requirement '=anchor apple generic' "$app_path"
python3 "$project_root/scripts/verify-ipad-bundle.py" "$app_path" "$identifier" --team "$team"
for bundle_path in "$app_path" "$app_path/PlugIns/Omnibar Commands.appex"; do
    if [[ "$(plutil -extract CFBundleShortVersionString raw -o - "$bundle_path/Info.plist")" != "$version" \
       || "$(plutil -extract CFBundleVersion raw -o - "$bundle_path/Info.plist")" != "$build_number" ]]; then
        printf 'Archive version/build differs from the current project: %s\n' "$bundle_path" >&2
        exit 1
    fi
done
if [[ "$action" == archive ]]; then
    printf '\nVerified iPad archive: %s\n' "$archive_path"
    exit 0
fi

options_path="$distribution_dir/ExportOptions-$action.plist"
cat > "$options_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>$action</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$team</string>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>uploadSymbols</key><true/>
<key>testFlightInternalTestingOnly</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive_path" -exportPath "$export_path" \
    -exportOptionsPlist "$options_path" "${provisioning_options[@]}" 2>&1 | tee "$log_path"
if [[ "$action" == export ]]; then
    package="$export_path/Omnibar.ipa"
    if [[ ! -f "$package" ]]; then
        printf 'Expected iPad export package is missing: %s\n' "$package" >&2
        exit 1
    fi
    verification_dir="$(mktemp -d "$distribution_dir/export-verification-$version-$build_number.XXXXXX")"
    ditto -x -k "$package" "$verification_dir"
    python3 "$project_root/scripts/verify-ipad-bundle.py" "$verification_dir/Payload/Omnibar.app" "$identifier" \
        --team "$team" --distribution --package "$package" --receipt "$verification_dir/verification.json"
    printf '\nExported and verified iPad package: %s\nReceipt: %s\n' "$package" "$verification_dir/verification.json"
else
    printf '\niPad upload completed; App Store Connect processing continues separately.\nLog: %s\n' "$log_path"
fi
