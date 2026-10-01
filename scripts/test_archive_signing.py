"""Exercise actual archive command plans without Xcode or credentials."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('archive-app.py')


class ArchiveSigningTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        config = root / 'signing.env'
        config.write_text('APPLE_TEAM_ID=ABCDE12345\nAPPLE_API_KEY_ID=ABCDE12345\n'
                          'APPLE_API_ISSUER=84eafacc-18d8-41e9-ad12-d24703a41e1e\n'
                          'APPLE_API_KEY_PATH="/keys/Apple key.p8"\n')
        self.env = {name: value for name, value in os.environ.items()
                    if name not in ('APPLE_TEAM_ID', 'TEAM_ID', 'FASTLANE_TEAM_ID', 'ORBARI_TEAM_ID',
                                    'APPLE_API_KEY_PATH', 'APPLE_API_KEY_ID', 'APPLE_API_ISSUER',
                                    'ASC_KEY_ID', 'ASC_ISSUER_ID', 'APPLE_PROVISIONING_AUTH',
                                    'APPLE_SIGNING_IDENTITY', 'KEYCHAIN_PATH')}
        self.env['APPLE_SIGNING_CONFIG'] = str(config)

    def plan(self, *args):
        result = subprocess.run(['python3', str(SCRIPT), '--plan', *args], env=self.env,
                                capture_output=True, text=True, check=True)
        return next(command for command in json.loads(result.stdout) if 'archive' in command)

    def test_shared_settings_reach_actual_xcode_command(self):
        command = self.plan()
        self.assertIn('DEVELOPMENT_TEAM=ABCDE12345', command)
        self.assertIn('/keys/Apple key.p8', command)
        self.assertIn('-authenticationKeyID', command)
        self.assertIn('-authenticationKeyIssuerID', command)

    def test_explicit_account_and_identity_overrides_reach_xcode(self):
        self.env.update(APPLE_PROVISIONING_AUTH='account', APPLE_TEAM_ID='ZYXWV98765',
                        APPLE_SIGNING_IDENTITY='Apple Development')
        command = self.plan()
        self.assertIn('DEVELOPMENT_TEAM=ZYXWV98765', command)
        self.assertIn('CODE_SIGN_IDENTITY=Apple Development', command)
        self.assertIn('-allowProvisioningUpdates', command)
        self.assertNotIn('-authenticationKeyPath', command)

    def test_unsigned_ci_ignores_local_settings_and_auth(self):
        Path(self.env['APPLE_SIGNING_CONFIG']).write_text('not valid shell settings')
        command = self.plan('--unsigned')
        self.assertIn('CODE_SIGNING_ALLOWED=NO', command)
        self.assertNotIn('-allowProvisioningUpdates', command)
        self.assertNotIn('-authenticationKeyPath', command)
        self.assertFalse(any(arg.startswith('DEVELOPMENT_TEAM=') for arg in command))


if __name__ == '__main__':
    unittest.main()
