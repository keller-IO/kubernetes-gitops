import contextlib
from datetime import date
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

import yaml

ROOT = Path(__file__).parent


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f'{name}.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


pvc = module('check-pvc')
security = module('check-security')
required = module('check-required')
synthetic = module('synthetic-secrets')
coverage = module('check-source-coverage')


class Guards(unittest.TestCase):
    def test_mcp_rbac_cannot_grant_node_proxy_access(self):
        # GET on nodes/proxy can execute commands through the kubelet API.
        path = ROOT.parent.parent / 'infrastructure/base/kubernetes-mcp/rbac.yaml'
        for doc in yaml.safe_load_all(path.read_text()):
            for rule in doc.get('rules', []):
                if {'', '*'} & set(rule.get('apiGroups', [])):
                    self.assertFalse(
                        {'nodes/proxy', 'nodes/*', '*/proxy', '*'} & set(rule.get('resources', [])),
                        f"{path}: node proxy access is not read-only",
                    )

    def test_external_source_mutation_or_new_application_blocks(self):
        doc = {'kind': 'Application', 'metadata': {'name': 'external'}, 'spec': {'source': {'repoURL': 'https://example.invalid/app.git', 'path': 'k8s', 'targetRevision': 'main'}}}
        baseline = [{'name': 'external', 'spec': doc['spec'], 'reason': 'Separate repo owns deployment'}]
        with tempfile.TemporaryDirectory() as work, contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            root = Path(work)
            path = root / 'clusters_main_external.yaml'
            path.write_text(yaml.safe_dump(doc))
            self.assertEqual(coverage.check(root, baseline), 0)
            doc = json.loads(json.dumps(doc))
            doc['spec']['source']['path'] = 'missing'
            path.write_text(yaml.safe_dump(doc))
            self.assertEqual(coverage.check(root, baseline), 1)
            doc['metadata']['name'] = 'new-external'
            path.write_text(yaml.safe_dump(doc))
            self.assertEqual(coverage.check(root, baseline), 1)

    def test_required_jobs_fail_closed(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(required.check({x: {'result': 'success'} for x in ('validate', 'integration')}), 0)
            for state in ('skipped', 'cancelled', 'failure', None):
                self.assertEqual(required.check({'validate': {'result': 'success'}, 'integration': {'result': state}}), 1)
            self.assertEqual(required.check({}), 1)

    def test_pvc_protection_rejects_partial_and_true_options(self):
        doc = {'kind': 'PersistentVolumeClaim', 'metadata': {'name': 'data', 'annotations': {}}}
        self.assertEqual(pvc.violations(doc), ['Prune=false', 'Delete=false'])
        key = 'argocd.argoproj.io/sync-options'
        doc['metadata']['annotations'][key] = 'Prune=false,Delete=true'
        self.assertEqual(pvc.violations(doc), ['Delete=false'])
        doc['metadata']['annotations'][key] = ' Prune = false , Delete = false '
        self.assertEqual(pvc.violations(doc), ['Prune=false', 'Delete=false'])
        doc['metadata']['annotations'][key] = ' Prune=false , Delete=false '
        self.assertEqual(pvc.violations(doc), [])
        doc['metadata']['annotations'][key] = 'Prune=false,Delete=false,Prune=true'
        self.assertEqual(pvc.violations(doc), ['Prune=false'])
        doc['metadata']['annotations'][key] = 'Prune=true,Prune=false,Delete=false'
        self.assertEqual(pvc.violations(doc), ['Prune=false'])

    def test_pvc_allowlist_cannot_allow_another_resource_or_stale_gap(self):
        with tempfile.TemporaryDirectory() as work, contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            root = Path(work)
            target = root / 'apps_example.yaml'
            doc = {'kind': 'PersistentVolumeClaim', 'metadata': {'name': 'old', 'namespace': 'app'}}
            target.write_text(yaml.safe_dump(doc))
            exceptions = root / 'gaps.txt'
            exceptions.write_text('apps_example:app/old # existing debt\n')
            self.assertEqual(pvc.check(root, exceptions), 0)
            doc['metadata']['name'] = 'new'
            target.write_text(yaml.safe_dump(doc))
            self.assertEqual(pvc.check(root, exceptions), 1)
            target.unlink()
            self.assertEqual(pvc.check(root, exceptions), 1)

    def test_security_new_changed_expired_and_stale_findings_block(self):
        finding = {'ID': 'KSV-1', 'Message': 'unsafe app', 'Status': 'FAIL', 'Severity': 'HIGH'}
        report = {'Results': [{'Target': 'apps_example.yaml', 'Misconfigurations': [finding]}]}
        exception = {'target': 'apps_example.yaml', 'id': 'KSV-1', 'message': 'unsafe app', 'count': 1, 'expires': '2027-01-18', 'reason': 'Existing debt'}
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(security.check(report, [exception], date(2026, 10, 18)), 0)
            self.assertEqual(security.check(report, [], date(2026, 10, 18)), 1)
            self.assertEqual(security.check(report, [exception], date(2027, 1, 18)), 1)
            report['Results'][0]['Misconfigurations'].append(finding.copy())
            self.assertEqual(security.check(report, [exception], date(2026, 10, 18)), 1)
            report['Results'][0]['Misconfigurations'] = []
            self.assertEqual(security.check(report, [exception], date(2026, 10, 18)), 1)
        with self.assertRaises(ValueError):
            security.findings({})

    def test_synthetic_payload_types_and_source_unchanged(self):
        original = {'n': 'ENC[AES256_GCM,data:x,type:int]', 'b': 'ENC[AES256_GCM,data:x,type:bool]', 's': ['ENC[AES256_GCM,data:x,type:str]'], 'name': 'app'}
        before = json.dumps(original)
        self.assertEqual(synthetic.synthetic(original), {'n': 1, 'b': False, 's': ['ci-synthetic-value'], 'name': 'app'})
        self.assertEqual(json.dumps(original), before)
