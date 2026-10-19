#!/usr/bin/env python3
"""Validate the iPad app/extension shape and exact shared WebExtension resources."""
import argparse
from datetime import datetime, timezone
import fnmatch
import hashlib
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def plist(path):
    with path.open('rb') as stream:
        return plistlib.load(stream)


def command_plist(*arguments):
    return plistlib.loads(subprocess.run(arguments, check=True, capture_output=True).stdout)


def authorized(value, patterns):
    return isinstance(patterns, list) and any(isinstance(pattern, str) and fnmatch.fnmatchcase(value, pattern) for pattern in patterns)


def verify_scene_lifecycle(app_info, extension_info):
    # iPadOS 27 terminates UIKit apps that still use the application-owned
    # window lifecycle. Check the built plist in every simulator/archive/export
    # verification so a missing or incomplete scene configuration cannot ship.
    manifest = app_info.get('UIApplicationSceneManifest')
    require(isinstance(manifest, dict), 'The iPad app must adopt the UIScene lifecycle.')
    require(manifest.get('UIApplicationSupportsMultipleScenes') is False,
            'The iPad settings app must explicitly use a single scene.')
    require(manifest.get('UISceneConfigurations') == {
        'UIWindowSceneSessionRoleApplication': [{
            'UISceneConfigurationName': 'Settings',
            'UISceneClassName': 'UIWindowScene',
            'UISceneDelegateClassName': 'SceneDelegate',
        }],
    }, 'The iPad settings scene must use UIWindowScene and SceneDelegate.')
    require('UIApplicationSceneManifest' not in extension_info,
            'The Safari extension must not declare an application scene lifecycle.')


