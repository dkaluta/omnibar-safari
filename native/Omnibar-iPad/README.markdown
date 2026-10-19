# Omnibar for iPad

This companion project packages the shared Omnibar WebExtension for iPad Safari. It contains a UIKit settings app and a Safari WebExtension. The original AppKit toolbar extension stays in the Mac project.

The palette's HTML, CSS, JavaScript, icons, and manifest are referenced directly from `../Omnibar/Omnibar Commands/Resources`. The URL resolver and search settings model are also shared. There is no copied browser implementation to keep synchronized.

## Build

Open `Omnibar-iPad.xcodeproj`, select the `Omnibar-iPad` scheme, and choose an iPad simulator or development device. The minimum deployment target is iPadOS 17. Only the iPad device family is enabled.

From the repository root:

```sh
./scripts/build-ipad.sh
```

This first verifies that the generated startup bundles match their source, then builds an ad hoc signed simulator bundle under `build/ipad` and verifies the embedded extension, privacy manifests, platform identities, and exact shared web resources. Local simulator signing embeds the App Group and Keychain entitlements without requiring a provisioning profile. Install the pinned dependencies with `npm ci --prefix website` and regenerate changed bundles with `node scripts/bundle-webextension.mjs` before building. For a connected development iPad:

```sh
IPAD_PLATFORM=device ./scripts/build-ipad.sh
```

Device builds use automatic Apple Development signing. Override `DEVELOPMENT_TEAM`, `DESTINATION`, or `DERIVED_DATA_PATH` as needed. The build script does not install the app, enable the extension, archive a release, or upload anything.

## App lifecycle

The settings app uses one `UIWindowScene`, declared in `Info.plist`. `SceneDelegate` owns its window and handles activation, clearing sensitive input on deactivation, and settings URLs both at launch and while running. `AppDelegate` handles only the application lifecycle. Multiple settings windows are disabled.

Build 11 was rejected after four identical startup crashes on iPadOS 27.0.1. Its archived symbols match the supplied crash reports, which trap in `___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption_block_invoke` before the app can show its settings. The archive was built with SDK 27 but did not declare a scene lifecycle. [Apple requires scene lifecycle adoption for apps built with SDK 27](https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle). Build 12 adds the required lifecycle without changing the settings screen or browser extension.

The bundle verifier checks the scene configuration in simulator builds, device archives, and exports. See [the test instructions](Tests/README.markdown) for the verifier regressions and isolated UIKit lifecycle harness.

## Identity and data

Local builds use `com.dkaluta.omnibar.development.ios` and its `.Commands` extension. The App Group and Keychain access group derive from that identity, keeping development settings separate from production. Distribution builds use `com.dkaluta.omnibar` and its `.Commands` extension. The iPad and Mac platforms share the existing App Store listing and production identifiers while using their respective provisioning profiles.

The native settings app stores engine configuration, website suffix, and first-use tips locally. The private Kagi link stays in the device-only shared Keychain. The extension does not store browsing history, queries, or tab metadata and does not collect analytics.

## Safari and keyboard use

After installing the containing app, enable Omnibar Commands in Safari's extension controls. A connected hardware keyboard is required. Open the palette with **Command-Shift-P** on a regular webpage; there is no WebExtension toolbar action or popup. Type a search or website, use **@** for tabs and **>** for commands, then use the arrows and Return. Command-Return opens a search or website in a new tab. Escape, Command-Shift-P, and a tap outside dismiss the centered palette.

The existing manifest's Mac shortcut is also used on iPad: WebKit chooses an `ios` shortcut when present, then `mac`, then `default`. Safari 26 and later also show extension commands in the iPad menu bar. See [Safari 26 release notes](https://developer.apple.com/documentation/safari-release-notes/safari-26-release-notes) and [WebKit's command manifest parsing](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/WebExtension.cpp).

The iPad native bridge cannot use macOS's `NSWorkspace` settings launcher. Search settings are available directly in the containing Omnibar app; the extension provides honest instructions to open it from the Home Screen. It does not use an undocumented app-launch workaround.

## Validation still required on device

An SDK build does not verify live Safari behavior. Before an iPad release, test first-keystroke focus, hardware keyboard and non-US/IME input, Return/Command-Return, Escape/toggle/outside dismissal, tab operations, private-window isolation, app suspension and reconnect guidance, and multiple Safari windows. Also verify portrait/landscape, narrow multitasking windows, the software keyboard, VoiceOver, larger text, and touch/trackpad hit targets.

## Distribution

