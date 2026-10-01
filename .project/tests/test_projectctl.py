#!/usr/bin/env python3
"""Real Git and artifact regressions. Apple/server operations are stubbed."""
import argparse
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import shutil
from types import SimpleNamespace
import unittest
from unittest.mock import patch

module_path = Path(__file__).resolve().parents[1] / 'projectctl.py'
spec = importlib.util.spec_from_file_location('projectctl', module_path)
ctl = importlib.util.module_from_spec(spec); spec.loader.exec_module(ctl)

class ContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q', '--initial-branch=main')
        self.git('config', 'user.email', 'tests@example.invalid'); self.git('config', 'user.name', 'Contract Tests')
        self.git('remote', 'add', 'origin', 'https://github.com/example/project.git')
        (self.root/'.project').mkdir(); (self.root/'Config').mkdir(); (self.root/'docs').mkdir()
        (self.root/'.gitignore').write_text('.project/output/\nbuild/\n')
        (self.root/'Config/Shared.xcconfig').write_text('MARKETING_VERSION = 1.2.3\nBUILD_NUMBER = 0\n')
        (self.root/'CHANGELOG.md').write_text('# Changelog\n\n## 1.2.3\n\nApproved release notes.\n')
        (self.root/'docs/PROJECT-COMMANDS.md').write_text('Project commands.\n')
        self.config = {'schema':ctl.SCHEMA,'name':'Example','version_file':'Config/Shared.xcconfig',
          'default_target':'app','commands':{x:{} for x in ctl.CORE | {'lint','security-check','docs-check',
              'build','archive','release-check','release','version','changelog','artifact-verify','upload',
              'test-result-verify','deploy','export','test','screenshot','source-capture','record-artifact','record-package'}},
          'targets':{'app':{'kind':'apple','default_platform':'macos','platforms':{'macos':{},'ios':{}},
                            'actions':{},'environments':{'production':'example-production','staging':'example-staging'}}},
          'apple':{'scripts':'Scripts','archive_config':'Config/ArchiveTargets.json'},
          'release':{'required_checks':['native'],'allow_untagged_beta':True},
          'clean':['.project/output'],'check':['lint','security-check','docs-check']}
        (self.root/'Config/ArchiveTargets.json').write_text(json.dumps({'project':'Example.xcodeproj',
            'spec':None,'defaultPlatform':'macos','platforms':{'macos':{'scheme':'Example','destination':'generic/platform=macOS'},
                                                          'ios':{'scheme':'Example','destination':'generic/platform=iOS'}}}))
        self.save(); self.commit()
        self.project = ctl.Project(self.root/'.project/commands.json')

    def git(self,*args):
        return subprocess.run(['git',*args],cwd=self.root,text=True,capture_output=True,check=True).stdout.strip()
    def commit(self):
        self.git('add','.'); self.git('commit','-qm','fixture')
    def save(self):
        (self.root/'.project/commands.json').write_text(json.dumps(self.config))
    def opts(self, command='help', **kwargs):
        result=ctl.parser().parse_args([command]); vars(result).update(kwargs); return result
    def artifact(self, channel='release', dirty='NO', tagged='YES'):
        archive=self.root/'build/Example.xcarchive'; app=archive/'Products/Applications/Example.app/Contents'
        app.mkdir(parents=True,exist_ok=True)
        info={'CFBundleVersion':'2026.1001.0900','CFBundleShortVersionString':'1.2.3',
              'BuildTimestamp':'2026-10-01T09:00:12Z','BuildChannel':channel,'BuildDirty':dirty,
              'BuildTagged':tagged,'BuildDirtyFiles':'0','BuildSHA':'','BuildBranch':'','BuildDescribe':'','BuildDiffID':''}
        (app/'Info.plist').write_bytes(plistlib.dumps(info))
        (archive/'Info.plist').write_bytes(plistlib.dumps({'ApplicationProperties':{
            'ApplicationPath':'Applications/Example.app','CFBundleVersion':info['CFBundleVersion'],
            'CFBundleShortVersionString':info['CFBundleShortVersionString']}}))
        return archive,info
    def test_actual_detached_checkout(self):
        sha=self.git('rev-parse','HEAD'); self.git('checkout','--detach','-q')
        report=ctl.source(self.root); self.assertEqual(report['sha'],sha); self.assertEqual(report['branch'],'detached')
    def test_source_capture_does_not_create_build_number(self):
        output=self.root/'build/source.json';output.parent.mkdir()
        self.project.run(self.opts('source-capture',value=str(output)))
        record=json.loads(output.read_text());self.assertEqual(record['sha'],self.git('rev-parse','HEAD'))
        self.assertIn('captured_at',record);self.assertNotIn('build',record)
        self.assertFalse(ctl.source(self.root)['dirty'])
    def test_current_source_cannot_be_assigned_to_old_archive(self):
        artifact,_=self.artifact();path=self.root/'build/source.json'
        path.write_text(json.dumps(dict(ctl.source(self.root),captured_at='2026-10-02T00:00:00Z')))
        with self.assertRaisesRegex(ctl.ContractError,'older artifact'):
            self.project.run(self.opts('record-artifact',value=str(artifact),source_record=str(path)))
        self.assertFalse(Path(str(artifact)+'.project.json').exists())
    def test_packaging_reuses_original_identity_and_rejects_changed_bytes(self):
        self.git('tag','-a','v1.2.3','-m','release')
        artifact,_=self.artifact();self.project.record(artifact,ctl.source(self.root))
        package=self.root/'build/Example.dmg';package.write_bytes(b'packaged app')
        with patch.object(self.project,'check_ci'):
            self.project.run(self.opts('record-package',value=str(package),from_artifact=str(artifact),channel='release'))
            info=self.project.verify(package,'release');self.assertEqual(info['build'],'2026.1001.0900')
            package.write_bytes(b'tampered package')
            with self.assertRaisesRegex(ctl.ContractError,'changed'):self.project.verify(package,'release')
    def test_archive_receives_selected_channel(self):
        with patch.object(ctl,'call',return_value='') as runner:
            self.project.archive(self.opts('archive',channel='testflight',plan=True))
        self.assertEqual(runner.call_args.kwargs['env']['BUILD_CHANNEL'],'testflight')
    def test_export_retry_never_compiles_or_changes_archive_identity(self):
        artifact,info=self.artifact();self.project.record(artifact,ctl.source(self.root))
        before=ctl.digest(artifact);commands=[]
        module=SimpleNamespace(load_environment=lambda:{'APPLE_TEAM_ID':'ABCDEFGHIJ'},provisioning_arguments=lambda env:[])
        def fake(argv,root,env=None,capture=False):
            commands.append(argv)
            self.assertIn('-exportArchive',argv);self.assertNotIn('archive',argv)
            output=Path(argv[argv.index('-exportPath')+1]);output.mkdir()
            shutil.copytree(artifact/'Products/Applications/Example.app',output/'Example.app')
            return ''
        with patch.object(self.project,'apple_module',return_value=module),patch.object(ctl,'call',side_effect=fake):
            one=self.project.export(self.opts('export'),artifact)
            two=self.project.export(self.opts('export'),artifact)
        self.assertNotEqual(one,two);self.assertEqual(ctl.digest(artifact),before)
        self.assertEqual(len(commands),2)
        exported=ctl.bundle_info(two/'Export/Example.app')
        self.assertEqual(exported['CFBundleVersion'],info['CFBundleVersion'])
        self.assertTrue(Path(str(two/'Export/Example.app')+'.project.json').exists())
    def test_unknown_test_suite_is_not_reported_as_unit_coverage(self):
        with self.assertRaisesRegex(ctl.ContractError,'suite=unit/contract'):
            self.project.run(self.opts('test',suite='unknown'))
    def test_dirty_tagged_are_independent(self):
        self.git('tag','-a','v1.2.3','-m','version'); (self.root/'untracked').write_text('change')
        report=ctl.source(self.root); self.assertTrue(report['dirty']); self.assertIn('v1.2.3',report['tags'])
    def test_beta_allows_identified_untagged_source(self):
        self.project.eligibility('testflight')
    def test_beta_can_require_tag(self):
        self.config['release']['allow_untagged_beta']=False; self.save(); self.commit()
        with self.assertRaisesRegex(ctl.ContractError,'matching tag'):ctl.Project(self.root/'.project/commands.json').eligibility('testflight')
    def test_upload_requires_explicit_channel(self):
        with self.assertRaisesRegex(ctl.ContractError,'explicitly'):self.project.run(self.opts('upload',value='archive'))
    def test_dirty_beta_rejected_before_credentials(self):
        (self.root/'change').write_text('dirty')
        with self.assertRaisesRegex(ctl.ContractError,'clean checkout'):self.project.eligibility('testflight')
    def test_release_tag_required(self):
        with self.assertRaisesRegex(ctl.ContractError,'matching tag'):self.project.eligibility('release',ci=False)
    def test_lightweight_tag_rejected(self):
        self.git('tag','v1.2.3')
        with self.assertRaisesRegex(ctl.ContractError,'annotated'):self.project.eligibility('release',ci=False)
    def test_matching_annotated_tag_accepted(self):
        self.git('tag','-a','v1.2.3','-m','version');self.project.eligibility('release',ci=False)
    def test_wrong_tag_rejected(self):
        self.git('tag','-a','v1.2.4','-m','version')
        with self.assertRaisesRegex(ctl.ContractError,'matching tag'):self.project.eligibility('release',ci=False)
    def test_unknown_command_fails(self):
        with self.assertRaisesRegex(ctl.ContractError,'Unsupported command'):self.project.run(self.opts('unknown'))
    def test_unknown_target_fails(self):
        with self.assertRaisesRegex(ctl.ContractError,'Unsupported target'):self.project.target(self.opts(target='missing'))
    def test_unknown_platform_fails(self):
        with self.assertRaisesRegex(ctl.ContractError,'Unsupported platform'):self.project.platform(self.opts(platform='windows'))
    def test_missing_adapter_fails(self):
        with self.assertRaisesRegex(ctl.ContractError,'unsupported'):self.project.adapter('test',self.opts('test'))
    def test_remote_environment_never_defaults(self):
        with self.assertRaisesRegex(ctl.ContractError,'explicitly'):self.project.remote_environment(self.opts('deploy'))
    def test_unknown_environment_rejected(self):
        with self.assertRaisesRegex(ctl.ContractError,'Unsupported remote'):self.project.remote_environment(self.opts('deploy',environment='typo'))
    def test_clean_preserves_tracked_files(self):
        self.project.config['clean']=['Config']
        with self.assertRaisesRegex(ctl.ContractError,'tracked source'):self.project.clean()
        self.assertTrue((self.root/'Config/Shared.xcconfig').exists())
    def test_clean_preserves_archive_evidence(self):
        self.artifact(); (self.root/'.project/output').mkdir(); (self.root/'.project/output/build').write_text('output')
        self.project.clean();self.assertTrue((self.root/'build/Example.xcarchive').exists())
    def test_symlink_escape_rejected(self):
        (self.root/'escape').symlink_to(self.root.parent,target_is_directory=True)
        with self.assertRaisesRegex(ctl.ContractError,'escapes'):self.project.path_in_root('escape')
    def test_archive_and_extension_identity(self):
        artifact,info=self.artifact(); plugin=artifact/'Products/Applications/Example.app/Contents/PlugIns/Widget.appex'
        plugin.mkdir(parents=True);(plugin/'Info.plist').write_bytes(plistlib.dumps(info)); ctl.bundle_info(artifact)
        info['CFBundleVersion']='2026.1001.0901';(plugin/'Info.plist').write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ctl.ContractError,'embedded target'):ctl.bundle_info(artifact)
    def test_epoch_build_rejected(self):
        artifact,info=self.artifact();info['CFBundleVersion']='998877'
        (artifact/'Products/Applications/Example.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ctl.ContractError,'UTC build stamp'):ctl.bundle_info(artifact)
    def test_release_repository_details_rejected(self):
        artifact,info=self.artifact();info['BuildSHA']='internal'
        (artifact/'Products/Applications/Example.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ctl.ContractError,'internal repository'):ctl.bundle_info(artifact)
    def test_tampered_artifact_rejected(self):
        artifact,_=self.artifact();self.project.record(artifact,ctl.source(self.root))
        (artifact/'unexpected').write_text('tampered')
        with self.assertRaisesRegex(ctl.ContractError,'changed'):self.project.verify(artifact)
    def test_old_archive_can_be_inspected_without_fake_provenance(self):
        artifact,_=self.artifact();self.project.verify(artifact)
        with self.assertRaisesRegex(ctl.ContractError,'original private'):self.project.verify(artifact,'testflight')
    def test_wrong_source_manifest_rejected(self):
        artifact,_=self.artifact();old=ctl.source(self.root);old['sha']='0'*40;self.project.record(artifact,old)
        with self.assertRaisesRegex(ctl.ContractError,'different source'):self.project.verify(artifact,'testflight')
    def test_dirty_artifact_rejected(self):
        artifact,_=self.artifact(dirty='YES')
        with self.assertRaisesRegex(ctl.ContractError,'Source changed'):self.project.record(artifact,ctl.source(self.root))
    def test_valid_beta_archive_identity_preserved(self):
        artifact,_=self.artifact();manifest=self.project.record(artifact,ctl.source(self.root)); before=ctl.digest(artifact)
        self.project.verify(artifact,'testflight');self.assertEqual(before,ctl.digest(artifact));self.assertEqual(manifest['build'],'2026.1001.0900')
    def test_version_requires_real_release_notes(self):
        with self.assertRaisesRegex(ctl.ContractError,'release-notes'):self.project.change_version(self.opts('version',value='2.0.0'))
        self.assertEqual(self.project.version(),'1.2.3')
    def test_version_changes_marketing_only(self):
        notes=self.root/'.project/output/notes.md';notes.parent.mkdir();notes.write_text('Approved changes.')
        self.project.change_version(self.opts('version',value='2.0.0',notes=str(notes)))
        self.assertEqual(self.project.version(),'2.0.0');self.assertIn('BUILD_NUMBER = 0',(self.root/'Config/Shared.xcconfig').read_text())
        self.assertIn('Approved changes.',(self.root/'CHANGELOG.md').read_text())
    def test_no_empty_suite_success(self):
        with patch.object(ctl,'call',return_value=json.dumps({'passedTests':0,'skippedTests':0})):
            with self.assertRaisesRegex(ctl.ContractError,'execute passing'):self.project.run(self.opts('test-result-verify',value='results'))
    def test_no_all_skipped_purchase_success(self):
        with patch.object(ctl,'call',return_value=json.dumps({'passedTests':0,'skippedTests':6})):
            with self.assertRaisesRegex(ctl.ContractError,'no failures or skips'):self.project.run(self.opts('test-result-verify',value='results'))
    def test_required_suite_pass(self):
        with patch.object(ctl,'call',return_value=json.dumps({'passedTests':6,'skippedTests':0,'failedTests':0})):
            self.project.run(self.opts('test-result-verify',value='results'))
    def test_public_doc_private_pointer_rejected(self):
        (self.root/'docs/PROJECT-COMMANDS.md').write_text('https://github.com/example/dev/docs/internal')
        with self.assertRaisesRegex(ctl.ContractError,'private development'):self.project.docs_check()
    def test_broken_local_link_rejected(self):
        (self.root/'docs/PROJECT-COMMANDS.md').write_text('[missing](missing.md)')
        with self.assertRaisesRegex(ctl.ContractError,'Broken local'):self.project.docs_check()
    def test_security_reports_filename_only(self):
        path=self.root/'credential';path.write_text('-----BEGIN PRIVATE KEY-----\nsecret material\n');self.git('add','credential')
        with self.assertRaises(ctl.ContractError) as error:self.project.security_check()
        self.assertIn('credential:1',str(error.exception));self.assertNotIn('secret material',str(error.exception))
    def test_build_captures_once_for_both_platforms(self):
        commands=[]
        def fake(argv,root,env=None,capture=False):
            commands.append(argv)
            if str(argv[0])=='bash' and str(argv[1]).endswith('buildinfo.sh'):
                return 'BUILD_NUMBER=2026.1001.0900\nBUILD_TIMESTAMP=2026-10-01T09:00:12Z\n'
            return ''
        with patch.object(ctl,'call',side_effect=fake):self.project.build(self.opts('build'))
        self.assertEqual(sum(str(x[0])=='bash' and str(x[1]).endswith('buildinfo.sh') for x in commands),1)
        builds=[x for x in commands if x[0]=='xcodebuild'];self.assertEqual(len(builds),2)
        self.assertTrue(all('BUILD_NUMBER=2026.1001.0900' in x for x in builds))
    def test_ci_pending_and_missing_checks_fail(self):
        values=[json.dumps([{'check_runs':[{'name':'native','status':'in_progress','conclusion':None}]}]),json.dumps([[]]),json.dumps({'protected':False})]
        with patch.object(ctl,'call',side_effect=values),patch.object(ctl,'git',return_value='https://github.com/example/project.git'):
            with self.assertRaisesRegex(ctl.ContractError,'pending'):self.project.check_ci('a'*40)
    def test_ci_skipped_does_not_equal_passed(self):
        values=[json.dumps([{'check_runs':[{'name':'native','status':'completed','conclusion':'skipped'}]}]),json.dumps([[]]),json.dumps({'protected':False})]
        with patch.object(ctl,'call',side_effect=values),patch.object(ctl,'git',return_value='https://github.com/example/project.git'):
            with self.assertRaisesRegex(ctl.ContractError,'skipped'):self.project.check_ci('a'*40)
    def test_shell_metacharacters_are_arguments(self):
        self.project.config['targets']['app']['actions']['test']=[{'argv':['example','{value}']}]
        with patch.object(ctl,'call') as fake:self.project.adapter('test',self.opts('test',value='$(never-run); `never`'))
        self.assertEqual(fake.call_args.args[0],['example','$(never-run); `never`'])
    def test_screenshot_requires_explicit_sample_state(self):
        with self.assertRaisesRegex(ctl.ContractError,'prepared sample'):self.project.screenshot(self.opts('screenshot',value='123'))
    def test_approved_secret_fixture_does_not_allow_different_key(self):
        key='ghp_'+'A'*36; path=self.root/'fixture';path.write_text(key);self.git('add','fixture')
        self.project.config['credential_fixtures']=[{'path':'fixture','sha256':ctl.hashlib.sha256(key.encode()).hexdigest()}]
        self.project.security_check();path.write_text('ghp_'+'B'*36)
        with self.assertRaisesRegex(ctl.ContractError,'credential'):self.project.security_check()
    def test_generic_build_records_source_and_exact_bytes(self):
        self.project.config['targets']['site']={'kind':'web','artifact':'.project/output/site','actions':{
            'build':[{'argv':[sys.executable,'-c',"from pathlib import Path; p=Path('.project/output/site'); p.mkdir(parents=True); (p/'index.html').write_text('site')"]}]}}
        options=self.opts('build',target='site',channel='ci');self.project.build(options)
        artifact=self.root/'.project/output/site';identity=self.project.verify(artifact)
        self.assertEqual(identity['version'],'1.2.3');self.assertNotIn('sha',identity)
        (artifact/'index.html').write_text('different')
        with self.assertRaisesRegex(ctl.ContractError,'changed after compilation'):self.project.verify(artifact)
    def test_cargo_version_is_separate_from_dependency_versions(self):
        path=self.root/'Cargo.toml';path.write_text('[package]\nname = "example"\nversion = "1.2.3"\n[dependencies]\nserde = "1.0"\n')
        self.project.config['version_file']='Cargo.toml'
        notes=self.root/'.project/output/notes';notes.parent.mkdir();notes.write_text('Approved Rust release.')
        self.project.change_version(self.opts('version',value='2.0.0',notes=str(notes)))
        self.assertEqual(self.project.version(),'2.0.0');self.assertIn('serde = "1.0"',path.read_text())

if __name__ == '__main__':
    unittest.main()
