"""Exercise the real macOS sandbox using an isolated app-extension fixture.

No Safari, windows, app registration, preferences, or Keychain are accessed.
"""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SettingsRouteSandboxTests(unittest.TestCase):
    def test_own_containing_app_is_valid_when_sandbox_denies_parent_metadata(self):
        with tempfile.TemporaryDirectory(prefix="omnibar-route-sandbox-", dir="/private/tmp") as temporary:
            directory = Path(temporary)
            app = directory / "Omnibar Route Fixture.app"
            extension = app / "Contents/PlugIns/Commands.appex"
            identifier = "com.dkaluta.omnibar.route-fixture"
            for bundle, suffix, package in ((app, "", "APPL"), (extension, ".Commands", "XPC!")):
                (bundle / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": identifier + suffix,
                    "CFBundlePackageType": package,
                    "CFBundleExecutable": "Probe",
                    "OmnibarContainingAppIdentifier": identifier,
                }))
            source = directory / "probe.m"
            source.write_text('''#import <Foundation/Foundation.h>
#import "OmnibarSettingsLink.h"
int main(void) { @autoreleasepool {
    NSBundle *extension = NSBundle.mainBundle;
    NSURL *expected = extension.bundleURL.URLByStandardizingPath.URLByResolvingSymlinksInPath.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:[expected URLByAppendingPathComponent:@"Contents/Info.plist"] options:0 error:&error];
    BOOL denied = !data && [error.domain isEqual:NSCocoaErrorDomain] && error.code == NSFileReadNoPermissionError;
    BOOL valid = [OmnibarSettingsApplicationURL(extension) isEqual:expected];
    printf("sandbox_denied_parent_metadata=%u own_parent_valid=%u\\n", denied, valid);
    return denied && valid ? 0 : 1;
} }
''')
            binary = extension / "Contents/MacOS/Probe"
            subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc",
                            "-Wall", "-Wextra", "-Werror", "-framework", "Foundation",
                            "-I", str(ROOT / "native/Omnibar/Omnibar"), str(source), "-o", str(binary)],
                           check=True, capture_output=True)
            shutil.copy2(binary, app / "Contents/MacOS/Probe")
            entitlements = directory / "fixture.entitlements"
            entitlements.write_bytes(plistlib.dumps({"com.apple.security.app-sandbox": True}))
            subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(extension)],
                           check=True, capture_output=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip(), "sandbox_denied_parent_metadata=1 own_parent_valid=1")


if __name__ == "__main__":
    unittest.main()
