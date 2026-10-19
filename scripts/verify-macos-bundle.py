#!/usr/bin/env python3
"""Check the packaged companion and shared-storage configuration without opening it."""

import argparse
from datetime import datetime, timezone
import fnmatch
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def read_plist(path):
    with path.open('rb') as source:
        value = plistlib.load(source)
    require(isinstance(value, dict), f'Expected a property-list dictionary: {path}')
    return value


def command_plist(arguments, label):
    result = subprocess.run(arguments, capture_output=True, check=False)
    require(result.returncode == 0 and result.stdout.strip(), f'Could not read {label}. Signing inspection may require access outside a restricted sandbox.')
    try:
        value = plistlib.loads(result.stdout)
        require(isinstance(value, dict), f'Expected a dictionary in {label}.')
        return value
    except plistlib.InvalidFileException as error:
        raise VerificationError(f'Could not parse {label}.') from error


def authorized(value, patterns):
    return isinstance(patterns, list) and any(isinstance(pattern, str) and fnmatch.fnmatchcase(value, pattern) for pattern in patterns)


def check_resources(resources, manifest):
    require(manifest.get('manifest_version') == 3, 'Expected a Manifest V3 command palette.')
    description = manifest.get('description')
    require(isinstance(description, str) and 0 < len(description) <= 112,
            'Safari App Store manifest descriptions must contain 1–112 characters.')
    require(all(key not in manifest for key in ('action', 'browser_action', 'page_action')),
            'The companion must remain a keyboard-only palette without a WebExtension toolbar action.')
    require(all(not (resources / name).exists() for name in ['popup.html', *(f'toolbar{size}.png' for size in (16, 19, 32, 38))]),
            'Removed WebExtension toolbar resources must not remain in the app bundle.')
    require(manifest.get('web_accessible_resources') == [{'resources': ['palette.html'], 'matches': ['http://*/*', 'https://*/*']}],
            'Only the centered palette document may be web accessible.')
    require(manifest.get('commands', {}).get('open-palette', {}).get('suggested_key', {}).get('mac') == 'Command+Shift+P',
            'Missing Command-Shift-P palette command.')
    require(not manifest.get('content_scripts'), 'The palette must be injected only when requested, not on every webpage.')
    require(set(manifest.get('permissions', [])) == {'activeTab', 'scripting', 'tabs', 'nativeMessaging'},
            'Unexpected command palette permissions.')
    references = {'palette.html', 'palette.css', 'palette-entry.js', 'palette-core.js', 'overlay-ui.js',
                  'content.js', 'background.html', 'background-start.js', 'background.mjs', 'browser-actions.js',
                  'palette-bundle.js', 'background-bundle.js',
                  'unavailable.html', 'unavailable.css', 'unavailable.js'}

    def add(value):
        if isinstance(value, str):
            references.add(value)
        elif isinstance(value, dict):
            for nested in value.values():
                add(nested)
        elif isinstance(value, list):
            for nested in value:
                add(nested)
        elif value is not None:
            raise VerificationError('A manifest resource reference has an invalid type.')

    add(manifest.get('icons'))
    for key in ('action', 'browser_action', 'page_action', 'sidebar_action'):
        action = manifest.get(key, {})
        add(action.get('default_icon'))
        add(action.get('default_popup'))
        add(action.get('default_panel'))
    for key in ('options_page', 'devtools_page'):
        add(manifest.get(key))
    add(manifest.get('options_ui', {}).get('page'))
    add(manifest.get('side_panel', {}).get('default_path'))
    add(manifest.get('chrome_url_overrides'))
    for key in ('scripts', 'service_worker', 'page'):
        add(manifest.get('background', {}).get(key))
    for content in manifest.get('content_scripts', []):
        add(content.get('js'))
        add(content.get('css'))
    for accessible in manifest.get('web_accessible_resources', []):
        add(accessible.get('resources') if isinstance(accessible, dict) else accessible)

    root = resources.resolve()
    for reference in sorted(references):
        parsed = urlsplit(reference)
        relative = Path(unquote(parsed.path))
        require(not parsed.scheme and not parsed.netloc and not relative.is_absolute() and '..' not in relative.parts,
                f'Manifest resource must stay inside the extension: {reference}')
        matches = list(root.glob(str(relative)))
        require(matches, f'Missing command palette resource: {reference}')
        for path in matches:
            require(root in path.resolve().parents and path.is_file() and path.stat().st_size > 0,
                    f'Missing or invalid command palette resource: {reference}')


