#!/usr/bin/env python3
"""Copy the shared macOS surface sources into an app, or verify the copy.

Run from an app as `.project/mac_surfaces.py` (through `just surfaces` and the
build). When the standards checkout is reachable, a newer reviewed version is
copied in and shows up as an ordinary diff to commit. When it is not, as in CI
or a contributor's clone, the committed copy is verified against its lock.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

SCHEMA = "mac-surfaces/v1"
LOCK = ".project/mac-surfaces.lock.json"
TOOL = ".project/mac_surfaces.py"
STANDARD = Path("dev") / "standards" / "mac-surfaces"


class SurfaceError(Exception):
    pass


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_files(source):
    return sorted((source / "Sources" / "MacSurfaces").glob("*.swift"))


def build_manifest(source, version):
    return {"schema": SCHEMA, "version": version,
            "tool": digest(source / "sync.py"),
            "files": {path.name: digest(path) for path in source_files(source)}}


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, indent=2) + "\n")


def find_source(root, explicit):
    """The standards checkout, or None when this machine does not have one."""
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    if os.environ.get("MAC_SURFACES_SOURCE"):
        candidates.append(Path(os.environ["MAC_SURFACES_SOURCE"]))
    try:
        common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                cwd=root, capture_output=True, text=True, check=True).stdout.strip()
        candidates.append(Path(common).parent.parent / STANDARD)
    except (OSError, subprocess.CalledProcessError):
        pass
    candidates.append(root.parent / STANDARD)
    for candidate in candidates:
        if (candidate / "manifest.json").is_file():
            return candidate.resolve()
    if explicit:
        raise SurfaceError(f"No manifest.json under {explicit}")
    return None


def verify(root, lock):
    """Problems with the committed copy, as a list of sentences."""
    destination = root / lock["destination"]
    problems = []
    for name, expected in lock["files"].items():
        path = destination / name
        if not path.is_file():
            problems.append(f"{name} is missing")
        elif digest(path) != expected:
            problems.append(f"{name} was edited in this app")
    if destination.is_dir():
        for path in sorted(destination.glob("*.swift")):
            if path.name not in lock["files"]:
                problems.append(f"{path.name} is not part of the standard")
    return problems


def check(root):
    lock_path = root / LOCK
    if not lock_path.is_file():
        raise SurfaceError("No copy recorded; run sync with --destination first")
    lock = read_json(lock_path)
    problems = verify(root, lock)
    if problems:
        raise SurfaceError("The shared surface code has drifted: " + "; ".join(problems)
                           + ". Change the standard, then sync; do not edit the copy.")
    print(f"Mac surfaces: version {lock['version']}, {len(lock['files'])} files verified")


def sync(root, destination, explicit_source, force):
    lock_path = root / LOCK
    lock = read_json(lock_path) if lock_path.is_file() else None
    if destination is None:
        if lock is None:
            raise SurfaceError("First sync needs --destination, the folder in the app that holds the copy")
        destination = lock["destination"]
    source = find_source(root, explicit_source)
    if source is None:
        if lock is None:
            raise SurfaceError("The standards checkout is not on this machine and no copy is recorded")
        print("Mac surfaces: standards checkout not found; using the committed copy")
        return check(root)

    manifest = read_json(source / "manifest.json")
    actual = build_manifest(source, manifest["version"])
    if actual != manifest:
        raise SurfaceError("The standards checkout has changes that manifest.json does not record; "
                           "run `python3 sync.py manifest --bump` there")

    if lock is not None:
        problems = verify(root, dict(lock, destination=lock["destination"]))
        if problems and not force:
            raise SurfaceError("The shared surface code has drifted: " + "; ".join(problems)
                               + ". Change the standard, then sync (or pass --force to discard the edits).")
        if manifest["version"] < lock["version"]:
            print(f"Mac surfaces: checkout has version {manifest['version']}, older than this app's "
                  f"{lock['version']}; keeping the committed copy")
            return
        same = manifest["files"] == lock["files"] and destination == lock["destination"]
        if same and not problems and manifest["tool"] == lock.get("tool"):
            print(f"Mac surfaces: version {lock['version']}, up to date")
            return
        if manifest["version"] == lock["version"] and manifest["files"] != lock["files"]:
            raise SurfaceError("The standard changed without a version bump; "
                               "run `python3 sync.py manifest --bump` in the standards checkout")

    target = root / destination
    target.mkdir(parents=True, exist_ok=True)
    previous = set(lock["files"]) if lock else set()
    old_target = root / lock["destination"] if lock else target
    for name in previous - set(manifest["files"]):
        (old_target / name).unlink(missing_ok=True)
    if lock and old_target != target:
        for name in previous & set(manifest["files"]):
            (old_target / name).unlink(missing_ok=True)
    for path in source_files(source):
        shutil.copyfile(path, target / path.name)
    tool = root / TOOL
    if not tool.is_file() or digest(tool) != manifest["tool"]:
        tool.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / "sync.py", tool)
    write_json(lock_path, {"schema": SCHEMA, "version": manifest["version"], "destination": destination,
                           "tool": manifest["tool"], "files": manifest["files"]})
    print(f"Mac surfaces: copied version {manifest['version']} ({len(manifest['files'])} files) "
          f"into {destination}; review and commit the change")


def write_manifest(source, bump):
    path = source / "manifest.json"
    version = read_json(path)["version"] if path.is_file() else 0
    current = build_manifest(source, version)
    if path.is_file() and current == read_json(path):
        print(f"Mac surfaces: manifest is current at version {version}")
        return
    if not bump and path.is_file():
        raise SurfaceError("Sources changed; rerun with --bump to publish them as a new version")
    write_json(path, build_manifest(source, version + 1))
    print(f"Mac surfaces: manifest written, version {version + 1}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["sync", "check", "manifest"])
    parser.add_argument("--root", default=".", help="the app checkout (default: current directory)")
    parser.add_argument("--destination", help="folder in the app for the copy, relative to the root")
    parser.add_argument("--source", help="the standard's folder; found automatically when omitted")
    parser.add_argument("--force", action="store_true", help="discard edits made to the copy")
    parser.add_argument("--bump", action="store_true", help="manifest: publish changed sources as a new version")
    options = parser.parse_args(argv)
    try:
        if options.action == "manifest":
            write_manifest(Path(options.source or Path(__file__).parent).resolve(), options.bump)
        elif options.action == "check":
            check(Path(options.root).resolve())
        else:
            sync(Path(options.root).resolve(), options.destination, options.source, options.force)
    except (SurfaceError, OSError, ValueError, KeyError) as error:
        print("Mac surfaces failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
