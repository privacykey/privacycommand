"""Run the real release shell through credential checks, stopping at mocked Xcode."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent


class ShellSigningTests(unittest.TestCase):
    def test_shared_settings_reach_shell_archive_before_xcode_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            scripts = root / SCRIPTS.name
            scripts.mkdir()
            runner = 'archive.sh' if (SCRIPTS / 'archive.sh').exists() else 'release.sh'
            for name in (runner, 'apple_signing.py'):
                shutil.copyfile(SCRIPTS / name, scripts / name)
            (root / 'Config').mkdir()
            (root / 'Config/Shared.xcconfig').write_text('MARKETING_VERSION = 1.0.0\n')
            (root / 'BananaBlitz.xcodeproj').mkdir()
            (root / 'FrameSplash').mkdir()
            (root / 'privacycommand').mkdir()
            (scripts / 'buildinfo.sh').write_text('#!/bin/bash\nprintf "%s\\n" BUILD_NUMBER=2026.1001.0100 BUILD_SHA=fixture BUILD_BRANCH=main BUILD_DIRTY=NO BUILD_DIRTY_FILES=0 BUILD_DIFF_ID= BUILD_DESCRIBE=fixture BUILD_TAGGED=NO BUILD_TIMESTAMP=2026-10-01T01:00:00Z BUILD_CHANNEL=release\n')
            (scripts / 'buildinfo.sh').chmod(0o755)
            key = root / 'key with spaces.p8'
            key.write_text('fixture')
            config = root / 'signing.env'
            config.write_text('APPLE_TEAM_ID=ABCDE12345\nAPPLE_API_KEY_ID=ABCDE12345\nAPPLE_API_ISSUER=00000000-0000-0000-0000-000000000000\nAPPLE_API_KEY_PATH="'+str(key)+'"\nAPPLE_DEVELOPER_ID_IDENTITY="Developer ID Application: Test (ABCDE12345)"\n')
            bin = root / 'bin'
            bin.mkdir()
            (bin / 'xcodegen').write_text('#!/bin/bash\nexit 0\n')
            (bin / 'xcodebuild').write_text('#!/usr/bin/env python3\nimport json,os,sys\nif sys.argv[1:]==["-version"]:sys.exit(0)\nopen(os.environ["TEST_ARCHIVE_ARGS"],"w").write(json.dumps(sys.argv[1:]))\nsys.exit(99)\n')
            for file in bin.iterdir():file.chmod(0o755)
            env = {k:v for k,v in os.environ.items() if not k.startswith('APPLE_') and k not in ('TEAM_ID','FASTLANE_TEAM_ID','ORBARI_TEAM_ID','ASC_KEY_ID','ASC_ISSUER_ID','DEVELOPER_ID','KEYCHAIN_PATH','TEAM_ID_OVERRIDE')}
            output = root / 'args.json'
            env.update(PATH=str(bin)+':'+os.defpath, APPLE_SIGNING_CONFIG=str(config),
                       TEST_ARCHIVE_ARGS=str(output), SKIP_CK_SCHEMA_CHECK='1', PYTHONDONTWRITEBYTECODE='1')
            result = subprocess.run(['bash', str(scripts/runner)], cwd=root, env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode,99,result.stdout+result.stderr)
            args = json.loads(output.read_text())
            self.assertIn('DEVELOPMENT_TEAM=ABCDE12345', args)
            if runner=='archive.sh':
                self.assertIn(str(key), args)
                self.assertIn('-authenticationKeyID', args)
            else:
                self.assertIn('CODE_SIGN_IDENTITY=Developer ID Application: Test (ABCDE12345)',args)
            self.assertNotIn('fixture private key',result.stdout+result.stderr)


if __name__ == '__main__':
    unittest.main()
