#!/usr/bin/env python3
"""Local, dependency-free project command contract. Adapters are argv, never shell."""
import argparse
import ast
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import zipfile

SCHEMA = "project-commands/v1"
VERSION = re.compile(r"\d+\.\d+(?:\.\d+)?\Z")
CORE = {"help", "info", "doctor", "setup", "clean", "check"}
EFFECTS = {"deploy", "db-migrate", "worker-deploy", "worker-secret-google", "worker-secret-apple", "rollback"}
SECRET = re.compile(rb"(?m)^(?:-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)|\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{70,}|AKIA[A-Z0-9]{16})\b")

class ContractError(Exception):
    pass

def call(argv, root, env=None, capture=False):
    result = subprocess.run([str(x) for x in argv], cwd=root, env=env,
                            text=True, capture_output=capture)
    if result.returncode:
        # Child diagnostics are retained, but argv may contain credentials.
        raise ContractError(f"{Path(str(argv[0])).name} failed (exit {result.returncode})" +
                            (": " + result.stderr.strip() if capture and result.stderr else ""))
    return result.stdout if capture else ""

def git(root, *args):
    return call(["git", *args], root, capture=True).strip()

def source(root):
    sha = git(root, "rev-parse", "HEAD")
    branch = subprocess.run(["git", "symbolic-ref", "--short", "-q", "HEAD"], cwd=root,
                            text=True, capture_output=True).stdout.strip() or "detached"
    changes = git(root, "status", "--porcelain", "--untracked-files=all")
    tags = git(root, "tag", "--points-at", "HEAD").splitlines()
    return {"sha": sha, "branch": branch, "dirty": bool(changes),
            "dirty_files": changes.splitlines(), "tags": tags,
            "event": os.environ.get("GITHUB_EVENT_NAME", "local"),
            "ref": os.environ.get("GITHUB_REF", "")}

def digest(path):
    path = Path(path)
    files = sorted(path.rglob("*")) if path.is_dir() else [path]
    value = hashlib.sha256()
    for item in files:
        if item.is_symlink():
            value.update(str(item.relative_to(path)).encode() + b"\0" + os.readlink(item).encode())
        elif item.is_file():
            value.update((str(item.relative_to(path)) if path.is_dir() else path.name).encode() + b"\0")
            with item.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    value.update(chunk)
    return value.hexdigest()

def bundle_info(artifact):
    artifact = Path(artifact)
    if artifact.suffix == ".xcarchive":
        props = plistlib.loads((artifact / "Info.plist").read_bytes())["ApplicationProperties"]
        app = artifact / "Products" / props["ApplicationPath"]
    elif artifact.suffix == ".app":
        app = artifact
        props = None
    elif artifact.suffix == ".ipa":
        with zipfile.ZipFile(artifact) as z:
            paths = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info.plist", n)]
            if len(paths) != 1:
                raise ContractError("IPA must contain exactly one main app")
            main = plistlib.loads(z.read(paths[0]))
            embedded = [plistlib.loads(z.read(n)) for n in z.namelist()
                        if ".appex/" in n and n.endswith("/Info.plist") and "/Frameworks/" not in n]
        verify_identity(main, embedded)
        return main
    else:
        raise ContractError("Artifact identity requires an .xcarchive, .app or .ipa")
    def info(bundle):
        file = bundle / "Contents/Info.plist"
        return plistlib.loads((file if file.exists() else bundle / "Info.plist").read_bytes())
    main = info(app)
    embedded = [info(x) for pattern in ("*.appex", "*.app", "*.xpc") for x in app.rglob(pattern)
                if "Frameworks" not in x.relative_to(app).parts]
    verify_identity(main, embedded)
    if props and any(props.get(k) != main[k] for k in ("CFBundleVersion", "CFBundleShortVersionString")):
        raise ContractError("Organizer and app versions differ")
    return main

def verify_identity(main, embedded):
    stamp = main.get("CFBundleVersion", "")
    timestamp = main.get("BuildTimestamp", "")
    try:
        expected = datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ").strftime("%Y.%m%d.%H%M")
    except ValueError:
        raise ContractError("Artifact lacks a valid UTC build timestamp")
    if stamp != expected or not VERSION.fullmatch(main.get("CFBundleShortVersionString", "")):
        raise ContractError("Artifact marketing version or UTC build stamp is invalid")
    fields = ("CFBundleVersion", "CFBundleShortVersionString", "BuildTimestamp", "BuildChannel", "BuildDirty", "BuildTagged")
    for item in embedded:
        if any(item.get(k) != main.get(k) for k in fields):
            raise ContractError("An embedded target has a different build identity")
    for item in [main, *embedded]:
        if item.get("BuildChannel") == "release" and any(item.get(k) for k in
                ("BuildSHA", "BuildBranch", "BuildDescribe", "BuildDiffID")):
            raise ContractError("Release artifact contains internal repository details")

