#!/bin/bash
set -euo pipefail

action="${1:-archive}"
if [[ $# -gt 1 || ! "$action" =~ ^(archive|export|upload)$ ]]; then
    printf 'Usage: %s [archive|export|upload]\n' "$0" >&2
    exit 2
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="$project_root/native/Omnibar/Omnibar.xcodeproj"
settings_key='objects.4225A17F305694F600A739B8.buildSettings'
version="$(plutil -extract "$settings_key.MARKETING_VERSION" raw -o - "$project_path/project.pbxproj")"
build_number="$(plutil -extract "$settings_key.CURRENT_PROJECT_VERSION" raw -o - "$project_path/project.pbxproj")"
team="${DEVELOPMENT_TEAM:-$(plutil -extract "$settings_key.DEVELOPMENT_TEAM" raw -o - "$project_path/project.pbxproj")}"
distribution_dir="${DISTRIBUTION_DIR:-$project_root/build/distribution}"
archive_path="${ARCHIVE_PATH:-$distribution_dir/Omnibar-$version-$build_number.xcarchive}"
export_path="$distribution_dir/$action-$version-$build_number"
log_dir="$distribution_dir/logs"
mkdir -p "$log_dir"
log_path="$log_dir/$action-$(date -u +%Y%m%dT%H%M%SZ).log"

if [[ "$action" == archive ]]; then
    printf 'Archiving Omnibar %s (%s). Log: %s\n' "$version" "$build_number" "$log_path"
    xcodebuild \
        -project "$project_path" \
        -scheme Omnibar \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$distribution_dir/DerivedData" \
        -archivePath "$archive_path" \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic \
        'CODE_SIGN_IDENTITY=Apple Development' \
        "DEVELOPMENT_TEAM=$team" \
        archive 2>&1 | tee "$log_path"
else
    if [[ ! -d "$archive_path" ]]; then
        printf 'Archive not found: %s. Run %s archive first.\n' "$archive_path" "$0" >&2
        exit 1
    fi
fi

app_path="$archive_path/Products/Applications/Omnibar.app"
extension_path="$app_path/Contents/PlugIns/Omnibar Extension.appex"
codesign --verify --deep --strict --test-requirement '=anchor apple generic' "$app_path"
codesign --verify --strict --test-requirement '=anchor apple generic' "$extension_path"
plutil -lint "$app_path/Contents/Resources/PrivacyInfo.xcprivacy" \
    "$extension_path/Contents/Resources/PrivacyInfo.xcprivacy"

for bundle_path in "$app_path" "$extension_path"; do
    metadata_path="$bundle_path/Contents/Info.plist"
    actual_version="$(plutil -extract CFBundleShortVersionString raw -o - "$metadata_path")"
    actual_build="$(plutil -extract CFBundleVersion raw -o - "$metadata_path")"
    actual_team="$(codesign --display --verbose=2 "$bundle_path" 2>&1 | awk -F= '$1 == "TeamIdentifier" { print $2 }')"
    if [[ "$actual_version" != "$version" || "$actual_build" != "$build_number" || "$actual_team" != "$team" ]]; then
        printf 'Archive version, build, or signing team does not match the project: %s\n' "$bundle_path" >&2
        exit 1
    fi
done
if [[ "$(plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")" != com.dkaluta.omnibar \
   || "$(plutil -extract CFBundleIdentifier raw -o - "$extension_path/Contents/Info.plist")" != com.dkaluta.omnibar.Extension ]]; then
    printf 'Archive bundle identifiers do not match Omnibar.\n' >&2
    exit 1
fi

if [[ "$action" == archive ]]; then
    printf '\nArchive ready: %s\n' "$archive_path"
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

printf '%s Omnibar %s (%s). Log: %s\n' "$action" "$version" "$build_number" "$log_path"
xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$options_path" \
    -allowProvisioningUpdates 2>&1 | tee "$log_path"
if [[ "$action" == upload ]]; then
    printf '\nUpload completed. App Store Connect processing continues separately.\nLog: %s\n' "$log_path"
else
    printf '\nExport completed. Output: %s\nLog: %s\n' "$export_path" "$log_path"
fi
