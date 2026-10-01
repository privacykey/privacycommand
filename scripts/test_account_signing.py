"""Account defaults, explicit automation, no-key upload, and Keychain notarization."""
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('apple_signing', Path(__file__).with_name('apple_signing.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class AccountSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_local_default_ignores_stale_api_key(self):
        env = signing.load_environment({'HOME': str(self.root), 'APPLE_TEAM_ID': 'ABCDE12345',
                                        'APPLE_API_KEY_ID': 'stale', 'APPLE_API_ISSUER': 'expired'})
        self.assertEqual(env['APPLE_PROVISIONING_AUTH'], 'account')
        self.assertEqual(signing.provisioning_arguments(env), ['-allowProvisioningUpdates'])

    def test_ci_keeps_api_auth_and_explicit_account_wins(self):
        env = signing.load_environment({'HOME': str(self.root), 'CI': 'true',
                                        'APPLE_API_KEY_ID': 'ABCDE12345',
                                        'APPLE_API_ISSUER': '00000000-0000-0000-0000-000000000000'})
        self.assertEqual(env['APPLE_PROVISIONING_AUTH'], 'auto')
        self.assertIn('-authenticationKeyPath', signing.provisioning_arguments(env, check_file=False))
        env = signing.load_environment(dict(env, APPLE_PROVISIONING_AUTH='account'))
        self.assertEqual(signing.provisioning_arguments(env), ['-allowProvisioningUpdates'])

    def test_explicit_api_mode_requires_credentials_before_exec(self):
        result = subprocess.run(['python3', signing.__file__, '--exec', 'true'],
                                env={'HOME': str(self.root), 'PATH': os.environ['PATH'],
                                     'APPLE_PROVISIONING_AUTH': 'api-key'}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('APPLE_API_KEY_ID', result.stderr)

    def test_keychain_profile_notarizes_without_api_key(self):
        env = signing.load_environment({'HOME': str(self.root), 'APPLE_NOTARY_PROFILE': 'Release Profile',
                                        'APPLE_NOTARY_KEYCHAIN': str(self.root/'profile keychain')})
        self.assertEqual(signing.notary_arguments(env),
                         ['--keychain-profile', 'Release Profile', '--keychain', str(self.root/'profile keychain')])

    def test_profile_takes_precedence_over_stale_api_settings(self):
        self.assertEqual(signing.notary_arguments({'APPLE_NOTARY_PROFILE': 'Release', 'APPLE_API_KEY_ID': 'stale'}),
                         ['--keychain-profile', 'Release'])

    def test_xcode_account_is_not_notary_authentication(self):
        with self.assertRaisesRegex(ValueError, 'Xcode account login alone'):
            signing.notary_arguments({'APPLE_TEAM_ID': 'ABCDE12345', 'APPLE_PROVISIONING_AUTH': 'account'})

    def test_apple_id_notary_fallback_is_preserved(self):
        self.assertEqual(signing.notary_arguments({'APPLE_TEAM_ID': 'ABCDE12345', 'APPLE_NOTARY_USER': 'test@example.invalid',
                                                 'APPLE_NOTARY_PASSWORD': 'test-only-password'}),
                         ['--apple-id', 'test@example.invalid', '--password', 'test-only-password', '--team-id', 'ABCDE12345'])

    def test_upload_uses_xcode_account_and_preserves_existing_build(self):
        archive = self.root/'Existing.xcarchive';archive.mkdir()
        original = plistlib.dumps({'ApplicationProperties': {'CFBundleVersion': '2026.1001.0100'}})
        (archive/'Info.plist').write_bytes(original)
        def upload(command, **kwargs):
            if 'artifact-verify' in command:
                self.assertIn(str(archive), command)
                self.assertEqual(command[-2:], ['--channel', 'testflight'])
                return subprocess.CompletedProcess(command, 0)
            self.assertEqual(command[:2], ['xcodebuild', '-exportArchive'])
            self.assertIn(str(archive), command)
            self.assertNotIn('-authenticationKeyPath', command)
            options = plistlib.loads(Path(command[command.index('-exportOptionsPlist')+1]).read_bytes())
            self.assertEqual(options['destination'], 'upload')
            self.assertEqual(options['teamID'], 'ABCDE12345')
            self.assertFalse(options['manageAppVersionAndBuildNumber'])
            self.assertTrue(kwargs['check'])
            return subprocess.CompletedProcess(command, 0)
        with patch.object(signing.subprocess, 'run', side_effect=upload) as run:
            signing.upload_archive(archive, {'APPLE_TEAM_ID': 'ABCDE12345', 'APPLE_PROVISIONING_AUTH': 'account'})
            has_contract=(Path(signing.__file__).resolve().parents[1]/'.project/commands.json').is_file()
            self.assertEqual(run.call_count, 2 if has_contract else 1)
        self.assertEqual((archive/'Info.plist').read_bytes(), original)

    def test_contract_rejection_prevents_credential_use_and_remote_upload(self):
        scripts=self.root/'Scripts';scripts.mkdir();(self.root/'.project').mkdir()
        (self.root/'.project/commands.json').write_text('{}')
        archive=self.root/'Existing.xcarchive';archive.mkdir();(archive/'Info.plist').write_bytes(plistlib.dumps({}))
        with patch.object(signing,'__file__',str(scripts/'apple_signing.py')),patch.object(signing.subprocess,'run',side_effect=subprocess.CalledProcessError(1,['guard'])) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                signing.upload_archive(archive,{'APPLE_TEAM_ID':'ABCDE12345','APPLE_PROVISIONING_AUTH':'api-key'})
        self.assertEqual(run.call_count,1)
        self.assertIn('artifact-verify',run.call_args.args[0])
        self.assertNotIn('xcodebuild',run.call_args.args[0])

    def test_missing_archive_fails_before_upload(self):
        with patch.object(signing.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'existing .xcarchive'):
                signing.upload_archive(self.root/'Missing.xcarchive', {'APPLE_TEAM_ID': 'ABCDE12345'})
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