class Project:
    def __init__(self, config, root=None):
        self.path = Path(config).resolve()
        self.root = Path(root).resolve() if root else self.path.parent.parent
        self.config = json.loads(self.path.read_text())
        if self.config.get("schema") != SCHEMA:
            raise ContractError("Unsupported project command schema")
        if not CORE <= set(self.config.get("commands", {})):
            raise ContractError("Project must declare all six core commands")
        if not self.config.get("targets"):
            raise ContractError("Declare at least one supported target")
        for name, detail in self.config["commands"].items():
            if detail.get("alias") and detail["alias"] not in self.config["commands"]:
                raise ContractError("Alias has no supported destination: " + name)
        self.output = self.root / ".project/output"

    def path_in_root(self, value):
        path = (self.root / value).resolve()
        if not path.is_relative_to(self.root):
            raise ContractError("Configured path escapes the checkout")
        return path

    def version(self):
        file = self.path_in_root(self.config["version_file"])
        if file.suffix == ".json":
            value = json.loads(file.read_text())["version"]
        elif file.name == "Cargo.toml":
            section = re.search(r"(?ms)^\[" + re.escape(self.config.get("version_section", "package")) + r"\]\s*\n(.*?)(?=^\[|\Z)", file.read_text())
            match = re.search(r'(?m)^version\s*=\s*"([0-9.]+)"', section[1] if section else "")
            if not match: raise ContractError("Cargo marketing version needs one literal source declaration")
            value = match[1]
        elif self.config.get("version_format") == "plain":
            value = file.read_text().strip()
        else:
            match = re.search(r"(?m)^MARKETING_VERSION\s*=\s*([0-9.]+)\s*$", file.read_text())
            if not match:
                raise ContractError("Marketing version is not declared once in source")
            value = match[1]
        if not VERSION.fullmatch(value):
            raise ContractError("Marketing version must be numeric X.Y or X.Y.Z")
        return value

    def target(self, options):
        name = options.target
        if name == "default":
            name = self.config.get("default_target", "app")
        if name not in self.config.get("targets", {}):
            raise ContractError("Unsupported target: " + name)
        return name, self.config["targets"][name]

    def adapter(self, action, options):
        name, target = self.target(options)
        spec = target.get("actions", {}).get(action)
        if spec is None:
            raise ContractError(f"{action} is unsupported for target {name}")
        values = vars(options).copy()
        values["target"] = name
        values["root"] = str(self.root)
        values["platform"] = self.platform(options)
        # Only explicitly declared environments can reach remote actions.
        if action in EFFECTS:
            self.remote_environment(options, target)
        values["environment"] = target.get("environment_aliases", {}).get(options.environment, options.environment)
        captured = None
        if action in ("build", "deploy-check") and target.get("artifact"):
            current = source(self.root)
            now = datetime.now(timezone.utc)
            captured = {"version": self.version(), "build": now.strftime("%Y.%m%d.%H%M"),
                        "timestamp": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "channel": options.channel}
        for step in spec:
            argv = []
            for item in step["argv"]:
                if item == "{extra}": argv.extend(shlex.split(options.value))
                else: argv.append(str(item).format_map(values))
            cwd = self.path_in_root(step.get("cwd", "."))
            env = dict(os.environ, BUILD_CHANNEL=options.channel)
            if captured:
                env.update(BUILD_NUMBER=captured["build"], BUILD_TIMESTAMP=captured["timestamp"], MARKETING_VERSION=captured["version"])
            call(argv, cwd, env=env)
        if captured:
            artifact = self.path_in_root(target["artifact"])
            if not artifact.exists(): raise ContractError("Declared build artifact was not produced")
            metadata = artifact / "buildinfo.json" if artifact.is_dir() else Path(str(artifact) + ".buildinfo.json")
            metadata.write_text(json.dumps(captured, indent=2) + "\n")
            manifest = dict(captured, schema="project-artifact/v1", kind="generic", source=current,
                            artifact=str(artifact), sha256=digest(artifact))
            Path(str(artifact) + ".project.json").write_text(json.dumps(manifest, indent=2) + "\n")

    def platform(self, options):
        name, target = self.target(options)
        platforms = target.get("platforms", {})
        chosen = options.platform
        if chosen in ("default", "all"):
            chosen = target.get("default_platform", "none")
        if platforms and chosen not in platforms:
            raise ContractError("Unsupported platform: " + chosen)
        if not platforms and chosen != "none":
            raise ContractError("This target does not support a platform override: " + name)
        return chosen

    def remote_environment(self, options, target=None):
        target = target or self.target(options)[1]
        if not options.environment:
            raise ContractError("Choose environment explicitly; production is never the default")
        if options.environment not in target.get("environments", {}):
            raise ContractError("Unsupported remote environment: " + options.environment)
        destination = target["environments"][options.environment]
        print(f"External action: {options.command}; environment={options.environment}; destination={destination}", flush=True)

    def check_ci(self, sha):
        repo = git(self.root, "remote", "get-url", "origin")
        match = re.search(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", repo)
        if not match:
            raise ContractError("Cannot identify CI repository")
        repository = match[1]
        checks = json.loads(call(["gh", "api", "--paginate", "--slurp",
            f"repos/{repository}/commits/{sha}/check-runs?per_page=100&filter=latest"], self.root, capture=True))
        statuses = json.loads(call(["gh", "api", "--paginate", "--slurp",
            f"repos/{repository}/commits/{sha}/statuses?per_page=100"], self.root, capture=True))
        results = {}
        for page in checks:
            for check in page["check_runs"]:
                results[check["name"]] = check.get("conclusion") if check["status"] == "completed" else "pending"
        for page in statuses:
            for status in page:
                results.setdefault(status["context"], status["state"])
        required = list(self.config.get("release", {}).get("required_checks", []))
        branch = json.loads(call(["gh", "api", f"repos/{repository}/branches/{self.config.get('default_branch', 'main')}"], self.root, capture=True))
        if branch.get("protected"):
            protection = json.loads(call(["gh", "api", f"repos/{repository}/branches/{self.config.get('default_branch', 'main')}/protection/required_status_checks"], self.root, capture=True))
            required.extend(protection.get("contexts", []))
            required.extend(x['context'] for x in protection.get('checks', []))
        if not required:
            raise ContractError("Public releases require an explicit list of required CI checks")
        failed = [name + ": " + str(results.get(name, "missing")) for name in required if results.get(name) != "success"]
        if failed:
            raise ContractError("Required CI at " + sha + ": " + "; ".join(failed))

    def eligibility(self, channel, phase="publish", ci=True):
        current = source(self.root)
        if channel not in ("release", "testflight"):
            return current
        if current["dirty"]:
            raise ContractError("Publication requires a clean checkout (tracked and untracked files)")
        chosen = "v" + self.version()
        beta = self.config.get("release", {}).get("allow_untagged_beta", False)
        if phase == "publish" and (channel == "release" or not beta):
            if chosen not in current["tags"]:
                raise ContractError("Publication requires the matching tag " + chosen + " at this exact commit")
            if git(self.root, "cat-file", "-t", "refs/tags/" + chosen) != "tag":
                raise ContractError("Release tag must be annotated")
        if channel == "release" and ci:
            self.check_ci(current["sha"])
        return current

    def record(self, artifact, current):
        artifact = Path(artifact).resolve()
        main = bundle_info(artifact)
        dirty = str(main.get("BuildDirty", "")).lower() in ("yes", "true", "1")
        if dirty != current["dirty"]:
            raise ContractError("Source changed during compilation; build record and artifact dirty state differ")
        if main.get("BuildSHA") and not current["sha"].startswith(main["BuildSHA"]):
            raise ContractError("Artifact identifies another source commit")
        manifest = {"schema": "project-artifact/v1", "source": current,
                    "artifact": str(artifact), "sha256": digest(artifact),
                    "version": main["CFBundleShortVersionString"], "build": main["CFBundleVersion"],
                    "timestamp": main["BuildTimestamp"], "channel": main["BuildChannel"]}
        sidecar = Path(str(artifact) + ".project.json")
        sidecar.write_text(json.dumps(manifest, indent=2) + "\n")
        return manifest

    def verify(self, artifact, channel="local"):
        artifact = Path(artifact).resolve()
        if artifact.suffix not in (".xcarchive", ".app", ".ipa"):
            sidecar = Path(str(artifact) + ".project.json")
            if not sidecar.is_file(): raise ContractError("Generic artifact requires its original build record")
            manifest = json.loads(sidecar.read_text())
            metadata = artifact / "buildinfo.json" if artifact.is_dir() else Path(str(artifact) + ".buildinfo.json")
            identity = json.loads(metadata.read_text())
            if manifest.get("kind") != "generic" or manifest["sha256"] != digest(artifact):
                raise ContractError("Generic artifact changed after compilation")
            if any(manifest[k] != identity.get(k) for k in ("version", "build", "timestamp", "channel")):
                raise ContractError("Generic artifact identity differs from its build record")
            if datetime.strptime(identity["timestamp"], "%Y-%m-%dT%H:%M:%SZ").strftime("%Y.%m%d.%H%M") != identity["build"]:
                raise ContractError("Generic artifact has an invalid UTC stamp")
            if channel in ("testflight", "release"):
                current = self.eligibility(channel)
                if manifest["source"]["dirty"] or manifest["source"]["sha"] != current["sha"]:
                    raise ContractError("Generic artifact was built from dirty or different source")
                if channel == "release" and identity["channel"] != "release":
                    raise ContractError("Public artifact must use the release channel")
            print("Generic artifact verified: " + identity["version"] + " (" + identity["build"] + ")")
            return identity
        main = bundle_info(artifact)
        if artifact.suffix == ".xcarchive" and self.config.get("apple", {}).get("product"):
            props = plistlib.loads((artifact / "Info.plist").read_bytes())["ApplicationProperties"]
            if Path(props["ApplicationPath"]).name != self.config["apple"]["product"]:
                raise ContractError("Artifact is not the declared project product")
        sidecar = Path(str(artifact) + ".project.json")
        if sidecar.exists():
            manifest = json.loads(sidecar.read_text())
            if manifest["sha256"] != digest(artifact):
                raise ContractError("Artifact changed after its build record was captured")
            if manifest["version"] != main["CFBundleShortVersionString"] or manifest["build"] != main["CFBundleVersion"]:
                raise ContractError("Artifact and manifest identity differ")
        elif channel in ("testflight", "release"):
            raise ContractError("Publication requires the original private artifact build record; archive again through the standard command")
        else:
            manifest = None
        if channel in ("testflight", "release"):
            current = self.eligibility(channel)
            if manifest["source"]["dirty"] or manifest["source"]["sha"] != current["sha"]:
                raise ContractError("Artifact was built from dirty or different source")
            if str(main.get("BuildDirty", "")).lower() not in ("0", "false", "no"):
                raise ContractError("Artifact identifies dirty source")
            if channel == "release" and str(main.get("BuildTagged", "")).lower() not in ("1", "true", "yes"):
                raise ContractError("Public artifact was not built from a tagged source")
            if channel == "release" and main.get("BuildChannel") != "release":
                raise ContractError("Public artifact must use the release channel and redact internal metadata")
        print(f"Artifact verified: {main['CFBundleShortVersionString']} ({main['CFBundleVersion']})", flush=True)
        return main

    def apple(self):
        if not self.config.get("apple"):
            raise ContractError("This project has no Apple adapter")
        return self.config["apple"]

    def apple_module(self):
        file = self.root / self.apple()["scripts"] / "apple_signing.py"
        spec = importlib.util.spec_from_file_location("project_apple_signing", file)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def generate(self):
        apple = self.apple()
        config = json.loads((self.root / apple["archive_config"]).read_text())
        if config.get("spec"):
            call(["xcodegen", "generate", "--spec", config["spec"]], self.root)

    def build(self, options):
        name, target = self.target(options)
        if target.get("kind") == "swiftpm":
            return self.swiftpm(options, "build")
        if target.get("kind") != "apple":
            return self.adapter("build", options)
        self.generate()
        ac = json.loads((self.root / self.apple()["archive_config"]).read_text())
        selected = list(ac["platforms"]) if options.platform in ("default", "all") else [self.platform(options)]
        env = dict(os.environ, BUILD_CHANNEL=options.channel)
        settings = call(["bash", str(self.root / self.apple()["scripts"] / "buildinfo.sh")], self.root, env=env, capture=True).splitlines()
        call(["bash", str(self.root / self.apple()["scripts"] / "banner.sh"), self.config["name"]], self.root,
             env=dict(env, BUILD_INFO="\n".join(settings)))
        for platform in selected:
            item = ac["platforms"][platform]
            destination = item["destination"].replace("platform=iOS", "platform=iOS Simulator").replace("platform=tvOS", "platform=tvOS Simulator")
            call(["xcodebuild", "-project", ac["project"], "-scheme", item["scheme"],
                  "-configuration", "Debug", "-destination", destination,
                  "-derivedDataPath", str(self.output / ("build-" + platform)),
                  "CODE_SIGNING_ALLOWED=NO", *settings, "build"], self.root, env=env)

    def swiftpm(self, options, operation):
        name, target = self.target(options)
        paths = []
        for pattern in target.get("package_paths", []):
            candidates = [self.root] if pattern == "." else self.root.glob(pattern)
            paths.extend(x for x in candidates if (x / "Package.swift").is_file())
        if options.package:
            paths = [x for x in paths if x.name == options.package]
        if not paths:
            raise ContractError("No declared Swift packages match the selection")
        failures = []
        for path in sorted(set(paths)):
            if not path.resolve().is_relative_to(self.root):
                raise ContractError("Package escapes the checkout")
            print(f"Swift package {operation}: {path.relative_to(self.root)}", flush=True)
            try:
                argv = ["swift", operation, "--package-path", str(path)] if operation != "resolve" else ["swift", "package", "--package-path", str(path), "resolve"]
                if operation == "test" and options.filter: argv.extend(["--filter", options.filter])
                call(argv, self.root)
            except ContractError:
                failures.append(str(path.relative_to(self.root)))
        if failures: raise ContractError("Failing Swift packages: " + ", ".join(failures))

    def archive(self, options):
        if self.target(options)[1].get("kind") != "apple":
            raise ContractError("Archive requires an Apple app target")
        platform = self.platform(options)
        apple = self.apple()
        current = source(self.root)
        cmd = ["python3", str(self.root / apple["scripts"] / "archive-app.py"), "--platform", platform,
               "--channel", options.channel]
        if options.unsigned:
            cmd.append("--unsigned")
        if options.plan:
            cmd.append("--plan")
        call(cmd, self.root, env=dict(os.environ, BUILD_CHANNEL=options.channel))
        ac = json.loads((self.root / apple["archive_config"]).read_text())
        artifact = self.root / "build" / (ac["platforms"][platform]["scheme"] + "-" + platform + ".xcarchive")
        if not options.plan:
            self.record(artifact, current)
        return artifact

    def export(self, options, artifact):
        artifact = Path(artifact).resolve()
        self.verify(artifact)
        module = self.apple_module()
        env = module.load_environment()
        team = env.get("APPLE_TEAM_ID", "")
        if not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise ContractError("Export requires APPLE_TEAM_ID in the shared signing configuration")
        options_file = self.output / ("export-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
        options_file.mkdir(parents=True, exist_ok=False)
        value = {"method": self.config.get("release", {}).get("export_method", "app-store-connect"),
                 "destination": "export", "teamID": team, "signingStyle": "automatic",
                 "manageAppVersionAndBuildNumber": False, "uploadSymbols": True}
        file = options_file / "ExportOptions.plist"
        file.write_bytes(plistlib.dumps(value))
        before = digest(artifact)
        call(["xcodebuild", "-exportArchive", "-archivePath", str(artifact),
              "-exportOptionsPlist", str(file), "-exportPath", str(options_file / "Export"),
              *module.provisioning_arguments(env)], self.root, env=env)
        if digest(artifact) != before:
            raise ContractError("Export modified the original archive")
        outputs = list((options_file / "Export").rglob("*.ipa")) + list((options_file / "Export").rglob("*.pkg")) + list((options_file / "Export").rglob("*.app"))
        if not outputs:
            raise ContractError("Export produced no distribution artifact")
        for output in outputs:
            if output.suffix in (".ipa", ".app"):
                exported = bundle_info(output)
                original = bundle_info(artifact)
                if any(exported.get(k) != original.get(k) for k in ("CFBundleVersion", "CFBundleShortVersionString", "BuildTimestamp")):
                    raise ContractError("Export changed the captured build identity")
                sidecar = Path(str(artifact) + ".project.json")
                if sidecar.is_file(): self.record(output, json.loads(sidecar.read_text())["source"])
        print("Export ready: " + str(options_file / "Export"))
        return options_file

    def docs_check(self):
        files = self.config.get("documentation", ["docs/PROJECT-COMMANDS.md"])
        count = 0
        for value in files:
            path = self.path_in_root(value)
            if not path.is_file():
                raise ContractError("Declared documentation is missing: " + value)
            text = path.read_text()
            if not self.config.get("private", False) and re.search(r"https://github\.com/[^/]+/dev(?:/|\b)|portfolio-build-(?:audit|rollout)|BUILD-COMMANDS\.md", text):
                raise ContractError("Public documentation contains a private development reference: " + value)
            for dest in re.findall(r"\[[^\]]*\]\(([^\s)]+)\)", text):
                if re.match(r"[a-z]+:|#", dest):
                    continue
                target = (path.parent / dest.split("#", 1)[0]).resolve()
                if not target.exists():
                    raise ContractError("Broken local documentation link in " + value + ": " + dest)
            count += 1
        print(f"Documentation checked: {count} declared files; local links and visibility policy (remote links not fetched)")

    def security_check(self):
        files = git(self.root, "ls-files", "-z").split("\0")
        findings = []
        scanned = 0
        fixtures = {(x["path"], x["sha256"]) for x in self.config.get("credential_fixtures", [])}
        for filename in files:
            if not filename:
                continue
            path = self.root / filename
            if not path.is_file() or path.is_symlink() or path.stat().st_size > 2 * 1024 * 1024:
                continue
            data = path.read_bytes()
            if b"\0" in data:
                continue
            scanned += 1
            for match in SECRET.finditer(data):
                sample = match[0]
                if sample.startswith(b"-----BEGIN"):
                    end = re.search(rb"-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", data[match.end():])
                    sample = data[match.start():match.end() + end.end()] if end else data[match.start():]
                fingerprint = hashlib.sha256(sample).hexdigest()
                if (filename, fingerprint) not in fixtures:
                    findings.append(filename + ":" + str(data[:match.start()].count(b"\n") + 1))
        if findings:
            raise ContractError("Potential committed credentials (values redacted): " + ", ".join(findings))
        print(f"Security checked: {scanned} tracked text files <=2 MiB for credential patterns; dependency/code audits are separate declared adapters")

    def lint(self):
        git(self.root, "diff", "--check")
        for filename in [".project/projectctl.py", ".project/tests/test_projectctl.py"]:
            if (self.root / filename).exists():
                ast.parse((self.root / filename).read_text(), filename=filename)
        self.target(argparse.Namespace(target="default"))
        lock = self.root / ".project/runtime.lock.json"
        if lock.is_file():
            for name, expected in json.loads(lock.read_text())["files"].items():
                if hashlib.sha256((self.root / ".project" / name).read_bytes()).hexdigest() != expected:
                    raise ContractError("Vendored runtime changed without refreshing its reviewed lock: " + name)
        print("Lint checked: command configuration, Python syntax and diff whitespace")

    def clean(self):
        tracked = set(git(self.root, "ls-files", "-z").split("\0"))
        for value in self.config.get("clean", [".project/output"]):
            path = self.path_in_root(value)
            relative = str(path.relative_to(self.root))
            if path == self.root or any(x == relative or x.startswith(relative + "/") for x in tracked):
                raise ContractError("Refusing to clean tracked source: " + value)
            if path.is_dir():
                shutil.rmtree(path)
            elif path.exists():
                path.unlink()
        print("Removed declared reproducible outputs; archive/release evidence retained")

    def changelog(self):
        path = self.path_in_root(self.config.get("changelog", "CHANGELOG.md"))
        text = path.read_text()
        version = self.version()
        match = re.search(r"(?ms)^## \[?" + re.escape(version) + r"\]?(?:[^\n]*)\n(.*?)(?=^## |\Z)", text)
        if not match or not match[1].strip():
            raise ContractError("Approved release notes are missing for " + version + "; supply them with just version")
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "changelog.md").write_text("## " + version + "\n\n" + match[1].strip() + "\n")
        print("Release notes prepared: " + str(self.output / "changelog.md"))

    def change_version(self, options):
        chosen = options.value
        if not VERSION.fullmatch(chosen):
            raise ContractError("Choose an explicit numeric marketing version")
        if not options.notes:
            raise ContractError("Supply an approved release-notes file: just version VERSION NOTES_FILE")
        notes = Path(options.notes).read_text().strip()
        if not notes:
            raise ContractError("Release notes cannot be empty")
        file = self.path_in_root(self.config["version_file"])
        if file.suffix == ".json":
            data = json.loads(file.read_text()); data["version"] = chosen
            revised = json.dumps(data, indent=2) + "\n"
        elif file.name == "Cargo.toml":
            original = file.read_text()
            section = re.search(r"(?ms)^\[" + re.escape(self.config.get("version_section", "package")) + r"\]\s*\n(.*?)(?=^\[|\Z)", original)
            if not section: raise ContractError("Cargo version section is missing")
            updated, count = re.subn(r'(?m)^(version\s*=\s*)"[0-9.]+"', r'\g<1>"' + chosen + '"', section[1])
            if count != 1: raise ContractError("Cargo marketing version must have one literal declaration")
            revised = original[:section.start(1)] + updated + original[section.end(1):]
        elif self.config.get("version_format") == "plain":
            revised = chosen + "\n"
        else:
            revised, count = re.subn(r"(?m)^MARKETING_VERSION\s*=\s*[0-9.]+\s*$", "MARKETING_VERSION = " + chosen, file.read_text())
            if count != 1:
                raise ContractError("Marketing version must have one source declaration")
        log = self.path_in_root(self.config.get("changelog", "CHANGELOG.md"))
        old = log.read_text() if log.exists() else "# Changelog\n"
        if re.search(r"(?m)^## \[?" + re.escape(chosen) + r"\]?(?:\s|$)", old):
            raise ContractError("Release notes already contain this version; review the existing entry")
        file.write_text(revised)
        log.write_text("# Changelog\n\n## " + chosen + "\n\n" + notes + "\n\n" + re.sub(r"\A# Changelog\s*", "", old))
        print("Marketing version and release notes updated; review and commit the changes before release")

    def screenshot(self, options):
        if not options.state or not options.value or options.width < 1 or options.height < 1:
            raise ContractError("Supply a prepared sample state, pixel size and explicit simulator UUID or Mac window ID: just state=sample width=1320 height=2868 screenshot DEVICE_OR_WINDOW")
        platform = self.platform(options)
        directory = self.output / "screenshots" / platform
        directory.mkdir(parents=True, exist_ok=True)
        output = directory / (re.sub(r"[^A-Za-z0-9_-]", "_", options.state) + ".png")
        if platform == "macos":
            if not options.value.isdigit():
                raise ContractError("macOS screenshot requires the app window's numeric window ID")
            call(["screencapture", "-x", "-l", options.value, str(output)], self.root)
        else:
            if not re.fullmatch(r"[A-Fa-f0-9-]{36}", options.value):
                raise ContractError("Screenshot requires an explicit simulator UUID")
            call(["xcrun", "simctl", "io", options.value, "screenshot", str(output)], self.root)
        if not output.is_file():
            raise ContractError("Screenshot was not created")
        data = output.read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n' or (int.from_bytes(data[16:20], 'big'), int.from_bytes(data[20:24], 'big')) != (options.width, options.height):
            raise ContractError("Screenshot pixel size differs from the declared capture size")
        (output.with_suffix(".json")).write_text(json.dumps({"platform": platform, "declared_sample_state": options.state,
            "device_or_window": options.value, "width": options.width, "height": options.height,
            "sha256": digest(output), "source": source(self.root)}, indent=2) + "\n")
        print("Screenshot captured with its declared sample-state record: " + str(output))

    def dev(self, options):
        name, target = self.target(options)
        platform = self.platform(options)
        if "dev" in target.get("actions", {}) and platform in target.get("dev_platforms", [platform]):
            return self.adapter("dev", options)
        if target.get("kind") != "apple":
            raise ContractError("No development launcher for target " + name)
        if platform != "macos" and not re.fullmatch(r"[A-Fa-f0-9-]{36}", options.value):
            raise ContractError("Native simulator launch requires a device UUID: just platform=ios dev UUID")
        self.build(options)
        ac = json.loads((self.root / self.apple()["archive_config"]).read_text())
        destination = ac["platforms"][platform]["destination"].replace("platform=iOS", "platform=iOS Simulator").replace("platform=tvOS", "platform=tvOS Simulator")
        settings = json.loads(call(["xcodebuild", "-project", ac["project"], "-scheme", ac["platforms"][platform]["scheme"],
            "-configuration", "Debug", "-destination", destination,
            "-derivedDataPath", str(self.output / ("build-" + platform)), "-showBuildSettings", "-json"], self.root, capture=True))
        apps = [x["buildSettings"] for x in settings if x["buildSettings"].get("FULL_PRODUCT_NAME", "").endswith(".app")]
        if len(apps) != 1: raise ContractError("Could not identify exactly one runnable app")
        settings = apps[0]
        app = Path(settings["BUILT_PRODUCTS_DIR"]) / settings["FULL_PRODUCT_NAME"]
        if platform == "macos":
            call(["open", "-n", str(app)], self.root)
        else:
            devices = json.loads(call(["xcrun", "simctl", "list", "devices", "--json"], self.root, capture=True))
            selected = [x for xs in devices["devices"].values() for x in xs if x["udid"] == options.value and x.get("isAvailable")]
            if len(selected) != 1: raise ContractError("Selected simulator is unavailable")
            if selected[0]["state"] != "Booted": call(["xcrun", "simctl", "boot", options.value], self.root)
            call(["xcrun", "simctl", "bootstatus", options.value, "-b"], self.root)
            call(["xcrun", "simctl", "install", options.value, str(app)], self.root)
            call(["xcrun", "simctl", "launch", options.value, settings["PRODUCT_BUNDLE_IDENTIFIER"]], self.root)

    def run(self, options):
        command = options.command
        if command not in self.config["commands"]:
            raise ContractError("Unsupported command: " + command)
        spec = self.config["commands"][command]
        for key, value in spec.get("defaults", {}).items():
            if key == "target" or getattr(options, key) in ("", "default"):
                setattr(options, key, value)
        if spec.get("platforms"):
            if options.platform in ("default", "all"):
                options.platform = spec["platforms"][0]
            elif options.platform not in spec["platforms"]:
                raise ContractError(command + " only supports: " + ", ".join(spec["platforms"]))
        if spec.get("alias"):
            options.command = spec["alias"]
            return self.run(options)
        if command == "help":
            print(self.config["name"] + " project commands")
            for name, detail in self.config["commands"].items():
                if detail.get("hidden"): continue
                print("  " + name.ljust(24) + detail.get("description", ""))
            print("Arguments: just target=app platform=ios build; environment is required for remote changes")
            return
        if command == "info":
            report = source(self.root)
            report.update({"marketing_version": self.version(), "utc_build_preview": datetime.now(timezone.utc).strftime("%Y.%m%d.%H%M"),
                           "channel": options.channel, "targets": self.config["targets"], "commands": list(self.config["commands"])})
            print(json.dumps(report, indent=2)); return
        if command == "doctor":
            missing = [x for x in self.config.get("tools", ["python3", "git", "just"]) if not shutil.which(x)]
            if missing: raise ContractError("Missing tools: " + ", ".join(missing))
            if self.config.get("apple"): call(["xcodebuild", "-version"], self.root)
            print("Declared local tools are available; real server signing and upload permission remain separate checks"); return
        if command == "clean": return self.clean()
        if command == "source-capture":
            if not options.value: raise ContractError("Supply a private source-record path")
            record = source(self.root)
            record["captured_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            Path(options.value).write_text(json.dumps(record, indent=2) + "\n")
            return
        if command == "record-artifact":
            if not options.source_record: raise ContractError("Use the source record captured before this build")
            record = json.loads(Path(options.source_record).read_text())
            info = bundle_info(options.value)
            if info["BuildTimestamp"] < record["captured_at"]:
                raise ContractError("Cannot assign current source to an older artifact")
            self.record(options.value, record)
            return
        if command == "record-package":
            if not options.from_artifact or not options.value:
                raise ContractError("Supply the package and its verified original app/archive")
            original = Path(options.from_artifact).resolve()
            identity = self.verify(original, options.channel)
            manifest = json.loads(Path(str(original) + ".project.json").read_text())
            package = Path(options.value).resolve()
            if not package.is_file(): raise ContractError("Package is missing")
            identity = {"version": identity["CFBundleShortVersionString"], "build": identity["CFBundleVersion"],
                        "timestamp": identity["BuildTimestamp"], "channel": identity["BuildChannel"]}
            Path(str(package) + ".buildinfo.json").write_text(json.dumps(identity, indent=2) + "\n")
            Path(str(package) + ".project.json").write_text(json.dumps(dict(identity, schema="project-artifact/v1",
                kind="generic", source=manifest["source"], sha256=digest(package),
                packaged_from_sha256=manifest["sha256"]), indent=2) + "\n")
            return self.verify(package, options.channel)
        if command == "lint": return self.lint()
        if command == "docs-check": return self.docs_check()
        if command == "security-check": return self.security_check()
        if command == "version": return self.change_version(options)
        if command == "check":
            for task in self.config.get("check", ["lint", "security-check", "docs-check"]):
                child = argparse.Namespace(**vars(options))
                child.command = task["command"] if isinstance(task, dict) else task
                if isinstance(task, dict):
                    for name, value in task.items(): setattr(child, name, value)
                if child.command == "test": child.suite = "contract"
                self.run(child)
            return
        if command == "test" and options.suite == "contract":
            return call(["python3", ".project/tests/test_projectctl.py"], self.root)
        if command == "test" and options.suite != "unit":
            raise ContractError("Use test suite=unit/contract, or the declared ui-test/purchase-test task")
        if command == "test-result-verify":
            if not options.value: raise ContractError("Supply a result bundle")
            result = json.loads(call(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", options.value], self.root, capture=True))
            if result.get("passedTests", 0) < 1 or result.get("failedTests", 0) or result.get("skippedTests", 0):
                raise ContractError("Required suite must execute passing tests, with no failures or skips")
            print("Executed required tests: " + str(result["passedTests"])); return
        if command == "test":
            suite = options.suite
            if suite != "unit":
                mapped = {"ui": "ui-test", "purchase": "purchase-test", "integration": "integration-test", "e2e": "e2e-test"}.get(suite)
                if not mapped: raise ContractError("Unsupported test suite: " + suite)
                options.command = mapped; return self.run(options)
            if options.target == "default":
                options.target = self.config.get("default_test_target", "default")
            name, target = self.target(options)
            print("Unit test scope: " + name, flush=True)
            if target.get("kind") == "swiftpm": return self.swiftpm(options, "test")
            if target.get("kind") == "apple": self.generate()
            return self.adapter("test", options)
        if command == "ui-test" and not options.filter:
            options.filter = self.target(options)[1].get("default_filter", "")
        if command == "generate": return self.generate() if self.config.get("apple") else self.adapter(command, options)
        if command == "setup":
            name, target = self.target(options)
            if command in target.get("actions", {}): return self.adapter(command, options)
            if target.get("kind") == "apple": return self.generate()
            if target.get("kind") == "swiftpm": return self.swiftpm(options, "resolve")
            raise ContractError("No locked setup adapter for target " + name)
        if command in ("build", "typecheck"):
            name, target = self.target(options)
            if command == "typecheck" and command in target.get("actions", {}): return self.adapter(command, options)
            return self.build(options)
        if command == "archive": return self.archive(options)
        if command == "artifact-verify":
            if not options.value: raise ContractError("Supply an existing artifact path")
            return self.verify(options.value, options.channel)
        if command == "export":
            if not options.value: raise ContractError("Supply an existing archive; export never rebuilds")
            return self.export(options, options.value)
        if command == "archive-export": return self.export(options, self.archive(options))
        if command == "release-plan":
            print(json.dumps({"version": self.version(), "source": source(self.root), "channel": options.channel,
                              "platform": self.platform(options), "actions": ["archive", "artifact-verify", "export", "explicit upload"],
                              "release_trigger": "annotated tag push; publication waits for exact-source CI and artifact checks"}, indent=2))
            plan = argparse.Namespace(**vars(options)); plan.plan = True; plan.unsigned = True
            return self.archive(plan) if self.config.get("apple") else None
        if command in ("release-check", "source-check"):
            self.eligibility(options.channel, options.phase)
            if command == "source-check": return
            if self.config.get("apple"):
                return call(["python3", str(self.root / self.apple()["scripts"] / "apple_signing.py"), "--check"], self.root)
            return
        if command == "upload":
            if options.channel not in ("testflight", "release"):
                raise ContractError("Upload requires channel=testflight or channel=release explicitly")
            if not options.value: raise ContractError("Supply an existing verified archive; upload never rebuilds")
            self.verify(options.value, options.channel)
            print("External action: upload existing archive to App Store Connect; channel=" + options.channel, flush=True)
            module = self.apple_module(); before = digest(options.value)
            module.upload_archive(Path(options.value).resolve(), dict(module.load_environment(), BUILD_CHANNEL=options.channel))
            if digest(options.value) != before: raise ContractError("Upload modified the archive")
            return
        if command == "beta":
            options.channel = "testflight"
            self.eligibility("testflight")
            for task in self.config.get("beta_preflight", []):
                child = argparse.Namespace(**vars(options)); child.command = task; self.run(child)
            artifact = self.archive(options)
            child = argparse.Namespace(**vars(options)); child.command = "upload"; child.value = str(artifact)
            return self.run(child)
        if command == "release":
            if options.value != self.version(): raise ContractError("Requested release must match the committed marketing version")
            self.changelog()
            self.eligibility("release", "prepare")
            tag = "v" + options.value
            if subprocess.run(["git", "show-ref", "--verify", "--quiet", "refs/tags/" + tag], cwd=self.root).returncode == 0:
                raise ContractError("Release tag already exists; refusing to replace it")
            git(self.root, "tag", "-a", tag, "-m", "Release " + options.value)
            print("External action: push annotated tag " + tag + "; release pipeline may publish", flush=True)
            call(["git", "push", "origin", "refs/tags/" + tag], self.root)
            print("Release triggered; publication status is pending CI"); return
        if command == "changelog":
            name, target = self.target(options)
            return self.adapter(command, options) if command in target.get("actions", {}) else self.changelog()
        if command == "screenshot": return self.screenshot(options)
        if command == "dev": return self.dev(options)
        if command == "ci-status":
            sha = options.value or git(self.root, "rev-parse", "HEAD")
            return call(["gh", "run", "list", "--commit", sha, "--json", "name,status,conclusion,headSha,url"], self.root)
        if command == "ci":
            if not options.value or not options.ref: raise ContractError("Supply workflow and exact ref: just ci WORKFLOW REF")
            print("External action: dispatch " + options.value + " at " + options.ref, flush=True)
            return call(["gh", "workflow", "run", options.value, "--ref", options.ref], self.root)
        if command in EFFECTS:
            self.remote_environment(options)
            self.eligibility("release" if options.environment == "production" else "testflight")
        if command == "deploy":
            options.channel = "release" if options.environment == "production" else "testflight"
            self.adapter("deploy-check", options)
            name, target = self.target(options)
            if not target.get("artifact"): raise ContractError("Deployment requires a declared verified artifact")
            artifact = self.path_in_root(target["artifact"])
            self.verify(artifact, options.channel)
            before = digest(artifact)
            self.adapter("deploy", options)
            if digest(artifact) != before: raise ContractError("Deployment rebuilt or changed the verified artifact")
            return
        if command == "release-local":
            self.eligibility("release")
            print("External action: Developer ID signing/notarization; local packaging may contact Apple", flush=True)
        return self.adapter(command, options)

def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--config", default=".project/commands.json")
    p.add_argument("command")
    p.add_argument("value", nargs="?", default="")
    p.add_argument("--target", default="default")
    p.add_argument("--platform", default="default")
    p.add_argument("--environment", default="")
    p.add_argument("--channel", choices=["", "local", "ci", "testflight", "release"], default=os.environ.get("BUILD_CHANNEL") or ("ci" if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS") else "local"))
    p.add_argument("--suite", default="unit")
    p.add_argument("--package", default="")
    p.add_argument("--filter", default="")
    p.add_argument("--notes", default="")
    p.add_argument("--source-record", default="")
    p.add_argument("--from-artifact", default="")
    p.add_argument("--state", default="")
    p.add_argument("--width", type=int, default=0)
    p.add_argument("--height", type=int, default=0)
    p.add_argument("--ref", default="")
    p.add_argument("--phase", choices=["prepare", "publish"], default="publish")
    p.add_argument("--unsigned", action="store_true")
    p.add_argument("--plan", action="store_true")
    return p

def main(argv=None):
    options = parser().parse_args(argv)
    if not options.channel:
        options.channel = "ci" if os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS") else "local"
    try:
        Project(options.config).run(options)
    except (ContractError, OSError, ValueError, KeyError) as error:
        print("Project command failed: " + str(error), file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