Run `./scripts/distribute-ipad.sh archive`, then `./scripts/distribute-ipad.sh export` from the repository root. The release pipeline signs for the production iPad identities and verifies profiles, entitlements, privacy manifests, exact shared resources, and the exported package. Upload with `./scripts/distribute-ipad.sh upload` only as part of an authorized release. An archive or upload does not establish App Store approval or public availability.

For API-key authentication without a signed-in Xcode account, set `ASC_API_KEY_PATH` to the private `.p8` file, and supply `ASC_API_KEY_ID` and `ASC_API_ISSUER_ID`. All three are required together. The distribution script passes them to Xcode for provisioning and cloud signing; keep the key outside the repository.

## Simulator evidence

### Startup crash fix — 2026-10-15

On iPad Air 13-inch (M4), iPadOS 27.0 (24A434), the existing build 11 simulator app reproduced the same missing-scene-lifecycle trap as the review reports. Build 12 survived three fresh launches and opened its settings screen through the settings URL after the system's Open confirmation. The current capture is `../../build/ipad-crash-fix/build-12-settings.png`.

The isolated UIKit harness passed 22 lifecycle checks, including completed warm settings navigation, activation refresh, and sensitive-input clearing. The verifier passed six regression tests and rejected the original build 11 archive. Existing native bridge, native WebExtension, and browser tests passed 66, 90, and 135 checks respectively.

The signed arm64 device archive, `../../build/distribution-ipad/Omnibar-iPad-2.0-12.xcarchive`, passed bundle, provisioning, entitlements, and resource verification. After the user signed into Xcode with the existing Admin account, automatic cloud signing exported `../../build/distribution-ipad/export-2.0-12/Omnibar.ipa`. The exported package passed distribution certificate, provisioning profile, app/extension identity, privacy, scene lifecycle, and exact resource checks; its receipt is `../../build/distribution-ipad/export-verification-2.0-12.YX8Ar9/verification.json`.

The earlier API-key attempt authenticated successfully but lacked cloud signing permission, so the successful export used the signed-in Xcode account without API-key overrides. The release script supports either path and handles the account path on macOS Bash 3.2. After explicit user authorization, build 12 was uploaded and Apple processed it as valid and App Store eligible, with build ID `1cedc94a-1cba-4021-b7c5-a70e3603b2af`. It replaced build 11 on iOS version 2.0, and updated review notes preserve setup instructions, describe the crash fix and simulator checks, and clarify that no proprietary accessory or app-specific keyboard pairing is involved.

The user supplied `IMG_5456.MOV`, showing the physical iPad and attached keyboard with Omnibar's Safari palette in use. That original 55,920,859-byte file was attached to App Review Information as attachment `968b6fce-90d9-4cb5-9b84-7d1e696c2927`; Apple verified its MD5 and reported asset state `COMPLETE`. Apple permits one review attachment, so the separate supplied screen recording was not attached. The notes describe the physical footage and clarify that the keyboard is already connected to iPadOS and Omnibar has no separate pairing step. The footage does not establish a particular installed build or OS version.

Build 12 was resubmitted under existing review submission `dd95a5d5-7718-47d8-b39a-ed01810d75b1` on October 15, 2026. Both the submission and iOS version reported `WAITING_FOR_REVIEW`. The final receipt is `../../build/distribution-ipad/app-review-submission-2.0-12.json`; the attachment receipt is `../../build/distribution-ipad/review-video-attachments-2.0-12.json`. App Store approval and public availability remain separate from this verified submission.

### Earlier captures

The earlier app and extension built successfully with Xcode 27's simulator SDK, including exact shared browser resources and the privacy/identity checks. The separate native bridge checks passed 66 cases. The app was installed and launched on **iPad Air 13-inch (M4), iPadOS 27.0 (24A434)** in light appearance. Historical simulator captures are saved at:

- `../../build/app-store/screenshots/ipad-2.0-9/01-settings.png` — native settings, portrait, 2048 × 2732.
- `../../build/app-store/screenshots/ipad-2.0-9/02-safari-palette.png` — centered Safari palette with the current tab and native search settings loaded, landscape, 2732 × 2048.

Those captures used iPad development version **2.0 (1)**; the screenshot folder grouped the tablet work with the Mac 2.0 (9) work. Device Hub's accessibility interface timed out even after restarting its host, so the user enabled and opened Omnibar for the Safari capture. They precede the removal of the WebExtension toolbar action and should be replaced for the final keyboard-only release.

Keyboard operation, separate search/command screenshots, opening latency, and the device checks above remain unverified. No mock palette screenshots were substituted.
