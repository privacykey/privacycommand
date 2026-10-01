#!/usr/bin/env python3
"""Shared Apple release settings. Private key contents are never read or logged."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import plistlib
import subprocess
import tempfile
import sys

ALIASES = {
    "APPLE_TEAM_ID": ("TEAM_ID", "FASTLANE_TEAM_ID", "ORBARI_TEAM_ID", "APPLE_NOTARY_TEAM_ID"),
    "APPLE_API_KEY_ID": ("ASC_KEY_ID",),
    "APPLE_API_ISSUER": ("ASC_ISSUER_ID",),
}
API_KEYS = ("APPLE_API_KEY_PATH", "APPLE_API_KEY_ID", "APPLE_API_ISSUER")
SETTINGS = set(ALIASES) | set(API_KEYS) | {
    name for aliases in ALIASES.values() for name in aliases
} | {
    "APPLE_SIGNING_IDENTITY", "APPLE_DEVELOPER_ID_IDENTITY", "DEVELOPER_ID",
    "APPLE_PROVISIONING_AUTH", "APPLE_NOTARY_USER", "APPLE_NOTARY_PASSWORD",
    "KEYCHAIN_PATH", "TEAM_ID_OVERRIDE", "APPLE_NOTARY_PROFILE", "APPLE_NOTARY_KEYCHAIN",
}


def expand(value, environment):
    def replace(match):
        name = match.group(1) or match.group(2)
        if name not in environment:
            raise ValueError("Undefined variable in Apple settings: " + name)
        return environment[name]
    value = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", replace, value)
    if value.startswith("~/"):
        value = str(Path(environment.get("HOME", str(Path.home()))) / value[2:])
    return value


def load_environment(environ=None):
    """Explicit environment (including legacy aliases) wins over the shared file."""
    original = dict(os.environ if environ is None else environ)
    home = original.get("HOME", str(Path.home()))
    filename = original.get("APPLE_SIGNING_CONFIG") or str(Path(home) / ".config/apple/signing.env")
    path = Path(expand(filename, original)).expanduser()
    defaults = {}
    if path.is_file():
        for number, line in enumerate(path.read_text().splitlines(), 1):
            try:
                words = shlex.split(line, comments=True)
            except ValueError:
                raise ValueError(f"Invalid quoting in Apple settings at {path}:{number}") from None
            if not words:
                continue
            if words[0] == "export":
                words = words[1:]
            if len(words) != 1 or "=" not in words[0]:
                raise ValueError(f"Expected NAME=value in Apple settings at {path}:{number}")
            name, value = words[0].split("=", 1)
            if name not in SETTINGS:
                raise ValueError(f"Unsupported Apple setting {name} at {path}:{number}")
            if "$(" in value or "`" in value:
                raise ValueError(f"Shell commands are not supported in Apple setting {name}")
            context = dict(defaults, **original)
            context.setdefault("HOME", home)
            raw_value = line.split("=", 1)[1].lstrip()
            defaults[name] = value if raw_value.startswith("'") else expand(value, context)
    elif original.get("APPLE_SIGNING_CONFIG"):
        raise ValueError("APPLE_SIGNING_CONFIG is not a readable settings file: " + str(path))
    result = dict(defaults, **original)
    for canonical, aliases in ALIASES.items():
        value = next((original.get(name) for name in (canonical,) + aliases if original.get(name)), None)
        if value is None:
            value = next((defaults.get(name) for name in (canonical,) + aliases if defaults.get(name)), None)
        if value:
            result[canonical] = value
    if result.get("APPLE_API_KEY_ID") and not result.get("APPLE_API_KEY_PATH"):
        result["APPLE_API_KEY_PATH"] = str(Path(home) / ".appstoreconnect/private_keys" /
                                           ("AuthKey_" + result["APPLE_API_KEY_ID"] + ".p8"))
    for name in ("APPLE_API_KEY_PATH", "KEYCHAIN_PATH", "APPLE_NOTARY_KEYCHAIN"):
        if result.get(name):
            result[name] = str(Path(expand(result[name], result)).resolve())
    # Local releases use Xcode's account even if an old API key is present.
    # CI retains its existing API-key fallback unless explicitly overridden.
    ci = original.get("CI", "").lower() in ("1", "true", "yes")
    result.setdefault("APPLE_PROVISIONING_AUTH", "auto" if ci else "account")
    if result["APPLE_PROVISIONING_AUTH"] not in ("auto", "account", "api-key"):
        raise ValueError("APPLE_PROVISIONING_AUTH must be auto, account or api-key")
    if result.get("APPLE_TEAM_ID") and not re.fullmatch(r"[A-Z0-9]{10}", result["APPLE_TEAM_ID"]):
        raise ValueError("APPLE_TEAM_ID must have 10 uppercase letters/digits")
    # Preserve old entry points while their callers migrate to the canonical names.
    for canonical, aliases in ALIASES.items():
        if result.get(canonical):
            for alias in aliases:
                result.setdefault(alias, result[canonical])
    return result


def validate_api(environment, required=False, check_file=True):
    present = [name for name in API_KEYS if environment.get(name)]
    if not required and not present:
        return
    missing = [name for name in API_KEYS if not environment.get(name)]
    if missing:
        raise ValueError("Set these signing inputs: " + ", ".join(missing))
    if not re.fullmatch(r"[A-Z0-9]{10}", environment["APPLE_API_KEY_ID"]):
        raise ValueError("APPLE_API_KEY_ID must be the 10-character App Store Connect Team Key ID")
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", environment["APPLE_API_ISSUER"]):
        raise ValueError("APPLE_API_ISSUER must be the App Store Connect issuer UUID")
    if check_file and not Path(environment["APPLE_API_KEY_PATH"]).is_file():
        raise ValueError("APPLE_API_KEY_PATH does not point to a readable .p8 file")


def provisioning_arguments(environment, check_file=True):
    args = ["-allowProvisioningUpdates"]
    mode = environment.get("APPLE_PROVISIONING_AUTH", "account")
    if mode == "account":
        return args
    validate_api(environment, required=mode == "api-key", check_file=check_file)
    if environment.get("APPLE_API_KEY_PATH"):
        args += ["-authenticationKeyPath", environment["APPLE_API_KEY_PATH"],
                 "-authenticationKeyID", environment["APPLE_API_KEY_ID"],
                 "-authenticationKeyIssuerID", environment["APPLE_API_ISSUER"]]
    return args


def notary_arguments(environment):
    """Notarization has its own credentials; Xcode account login is insufficient."""
    profile = environment.get("APPLE_NOTARY_PROFILE")
    if profile:
        args = ["--keychain-profile", profile]
        if environment.get("APPLE_NOTARY_KEYCHAIN"):
            args += ["--keychain", environment["APPLE_NOTARY_KEYCHAIN"]]
        return args
    if any(environment.get(name) for name in API_KEYS):
        validate_api(environment, required=True)
        return ["--key", environment["APPLE_API_KEY_PATH"], "--key-id", environment["APPLE_API_KEY_ID"],
                "--issuer", environment["APPLE_API_ISSUER"]]
    if all(environment.get(name) for name in ("APPLE_NOTARY_USER", "APPLE_NOTARY_PASSWORD", "APPLE_TEAM_ID")):
        return ["--apple-id", environment["APPLE_NOTARY_USER"], "--password", environment["APPLE_NOTARY_PASSWORD"],
                "--team-id", environment["APPLE_TEAM_ID"]]
    raise ValueError("Notarization needs APPLE_NOTARY_PROFILE (a saved notarytool Keychain profile), complete API credentials, or APPLE_NOTARY_USER/APPLE_NOTARY_PASSWORD/APPLE_TEAM_ID. Xcode account login alone cannot authenticate notarytool.")


def upload_archive(archive, environment):
    """Explicit upload command; never rebuilds or changes archive metadata."""
    archive = Path(archive).resolve()
    if not archive.is_dir() or not (archive / "Info.plist").is_file():
        raise ValueError("Upload needs an existing .xcarchive with Info.plist: " + str(archive))
    if not environment.get("APPLE_TEAM_ID"):
        raise ValueError("Set APPLE_TEAM_ID before uploading an archive")
    root = Path(__file__).resolve().parents[1]
    contract = root / ".project/commands.json"
    if contract.is_file():
        channel = environment.get("BUILD_CHANNEL", "testflight")
        if channel not in ("testflight", "release"):
            raise ValueError("Upload requires BUILD_CHANNEL=testflight or release")
        subprocess.run([sys.executable, str(root / ".project/projectctl.py"), "--config", str(contract),
                        "artifact-verify", str(archive), "--channel", channel],
                       cwd=root, env=environment, check=True)
    auth = provisioning_arguments(environment)
    options = {"method": "app-store-connect", "destination": "upload", "signingStyle": "automatic",
               "teamID": environment["APPLE_TEAM_ID"], "manageAppVersionAndBuildNumber": False,
               "uploadSymbols": True}
    with tempfile.TemporaryDirectory(prefix="apple-upload-") as directory:
        output = Path(directory)
        plist = output / "ExportOptions.plist"
        plist.write_bytes(plistlib.dumps(options))
        subprocess.run(["xcodebuild", "-exportArchive", "-archivePath", str(archive),
                        "-exportOptionsPlist", str(plist), "-exportPath", str(output / "Upload")] + auth,
                       env=environment, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--json", action="store_true", help="Load settings for a child release process")
    mode.add_argument("--check", action="store_true", help="Check shared settings without building")
    mode.add_argument("--api-check", action="store_true", help="Require API credentials for upload/notarization")
    mode.add_argument("--notary-args", action="store_true", help="Print NUL-separated notarization arguments")
    mode.add_argument("--upload-archive", type=Path, help="Upload an existing App Store archive through Xcode")
    mode.add_argument("--xcode-args", action="store_true", help="Print NUL-separated provisioning arguments")
    mode.add_argument("--exec", nargs=argparse.REMAINDER, dest="command")
    args = parser.parse_args()
    environment = load_environment()
    if args.json:
        print(json.dumps({name: environment[name] for name in SETTINGS if name in environment}))
    elif args.notary_args:
        sys.stdout.write("\0".join(notary_arguments(environment)) + "\0")
    elif args.upload_archive:
        upload_archive(args.upload_archive, environment)
    elif args.xcode_args:
        sys.stdout.write("\0".join(provisioning_arguments(environment)) + "\0")
    elif args.api_check:
        validate_api(environment, required=True)
        print("App Store Connect API settings and key file are available; server permissions still require verification.")
    elif args.check:
        if not environment.get("APPLE_TEAM_ID"):
            raise ValueError("Set these signing inputs: APPLE_TEAM_ID")
        provisioning_arguments(environment)
        print("Shared Apple provisioning settings are available. Xcode must still verify signing permissions and profiles.")
    elif args.command:
        # Catch incomplete API settings before a shell release starts a build.
        if environment.get("APPLE_PROVISIONING_AUTH") != "account":
            provisioning_arguments(environment)
        environment["APPLE_SIGNING_LOADED"] = "1"
        os.execvpe(args.command[0], args.command, environment)
    else:
        parser.error("--exec needs a command")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("Apple signing settings: " + str(error), file=sys.stderr)
        sys.exit(1)
