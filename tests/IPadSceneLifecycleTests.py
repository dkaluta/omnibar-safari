"""Reject release bundles that would restore the iPad startup lifecycle crash."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('verify_ipad_bundle', ROOT / 'scripts/verify-ipad-bundle.py')
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class IPadSceneLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.app_info = {'UIApplicationSceneManifest': {
            'UIApplicationSupportsMultipleScenes': False,
            'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
                'UISceneConfigurationName': 'Settings',
                'UISceneClassName': 'UIWindowScene',
                'UISceneDelegateClassName': 'SceneDelegate',
            }]},
        }}

    def test_single_settings_scene_is_accepted(self):
        VERIFIER.verify_scene_lifecycle(self.app_info, {})

    def test_legacy_application_window_lifecycle_is_rejected(self):
        for manifest in (None, {}, [], ''):
            with self.subTest(manifest=manifest), self.assertRaises(ValueError):
                VERIFIER.verify_scene_lifecycle({'UIApplicationSceneManifest': manifest}, {})
        with self.assertRaisesRegex(ValueError, 'adopt the UIScene lifecycle'):
            VERIFIER.verify_scene_lifecycle({}, {})

    def test_multiple_scene_support_must_be_explicitly_disabled(self):
        for value in (True, None, 0):
            app_info = deepcopy(self.app_info)
            app_info['UIApplicationSceneManifest']['UIApplicationSupportsMultipleScenes'] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'single scene'):
                VERIFIER.verify_scene_lifecycle(app_info, {})
        del self.app_info['UIApplicationSceneManifest']['UIApplicationSupportsMultipleScenes']
        with self.assertRaisesRegex(ValueError, 'single scene'):
            VERIFIER.verify_scene_lifecycle(self.app_info, {})

    def test_incomplete_scene_configuration_is_rejected(self):
        for key in ('UISceneConfigurationName', 'UISceneClassName', 'UISceneDelegateClassName'):
            app_info = deepcopy(self.app_info)
            scene = app_info['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication'][0]
            del scene[key]
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'UIWindowScene and SceneDelegate'):
                VERIFIER.verify_scene_lifecycle(app_info, {})

    def test_scene_must_use_application_window_role_and_delegate(self):
        configurations = self.app_info['UIApplicationSceneManifest']['UISceneConfigurations']
        for configs in ({}, {'UIWindowSceneSessionRoleExternalDisplay': configurations['UIWindowSceneSessionRoleApplication']},
                       {'UIWindowSceneSessionRoleApplication': []}):
            app_info = deepcopy(self.app_info)
            app_info['UIApplicationSceneManifest']['UISceneConfigurations'] = configs
            with self.subTest(configurations=configs), self.assertRaises(ValueError):
                VERIFIER.verify_scene_lifecycle(app_info, {})
        for delegate in ('AppDelegate', 'MissingSceneDelegate', ''):
            app_info = deepcopy(self.app_info)
            app_info['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication'][0]['UISceneDelegateClassName'] = delegate
            with self.subTest(delegate=delegate), self.assertRaises(ValueError):
                VERIFIER.verify_scene_lifecycle(app_info, {})

    def test_extension_cannot_acquire_application_scene_manifest(self):
        for manifest in (self.app_info['UIApplicationSceneManifest'], {}, None):
            with self.subTest(manifest=manifest), self.assertRaisesRegex(ValueError, 'Safari extension'):
                VERIFIER.verify_scene_lifecycle(self.app_info, {'UIApplicationSceneManifest': manifest})


if __name__ == '__main__':
    unittest.main()
