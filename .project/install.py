#!/usr/bin/env python3
"""Vendor a reviewed command runtime and render supported Just recipes offline."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

COMMON = ' --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}'

def render(config):
    lines = ['# Generated from .project/commands.json; regenerate with .project/install.py.',
             'set shell := ["bash", "-uc"]', 'target := "default"', 'platform := "default"',
             'environment := ""', 'channel := env("BUILD_CHANNEL", "")', 'suite := "unit"',
             'package := ""', 'filter := ""', 'state := ""', 'width := "0"', 'height := "0"', 'unsigned := "false"', 'plan := "false"', '', 'default: help', '']
    for name, spec in config['commands'].items():
        if spec.get('hidden'):
            continue
        lines.append('# ' + spec.get('description', name).replace('\n', ' '))
        args = ''
        tail = ''
        common = COMMON
        if name == 'version':
            args = ' chosen notes_file'; tail = ' {{quote(chosen)}} --notes {{quote(notes_file)}}'
        elif name == 'release':
            args = ' chosen'; tail = ' {{quote(chosen)}}'
        elif name in ('export', 'artifact-verify', 'upload', 'beta-upload'):
            args = ' artifact selected_platform=platform'; tail = ' {{quote(artifact)}}'
            common = common.replace('{{quote(platform)}}', '{{quote(selected_platform)}}')
        elif name in ('screenshot', 'dev'):
            args = ' value=""'; tail = ' {{quote(value)}}'
        elif name == 'ci':
            args = ' workflow ref'; tail = ' {{quote(workflow)}} --ref {{quote(ref)}}'
        elif name == 'ci-status':
            args = ' ref=""'; tail = ' {{quote(ref)}}'
        elif name in ('ui-test',):
            args = ' selection=filter'; common = common.replace('{{quote(filter)}}', '{{quote(selection)}}')
        elif name in ('archive', 'archive-export', 'beta', 'release-plan'):
            args = ' selected_platform=platform'; common = common.replace('{{quote(platform)}}', '{{quote(selected_platform)}}')
            if name == 'archive': tail += ' {{if unsigned == "true" { "--unsigned" } else { "" }}} {{if plan == "true" { "--plan" } else { "" }}}'
        elif name in ('worker-secret-google', 'worker-deploy', 'worker-logs'):
            args = ' selected_environment=environment'; common = common.replace('{{quote(environment)}}', '{{quote(selected_environment)}}')
        elif name == 'worker-secret-apple':
            args = ' key_file selected_environment=environment'; tail = ' {{quote(key_file)}}'
            common = common.replace('{{quote(environment)}}', '{{quote(selected_environment)}}')
        elif name == 'worker-configure-app':
            args = ' url'; tail = ' {{quote(url)}}'
        lines.extend([name + args + ':', '    @python3 .project/projectctl.py ' + name + tail + common, ''])
    return '\n'.join(lines)

def install(source, root):
    root = Path(root).resolve(); source = Path(source).resolve()
    dest = root / '.project'; (dest / 'tests').mkdir(parents=True, exist_ok=True)
    for filename in ('projectctl.py', 'install.py', 'tests/test_projectctl.py'):
        if (source / filename).resolve() != (dest / filename).resolve():
            shutil.copyfile(source / filename, dest / filename)
    hashes = {name: hashlib.sha256((dest / name).read_bytes()).hexdigest()
              for name in ('projectctl.py', 'install.py', 'tests/test_projectctl.py')}
    (dest / 'runtime.lock.json').write_text(json.dumps({'schema': 'project-runtime/v1', 'files': hashes}, indent=2) + '\n')
    config = json.loads((dest / 'commands.json').read_text())
    (root / 'justfile').write_text(render(config))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?', default='.')
    args = parser.parse_args()
    install(Path(__file__).parent, args.root)
