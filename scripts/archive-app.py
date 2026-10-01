#!/usr/bin/env python3
"""Regenerate if needed, archive with Xcode's normal version capture, then verify it.

This command creates an archive only. Export and upload remain separate actions.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from apple_signing import load_environment, provisioning_arguments

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--platform")
parser.add_argument("--channel", choices=["local", "ci", "testflight", "release"],
                    default=os.environ.get("BUILD_CHANNEL") or "release")
parser.add_argument("--unsigned", action="store_true", help="Validate an archive without a signing identity")
parser.add_argument("--plan", action="store_true", help="Print the commands without running them")
args = parser.parse_args()
try:
    environment = dict(os.environ) if args.unsigned else load_environment()
except ValueError as error:
    parser.error(str(error))
config = json.loads((root / "Config/ArchiveTargets.json").read_text())
platform = args.platform or config["defaultPlatform"]
if platform not in config["platforms"]:
    parser.error(f"Choose a supported platform: {', '.join(config['platforms'])}")
target = config["platforms"][platform]
commands = []
if config.get("spec"):
    commands.append(["xcodegen", "generate", "--spec", config["spec"]])
archive = root / "build" / (target["scheme"] + "-" + platform + ".xcarchive")
command = ["xcodebuild", "archive", "-project", config["project"], "-scheme", target["scheme"],
           "-configuration", "Release", "-destination", target["destination"], "-archivePath", str(archive)]
# Xcode's xcconfig values override environment variables. Pass the channel as
# a build setting so its shared scheme captures the explicitly chosen identity.
command.append("BUILD_CHANNEL=" + args.channel)
if args.unsigned:
    command.append("CODE_SIGNING_ALLOWED=NO")
else:
    try:
        command.extend(provisioning_arguments(environment, check_file=not args.plan))
    except ValueError as error:
        parser.error(str(error))
    team = next((environment[name] for name in ("APPLE_TEAM_ID", "TEAM_ID", "FASTLANE_TEAM_ID")
                 if environment.get(name)), "")
    if team:
        if not re.fullmatch(r"[A-Z0-9]{10}", team):
            parser.error("Apple team ID must have 10 uppercase letters/digits")
        command.append("DEVELOPMENT_TEAM=" + team)
    if environment.get("APPLE_SIGNING_IDENTITY"):
        command.append("CODE_SIGN_IDENTITY=" + environment["APPLE_SIGNING_IDENTITY"])
    if environment.get("KEYCHAIN_PATH"):
        command.append("OTHER_CODE_SIGN_FLAGS=--keychain " + json.dumps(environment["KEYCHAIN_PATH"]))
commands.append(command)
commands.append(["python3", str(Path(__file__).with_name("verify-archive.py")), str(archive)])
if args.plan:
    print(json.dumps(commands, indent=2))
else:
    env = dict(environment, BUILD_CHANNEL=args.channel)
    for command in commands:
        subprocess.run(command, cwd=root, env=env, check=True)
    print(f"Archive ready: {archive}")