def simulator_entitlements(executable):
    # Xcode puts simulator capabilities in the executable's Mach-O section,
    # separately from its ad hoc signature. Inspect every built architecture.
    architectures = subprocess.run(['/usr/bin/lipo', '-archs', str(executable)], check=True, capture_output=True).stdout.decode().split()
    require(architectures and set(architectures) <= {'arm64', 'x86_64'}, 'Unsupported simulator architecture.')
    entries = []
    for architecture in architectures:
        output = subprocess.run(['/usr/bin/otool', '-arch', architecture, '-s', '__TEXT', '__entitlements', str(executable)],
                                check=True, capture_output=True, text=True).stdout
        data = bytearray()
        for line in output.splitlines():
            fields = line.split()
            if not fields or not re.fullmatch(r'[0-9a-fA-F]{16}', fields[0]):
                continue
            for word in fields[1:]:
                require(re.fullmatch(r'(?:[0-9a-fA-F]{2}){1,4}', word), 'Invalid simulator entitlement section.')
                # otool formats arm64 as little-endian words and x86 as bytes.
                data.extend(int(word, 16).to_bytes(len(word) // 2, 'little'))
        require(data, 'Missing embedded simulator entitlements.')
        entries.append(plistlib.loads(bytes(data).rstrip(b'\0')))
    require(all(value == entries[0] for value in entries), 'Simulator architectures have different entitlements.')
    return entries[0]


def verify(app, identifier, team=None, distribution=False):
    project_root = Path(__file__).resolve().parents[1]
    subprocess.run(['node', str(project_root / 'scripts/bundle-webextension.mjs'), '--check'], check=True)
    extension = app / 'PlugIns' / 'Omnibar Commands.appex'
    require(extension.is_dir(), 'Missing embedded Safari WebExtension.')
    require(sorted(path.name for path in (app / 'PlugIns').glob('*.appex')) == ['Omnibar Commands.appex'], 'iPad must contain only the WebExtension.')
    infos = [plist(app / 'Info.plist'), plist(extension / 'Info.plist')]
    verify_scene_lifecycle(*infos)
    records = []
    for bundle, info, expected in zip([app, extension], infos, [identifier, identifier + '.Commands']):
        require(info['CFBundleIdentifier'] == expected, 'Bundle identity mismatch.')
        require(info['UIDeviceFamily'] == [2], 'The target must support iPad only.')
        require(info['OmnibarContainingAppIdentifier'] == identifier, 'Containing-app identity mismatch.')
        require(info['OmnibarSharedGroup'] == 'group.' + identifier, 'Shared preference group mismatch.')
        keychain_group = info['OmnibarKeychainGroup']
        require('$' not in keychain_group and keychain_group.endswith('.' + identifier + '.shared'), 'Unresolved or incorrect shared Keychain group.')
        if info.get('DTPlatformName') == 'iphonesimulator':
            require(not team and not distribution, 'A simulator build cannot certify device or distribution signing.')
            entitlements = simulator_entitlements(bundle / info['CFBundleExecutable'])
        else:
            entitlements = command_plist('/usr/bin/codesign', '--display', '--entitlements', '-', '--xml', str(bundle))
        require(entitlements.get('com.apple.security.application-groups') == ['group.' + identifier], 'Signed App Group differs from the native configuration.')
        require(entitlements.get('keychain-access-groups') == [keychain_group], 'Signed Keychain group differs from the native configuration.')
        record = {'identifier': expected, 'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion']}
        if team:
            require(entitlements.get('com.apple.developer.team-identifier') == team, 'Signing team mismatch.')
            application_id = entitlements.get('application-identifier')
            require(application_id == team + '.' + expected, 'Signed application identifier mismatch.')
            profile = command_plist('/usr/bin/security', 'cms', '-D', '-i', str(bundle / 'embedded.mobileprovision'))
            require(team in profile.get('TeamIdentifier', []), 'Provisioning team mismatch.')
            require('iOS' in profile.get('Platform', []), 'Expected an iOS provisioning profile.')
            expires = profile['ExpirationDate']
            require(expires.replace(tzinfo=timezone.utc) > datetime.now(timezone.utc), 'Expired iOS provisioning profile.')
            permitted = profile['Entitlements']
            require(authorized(application_id, [permitted.get('application-identifier')])
                    and authorized('group.' + identifier, permitted.get('com.apple.security.application-groups'))
                    and authorized(keychain_group, permitted.get('keychain-access-groups')),
                    'iOS profile does not authorize the app identity and shared groups.')
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--test-requirement', '=anchor apple generic', str(bundle)], check=True)
            details = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=2', str(bundle)], check=True, capture_output=True).stderr.decode()
            authority = next((line.split('=', 1)[1] for line in details.splitlines() if line.startswith('Authority=')), '')
            architectures = subprocess.run(['/usr/bin/lipo', '-archs', str(bundle / info['CFBundleExecutable'])], check=True, capture_output=True).stdout.decode().split()
            require(architectures == ['arm64'], 'Device release must contain the arm64 architecture.')
            require(info.get('DTPlatformName') == 'iphoneos', 'Expected a device build, not a simulator build.')
            if distribution:
                require(authority.startswith(('Apple Distribution:', 'iPhone Distribution:')), 'Expected an Apple distribution certificate.')
                require(not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'), 'Expected an App Store profile, not development, Ad Hoc, or enterprise.')
                require(not entitlements.get('get-task-allow') and not permitted.get('get-task-allow'), 'Distribution must not permit debugging.')
            record.update({'authority': authority, 'architectures': architectures,
                           'profile': {'name': profile['Name'], 'uuid': profile['UUID'], 'expires': expires.isoformat() + 'Z',
                                       'deviceCount': len(profile.get('ProvisionedDevices', [])),
                                       'betaReportsActive': permitted.get('beta-reports-active'),
                                       'debugAllowed': bool(permitted.get('get-task-allow'))},
                           'appGroups': entitlements['com.apple.security.application-groups'],
                           'keychainGroups': entitlements['keychain-access-groups']})
        records.append(record)
    require(infos[0]['CFBundleVersion'] == infos[1]['CFBundleVersion'], 'App and extension build numbers differ.')
    require(infos[0]['CFBundleShortVersionString'] == infos[1]['CFBundleShortVersionString'], 'App and extension versions differ.')
    require(infos[1]['NSExtension'] == {
        'NSExtensionPointIdentifier': 'com.apple.Safari.web-extension',
        'NSExtensionPrincipalClass': 'SafariWebExtensionHandler',
    }, 'Incorrect extension point or native handler.')
    require('NSAppTransportSecurity' not in infos[0], 'Unexpected transport-security override.')
    for bundle in [app, extension]:
        privacy = plist(bundle / 'PrivacyInfo.xcprivacy')
        require(privacy.get('NSPrivacyTracking') is False, 'Tracking must remain disabled.')
        require(privacy.get('NSPrivacyCollectedDataTypes') == [], 'Unexpected collected data declaration.')
        require(privacy.get('NSPrivacyTrackingDomains') == [], 'Unexpected tracking domains.')
        reasons = {reason for entry in privacy.get('NSPrivacyAccessedAPITypes', [])
                   if entry.get('NSPrivacyAccessedAPIType') == 'NSPrivacyAccessedAPICategoryUserDefaults'
                   for reason in entry.get('NSPrivacyAccessedAPITypeReasons', [])}
        require({'CA92.1', '1C8F.1'} <= reasons, 'Missing local/shared preferences required-reason declarations.')
    resource_root = project_root / 'native/Omnibar/Omnibar Commands/Resources'
    require(not (extension / 'startup-diagnostics.js').exists(), 'Development diagnostic source must not ship in the iPad extension.')
    require(all(not (extension / name).exists() for name in ['popup.html', *(f'toolbar{size}.png' for size in (16, 19, 32, 38))]), 'Removed WebExtension toolbar resources must not remain.')
    resource_count = 0
    for source in resource_root.iterdir():
        # Development timing helpers are bundled only into isolated diagnostic
        # builds. They are not a runtime dependency of either release bundle.
        if not source.is_file() or source.name == 'startup-diagnostics.js':
            continue
        installed = extension / source.name
        require(installed.is_file(), 'Missing shared resource: ' + source.name)
        require(hashlib.sha256(source.read_bytes()).digest() == hashlib.sha256(installed.read_bytes()).digest(), 'Shared resource diverged: ' + source.name)
        resource_count += 1
    manifest = json.loads((extension / 'manifest.json').read_text())
    description = manifest.get('description')
    require(isinstance(description, str) and 0 < len(description) <= 112, 'Safari App Store manifest descriptions must contain 1–112 characters.')
    require(manifest['version'] == infos[0]['CFBundleShortVersionString'], 'App and WebExtension versions differ.')
    require(manifest['commands']['open-palette']['suggested_key']['mac'] == 'Command+Shift+P', 'Keyboard shortcut changed.')
    require(manifest['background']['persistent'] is False, 'iPad requires a nonpersistent background.')
    require(set(manifest['permissions']) == {'tabs', 'activeTab', 'scripting', 'nativeMessaging'}, 'Unexpected extension permission.')
    require(not manifest.get('host_permissions') and not manifest.get('content_scripts'), 'Unexpected persistent website access.')
    require(all(key not in manifest for key in ['action', 'browser_action', 'page_action']), 'iPad palette must be keyboard-only without a toolbar action.')
    require(manifest.get('web_accessible_resources') == [{'resources': ['palette.html'], 'matches': ['http://*/*', 'https://*/*']}], 'Only the protected centered palette may be web accessible.')
    if distribution:
        require(infos[0].get('ITSAppUsesNonExemptEncryption') is False, 'Missing standard encryption declaration.')
        require((app / 'Assets.car').is_file(), 'Missing compiled application icon assets.')
        icons = infos[0].get('CFBundleIcons~ipad', infos[0].get('CFBundleIcons', {}))
        require(icons.get('CFBundlePrimaryIcon', {}).get('CFBundleIconName') == 'AppIcon', 'Missing primary iPad icon declaration.')
    print('Verified iPad scene lifecycle, identities, native bridge, privacy manifests, shortcut, and exact shared resources.')
    return {'verifiedAt': datetime.now(timezone.utc).isoformat(), 'verified': True, 'distribution': distribution,
            'app': str(app), 'bundles': records, 'resourcesMatchSource': resource_count, 'collectsData': False,
            'startupBundleSHA256': {name: hashlib.sha256((extension / name).read_bytes()).hexdigest()
                                    for name in ['palette-bundle.js', 'background-bundle.js']}}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('identifier')
    parser.add_argument('--team')
    parser.add_argument('--distribution', action='store_true')
    parser.add_argument('--receipt', type=Path)
    parser.add_argument('--package', type=Path)
    args = parser.parse_args()
    if args.distribution and not args.team:
        parser.error('--distribution requires --team')
    try:
        receipt = verify(args.app, args.identifier, args.team, args.distribution)
        if args.package:
            receipt.update({'package': str(args.package.resolve()), 'sha256': hashlib.sha256(args.package.read_bytes()).hexdigest(),
                            'bytes': args.package.stat().st_size, 'uploadedByThisVerification': False})
        if args.receipt:
            args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit('iPad bundle verification failed: ' + str(error))
