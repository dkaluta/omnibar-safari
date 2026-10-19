# iPad checks

From the repository root, run:

```sh
native/Omnibar-iPad/Tests/test-mobile-bridge.sh
```

This builds the Foundation/Safari native bridge on the Mac host with in-memory preferences and credential storage. It never reads or changes personal Keychain items. It verifies the iPad message contract, address/search resolution, explicit private Kagi behavior, settings-link validation, first-use tips, malformed requests, and the absence of browsing-data persistence or Mac migration prompts.

## Scene lifecycle

Run the bundle-verifier regression checks from the repository root:

```sh
python3 tests/IPadSceneLifecycleTests.py
```

These reject the missing scene manifest that caused the iPadOS 27 startup crash, incomplete scene configuration, and application scene declarations on the Safari extension. The normal iPad build, archive, and export checks validate the built app's scene configuration too.

The UIKit harness compiles the production scene delegate with isolated settings and a test settings controller. It checks scene-owned window creation, activation refresh, clearing sensitive input on deactivation, and settings URLs at launch and while running. Build it without launching a simulator:

```sh
native/Omnibar-iPad/Tests/test-lifecycle.sh --build-only
```

To run it, first boot an iPad simulator and supply its identifier:

```sh
SIMULATOR_UDID="your-booted-iPad-UUID" native/Omnibar-iPad/Tests/test-lifecycle.sh
```

The harness uses a separate test app identity and does not access personal preferences or Keychain items. Its console output is saved under `build/tests/ipad-lifecycle/results.log`.

The UIKit app and extension also need an iPad simulator or device build. These isolated checks do not establish live Safari keyboard behavior, extension activation, signed App Group/Keychain access, VoiceOver behavior, or physical-device readiness.
