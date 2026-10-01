import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("apple_signing", Path(__file__).with_name("apple_signing.py"))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.config = self.home / ".config/apple/signing.env"
        self.config.parent.mkdir(parents=True)
        self.key = self.home / "keys with spaces/AuthKey_ABCDEFGHIJ.p8"
        self.key.parent.mkdir()
        self.key.write_text("TEST KEY CONTENT MUST NEVER APPEAR IN OUTPUT")
        self.values = {"APPLE_TEAM_ID": "ABCDE12345", "APPLE_API_KEY_ID": "ABCDEFGHIJ",
                       "APPLE_API_ISSUER": "00000000-0000-0000-0000-000000000000",
                       "APPLE_API_KEY_PATH": str(self.key)}

    def config_values(self):
        self.config.write_text('\n'.join('export ' + k + '=' + json.dumps(v) for k, v in self.values.items()))

    def test_shared_file_expands_home_and_preserves_spaces(self):
        self.config_values()
        with self.config.open("a") as file:
            file.write('\nexport KEYCHAIN_PATH="$HOME/a keychain"\n')
        env = signing.load_environment({"HOME": str(self.home)})
        self.assertEqual(env["KEYCHAIN_PATH"], str(self.home / "a keychain"))
        args = signing.provisioning_arguments(env)
        self.assertEqual(args[args.index("-authenticationKeyPath") + 1], str(self.key))

    def test_explicit_canonical_environment_wins_over_alias_and_file(self):
        self.config_values()
        env = signing.load_environment({"HOME": str(self.home), "APPLE_TEAM_ID": "ZZZZZ12345", "TEAM_ID": "YYYYY12345"})
        self.assertEqual(env["APPLE_TEAM_ID"], "ZZZZZ12345")

    def test_legacy_environment_wins_over_file_default(self):
        self.config_values()
        env = signing.load_environment({"HOME": str(self.home), "ORBARI_TEAM_ID": "ZZZZZ12345", "ASC_KEY_ID": "ZZZZZ67890"})
        self.assertEqual(env["APPLE_TEAM_ID"], "ZZZZZ12345")
        self.assertEqual(env["APPLE_API_KEY_ID"], "ZZZZZ67890")

    def test_account_provisioning_does_not_send_api_credentials(self):
        self.config_values()
        env = signing.load_environment({"HOME": str(self.home), "APPLE_PROVISIONING_AUTH": "account"})
        self.assertEqual(signing.provisioning_arguments(env), ["-allowProvisioningUpdates"])
        self.assertEqual(env["APPLE_API_KEY_ID"], "ABCDEFGHIJ")

    def test_no_key_uses_signed_in_xcode_account(self):
        env = signing.load_environment({"HOME": str(self.home)})
        self.assertEqual(signing.provisioning_arguments(env), ["-allowProvisioningUpdates"])

    def test_incomplete_key_fails_before_build(self):
        env = signing.load_environment({"HOME": str(self.home), "APPLE_API_KEY_ID": "ABCDEFGHIJ"})
        with self.assertRaisesRegex(ValueError, "APPLE_API_ISSUER"):
            signing.provisioning_arguments(env)

    def test_key_path_defaults_to_conventional_folder(self):
        env = signing.load_environment({"HOME": str(self.home), "APPLE_API_KEY_ID": "ABCDEFGHIJ"})
        self.assertEqual(env["APPLE_API_KEY_PATH"], str(self.home / ".appstoreconnect/private_keys/AuthKey_ABCDEFGHIJ.p8"))

    def test_configuration_never_executes_shell_commands(self):
        marker = self.home / "must-not-exist"
        self.config.write_text('export APPLE_TEAM_ID="$(touch ' + str(marker) + ')"\n')
        with self.assertRaisesRegex(ValueError, "Shell commands"):
            signing.load_environment({"HOME": str(self.home)})
        self.assertFalse(marker.exists())

    def test_single_quoted_password_is_literal(self):
        self.config.write_text("export APPLE_NOTARY_PASSWORD='literal$PASSWORD'\n")
        env = signing.load_environment({"HOME": str(self.home)})
        self.assertEqual(env["APPLE_NOTARY_PASSWORD"], "literal$PASSWORD")

    def test_invalid_config_error_does_not_repeat_secret_value(self):
        self.config.write_text('export APPLE_NOTARY_PASSWORD="SECRET_UNTERMINATED\n')
        with self.assertRaises(ValueError) as error:
            signing.load_environment({"HOME": str(self.home)})
        self.assertNotIn("SECRET_UNTERMINATED", str(error.exception))

    def test_check_reads_path_but_never_prints_private_key_contents(self):
        self.config_values()
        run = subprocess.run([sys.executable, str(Path(signing.__file__)), "--check"],
                             env={"HOME": str(self.home), "PATH": os.environ["PATH"]}, text=True, capture_output=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn(self.key.read_text(), run.stdout + run.stderr)
        self.assertIn("permissions and profiles", run.stdout)

    def test_missing_explicit_settings_file_is_an_error(self):
        with self.assertRaisesRegex(ValueError, "APPLE_SIGNING_CONFIG"):
            signing.load_environment({"HOME": str(self.home), "APPLE_SIGNING_CONFIG": str(self.home / "absent")})


if __name__ == "__main__":
    unittest.main()
