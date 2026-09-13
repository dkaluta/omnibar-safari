#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${CONFIGURATION:-Release}"
derived_data="${DERIVED_DATA_PATH:-$project_root/build}"
signing_mode="${SIGNING_MODE:-development}"

case "$signing_mode" in
    development)
        signing_options=(
            -allowProvisioningUpdates
            CODE_SIGN_STYLE=Automatic
            'CODE_SIGN_IDENTITY=Apple Development'
        )
        if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
            signing_options+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
        fi
        ;;
    adhoc)
        signing_options=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
        ;;
    *)
        printf 'Unknown SIGNING_MODE: %s. Use development or adhoc.\n' "$signing_mode" >&2
        exit 2
        ;;
esac

xcodebuild \
    -project "$project_root/native/Omnibar/Omnibar.xcodeproj" \
    -scheme Omnibar \
    -configuration "$configuration" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    "${signing_options[@]}" \
    ENABLE_USER_SCRIPT_SANDBOXING=YES \
    "$@" \
    build

app_path="$derived_data/Build/Products/$configuration/Omnibar.app"
extension_path="$app_path/Contents/PlugIns/Omnibar Extension.appex"
codesign --verify --deep --strict "$app_path"

verify_development_signature() {
    local bundle_path="$1"
    local expected_team="$2"
    local signature_details signature_team="" leaf_authority="" field value

    if ! codesign --verify --strict --test-requirement '=anchor apple generic' "$bundle_path"; then
        printf 'Expected an Apple-issued development signature: %s\n' "$bundle_path" >&2
        return 1
    fi
    signature_details="$(codesign --display --verbose=2 "$bundle_path" 2>&1)"
    while IFS='=' read -r field value; do
        case "$field" in
            Authority) [[ -n "$leaf_authority" ]] || leaf_authority="$value" ;;
            TeamIdentifier) signature_team="$value" ;;
        esac
    done <<< "$signature_details"

    if [[ "$leaf_authority" != 'Apple Development: '* || -z "$signature_team" || "$signature_team" == 'not set' ]]; then
        printf 'Missing Apple Development identity or development team: %s\n' "$bundle_path" >&2
        return 1
    fi
    if [[ -n "$expected_team" && "$signature_team" != "$expected_team" ]]; then
        printf 'Signing team mismatch for %s: expected %s, found %s.\n' "$bundle_path" "$expected_team" "$signature_team" >&2
        return 1
    fi
    printf '%s' "$signature_team"
}

if [[ "$signing_mode" == development ]]; then
    app_team="$(verify_development_signature "$app_path" "${DEVELOPMENT_TEAM:-}")"
    verify_development_signature "$extension_path" "$app_team" > /dev/null
    printf '\nVerified Apple Development signatures for app and extension, team %s.\n' "$app_team"
else
    codesign --verify --strict "$extension_path"
    printf '\nVerified explicitly requested ad hoc build.\n'
fi
printf '\nBuilt and verified: %s\n' "$app_path"