def verify(app, identifier, team=None, allow_adhoc=False):
    app_info = read_plist(app / 'Contents/Info.plist')
    expected_group = f'group.{identifier}'
    shared_keychain = None
    for suffix, bundle in [('', app), ('.Extension', app / 'Contents/PlugIns/Omnibar Extension.appex'),
                           ('.Commands', app / 'Contents/PlugIns/Omnibar Commands.appex')]:
        label = bundle.name
        info = read_plist(bundle / 'Contents/Info.plist')
        require(info.get('CFBundleIdentifier') == identifier + suffix, f'Unexpected bundle identifier: {label}')
        for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
            require(info.get(key) and info[key] == app_info.get(key), f'App and extension version/build mismatch: {label}')
        privacy = read_plist(bundle / 'Contents/Resources/PrivacyInfo.xcprivacy')
        require(privacy.get('NSPrivacyTracking') is False and not privacy.get('NSPrivacyCollectedDataTypes') and not privacy.get('NSPrivacyTrackingDomains'),
                f'Privacy manifest no longer declares zero collection/tracking: {label}')
        accessed = privacy.get('NSPrivacyAccessedAPITypes', [])
        defaults_reasons = {reason for entry in accessed if entry.get('NSPrivacyAccessedAPIType') == 'NSPrivacyAccessedAPICategoryUserDefaults'
                            for reason in entry.get('NSPrivacyAccessedAPITypeReasons', [])}
        require({'CA92.1', '1C8F.1'} <= defaults_reasons,
                f'Missing local/shared UserDefaults required-reason declarations: {label}')
        entitlements = command_plist(['/usr/bin/codesign', '--display', '--entitlements', '-', '--xml', str(bundle)], f'entitlements for {label}')
        require(entitlements.get('com.apple.security.app-sandbox') is True, f'App Sandbox entitlement missing: {label}')
        require(entitlements.get('com.apple.security.application-groups') == [expected_group], f'Incorrect shared App Group entitlement: {label}')
        require(info.get('OmnibarSharedGroup') == expected_group, f'Unresolved or incorrect shared preferences group: {label}')
        groups = entitlements.get('keychain-access-groups')
        require(isinstance(groups, list) and len(groups) == 1 and isinstance(groups[0], str), f'Expected one shared Keychain group: {label}')
        group = groups[0]
        prefix_pattern = r'(?:[A-Za-z0-9]+\.)?' if allow_adhoc else r'[A-Za-z0-9]+\.'
        require(re.fullmatch(prefix_pattern + re.escape(identifier + '.shared'), group) is not None,
                f'Unresolved or unexpected shared Keychain entitlement: {label}')
        if shared_keychain is None:
            shared_keychain = group
        require(group == shared_keychain, f'App and extensions use different Keychain groups: {label}')
        require(info.get('OmnibarSharedGroup') == expected_group and info.get('OmnibarKeychainGroup') == group
                and info.get('OmnibarContainingAppIdentifier') == identifier,
                f'Shared-storage Info.plist values do not match resolved entitlements: {label}')
        if not suffix:
            require(info.get('CFBundleURLTypes') == [{'CFBundleTypeRole': 'Editor', 'CFBundleURLName': identifier + '.settings',
                                                     'CFBundleURLSchemes': [identifier]}],
                    'Containing app must register only its identity-specific Settings URL scheme.')
        if not allow_adhoc:
            require(team and entitlements.get('com.apple.developer.team-identifier') == team, f'Unexpected signing team entitlement: {label}')
            application_id = entitlements.get('com.apple.application-identifier')
            require(isinstance(application_id, str) and application_id.endswith('.' + identifier + suffix), f'Unexpected application identifier entitlement: {label}')
            profile = command_plist(['/usr/bin/security', 'cms', '-D', '-i', str(bundle / 'Contents/embedded.provisionprofile')], f'provisioning profile for {label}')
            require(team in profile.get('TeamIdentifier', []), f'Provisioning profile team mismatch: {label}')
            expires = profile.get('ExpirationDate')
            require(isinstance(expires, datetime) and expires.replace(tzinfo=timezone.utc) > datetime.now(timezone.utc), f'Expired provisioning profile: {label}')
            permitted = profile.get('Entitlements', {})
            require(authorized(expected_group, permitted.get('com.apple.security.application-groups'))
                    and authorized(group, permitted.get('keychain-access-groups'))
                    and authorized(application_id, [permitted.get('com.apple.application-identifier')]),
                    f'Provisioning profile does not authorize shared storage and application identity: {label}')

    resources = app / 'Contents/PlugIns/Omnibar Commands.appex/Contents/Resources'
    require(not (resources / 'startup-diagnostics.js').exists(),
            'Development-only timing source must not be copied into a normal app bundle.')
    with (resources / 'manifest.json').open() as source:
        manifest = json.load(source)
    require(isinstance(manifest, dict), 'Expected a WebExtension manifest dictionary.')
    require(manifest.get('version') == app_info['CFBundleShortVersionString'], 'WebExtension manifest version differs from the app version.')
    check_resources(resources, manifest)
    source_resources = Path(__file__).resolve().parents[1] / 'native/Omnibar/Omnibar Commands/Resources'
    for source in source_resources.iterdir():
        if not source.is_file() or source.name == 'startup-diagnostics.js':
            continue
        installed = resources / source.name
        require(installed.is_file(), f'Missing shared resource: {source.name}')
        require(hashlib.sha256(source.read_bytes()).digest() == hashlib.sha256(installed.read_bytes()).digest(),
                f'Packaged resource differs from current source: {source.name}')
    generator = Path(__file__).resolve().parent / 'bundle-webextension.mjs'
    result = subprocess.run(['node', str(generator), '--check', '--resources', str(resources)], capture_output=True, text=True)
    require(result.returncode == 0, 'Packaged startup bundles are missing, stale, or differ from current source.\n' + result.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('identifier')
    parser.add_argument('--team')
    parser.add_argument('--allow-adhoc', action='store_true', help='Inspect bundle configuration only; do not certify provisioning.')
    args = parser.parse_args()
    try:
        verify(args.app, args.identifier, args.team, args.allow_adhoc)
    except (VerificationError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f'Bundle verification failed: {error}', file=sys.stderr)
        return 1
    print('Verified palette resources, versions, zero-collection manifests, and matching shared-storage entitlements' +
          (' (ad hoc; provisioning unverified).' if args.allow_adhoc else ' and provisioning profiles.'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
