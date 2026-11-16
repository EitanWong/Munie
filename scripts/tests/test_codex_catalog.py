"""Offline protocol inventory regressions; fixtures never launch Codex or a model."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'catalog-codex.py'
SPEC = importlib.util.spec_from_file_location('catalog_codex', SCRIPT)
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)


def variant(method, kind):
    properties = {'method': {'type': 'string', 'enum': [method]}}
    required = ['method']
    if kind.endswith('Request'):
        properties.update(id={'type': 'integer'}, params={'type': 'object'})
        required += ['id', 'params']
    elif kind == 'ServerNotification':
        properties['params'] = {'type': 'object'}
        required.append('params')
    return {'type': 'object', 'properties': properties, 'required': required}


class CodexCatalogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.full = Path(self.temporary.name) / 'full'
        self.default = Path(self.temporary.name) / 'default'
        for directory in (self.full, self.default):
            directory.mkdir()
            for kind, method in {
                'ClientRequest': 'thread/start',
                'ServerRequest': 'item/commandExecution/requestApproval',
                'ServerNotification': 'turn/completed',
                'ClientNotification': 'initialized',
            }.items():
                self.write(directory, kind, {'title': kind, 'oneOf': [variant(method, kind)]})
        self.version = 'codex-cli 0.162.1'

    def write(self, directory, kind, document):
        (directory / f'{kind}.json').write_text(json.dumps(document), encoding='utf-8')

    def read(self, directory, kind):
        return json.loads((directory / f'{kind}.json').read_text())

    def build(self):
        return catalog.build_catalog(self.full, self.default, self.version)

    def test_inventory_is_deterministic_and_never_claims_implementation(self):
        first, second = self.build(), self.build()
        self.assertEqual(first, second)
        self.assertEqual(first['totalMethods'], 4)
        self.assertEqual(first['implementedMethods'], 0)
        self.assertTrue(all(row['status'] == 'unimplemented'
                            for group in first['methods'].values() for row in group))
        catalog.check_catalog(first, second)

    def test_new_method_is_included_and_drift_rejected(self):
        previous = self.build()
        schema = self.read(self.full, 'ClientRequest')
        schema['oneOf'].append(variant('thread/futureNativeFeature', 'ClientRequest'))
        self.write(self.full, 'ClientRequest', schema)
        current = self.build()
        row = next(row for row in current['methods']['ClientRequest']
                   if row['method'] == 'thread/futureNativeFeature')
        self.assertFalse(row['presentInDefaultExport'])
        with self.assertRaisesRegex(ValueError, 'added: thread/futureNativeFeature'):
            catalog.check_catalog(current, previous)

    def test_removed_method_is_reported(self):
        schema = self.read(self.full, 'ClientRequest')
        schema['oneOf'].append(variant('thread/deprecatedFeature', 'ClientRequest'))
        self.write(self.full, 'ClientRequest', schema)
        previous = self.build()
        schema['oneOf'].pop()
        self.write(self.full, 'ClientRequest', schema)
        with self.assertRaisesRegex(ValueError, 'removed: thread/deprecatedFeature'):
            catalog.check_catalog(self.build(), previous)

    def test_approval_and_notifications_preserve_directions(self):
        report = self.build()
        request = report['methods']['ServerRequest'][0]
        self.assertEqual(request['category'], 'approvals')
        self.assertNotIn(request['method'], [row['method'] for row in report['methods']['ServerNotification']])
        schema = self.read(self.full, 'ServerNotification')
        schema['oneOf'][0]['properties']['id'] = {'type': 'integer'}
        schema['oneOf'][0]['required'].append('id')
        self.write(self.full, 'ServerNotification', schema)
        with self.assertRaisesRegex(ValueError, 'notifications cannot'):
            self.build()

    def test_request_without_response_id_fails(self):
        schema = self.read(self.full, 'ServerRequest')
        schema['oneOf'][0]['required'].remove('id')
        self.write(self.full, 'ServerRequest', schema)
        with self.assertRaisesRegex(ValueError, 'requests require id'):
            self.build()

    def test_field_and_response_changes_cannot_hide_behind_same_method_names(self):
        previous = self.build()
        response = self.full / 'ThreadStartResponse.json'
        response.write_text(json.dumps({'type': 'object', 'properties': {'newState': {'type': 'string'}}}))
        with self.assertRaisesRegex(ValueError, 'schema hash changed'):
            catalog.check_catalog(self.build(), previous)
        previous = self.build()
        schema = self.read(self.full, 'ClientRequest')
        schema['oneOf'][0]['properties']['params'] = {'type': 'object', 'required': ['newField']}
        self.write(self.full, 'ClientRequest', schema)
        with self.assertRaisesRegex(ValueError, 'schema hash changed'):
            catalog.check_catalog(self.build(), previous)

    def test_default_export_is_not_labeled_stable_or_runtime_available(self):
        row = self.build()['methods']['ClientRequest'][0]
        self.assertTrue(row['presentInDefaultExport'])
        self.assertNotIn('stable', row)
        self.assertNotIn('available', row)

    def test_duplicate_or_nonliteral_tags_fail_instead_of_disappearing(self):
        for change in ('duplicate', 'empty', 'ambiguous'):
            with self.subTest(change=change):
                schema = self.read(self.default, 'ClientRequest')
                if change == 'duplicate':
                    schema['oneOf'].append(copy.deepcopy(schema['oneOf'][0]))
                elif change == 'empty':
                    schema['oneOf'][0]['properties']['method']['enum'] = []
                else:
                    schema['oneOf'][0]['properties']['method']['enum'].append('thread/other')
                self.write(self.full, 'ClientRequest', schema)
                with self.assertRaises(ValueError):
                    self.build()

    def test_missing_union_or_inverted_export_fails(self):
        path = self.full / 'ClientNotification.json'
        original = path.read_text()
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'all four'):
            self.build()
        path.write_text(original)
        schema = self.read(self.default, 'ClientRequest')
        schema['oneOf'].append(variant('thread/defaultOnly', 'ClientRequest'))
        self.write(self.default, 'ClientRequest', schema)
        with self.assertRaisesRegex(ValueError, 'not a subset'):
            self.build()

    def test_unresolved_and_external_refs_are_rejected_offline(self):
        for reference in ('#/definitions/Missing', 'https://example.invalid/schema.json'):
            with self.subTest(reference=reference):
                schema = self.read(self.default, 'ClientRequest')
                schema['oneOf'][0]['properties']['params'] = {'$ref': reference}
                self.write(self.full, 'ClientRequest', schema)
                with self.assertRaisesRegex(ValueError, 'schema reference'):
                    self.build()

    def test_malformed_json_and_version_fail(self):
        for content in ('{"title":"ClientRequest","title":"other"}', '{"x":NaN}', '[]'):
            with self.subTest(content=content):
                (self.full / 'ClientRequest.json').write_text(content)
                with self.assertRaises(ValueError):
                    self.build()
        for version in ('', 'latest', 'codex-cli 0.162.1\nextra'):
            with self.subTest(version=version):
                with self.assertRaises(ValueError):
                    catalog.build_catalog(self.full, self.default, version)

    def test_snapshot_validation_rejects_forged_counts_hashes_roles_and_status(self):
        original = self.build()
        self.assertEqual(catalog.validate_snapshot(original), 4)
        for mutation in ('count', 'total', 'hash', 'role', 'duplicate', 'status', 'category', 'presence'):
            with self.subTest(mutation=mutation):
                snapshot = copy.deepcopy(original)
                if mutation == 'count':
                    snapshot['counts']['ClientRequest'] = True
                elif mutation == 'total':
                    snapshot['totalMethods'] = 5
                elif mutation == 'hash':
                    snapshot['schemaBundles']['experimental']['sha256'] = 'invalid'
                elif mutation == 'role':
                    del snapshot['methods']['ServerRequest']
                elif mutation == 'duplicate':
                    snapshot['methods']['ClientRequest'].append(snapshot['methods']['ClientRequest'][0])
                elif mutation == 'status':
                    snapshot['methods']['ServerRequest'][0]['status'] = 'implemented'
                elif mutation == 'category':
                    snapshot['methods']['ServerRequest'][0]['category'] = ''
                else:
                    snapshot['methods']['ClientRequest'][0]['presentInDefaultExport'] = 'true'
                with self.assertRaises(ValueError):
                    catalog.validate_snapshot(snapshot)

    def test_ci_snapshot_mode_runs_without_codex_or_exported_schemas(self):
        path = Path(self.temporary.name) / 'catalog.json'
        path.write_text(json.dumps(self.build()))
        result = subprocess.run([sys.executable, str(SCRIPT), '--validate-catalog', str(path)],
                                env={'PATH': ''}, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('structure validated: total=4', result.stdout)
        self.assertIn('generated-schema drift not checked', result.stdout)

    def test_status_tampering_and_version_upgrade_are_drift(self):
        report = self.build()
        modified = copy.deepcopy(report)
        modified['methods']['ServerRequest'][0]['status'] = 'implemented'
        with self.assertRaisesRegex(ValueError, 'changed metadata/status'):
            catalog.check_catalog(report, modified)
        modified = dict(report, cliVersion='codex-cli 0.163.0')
        with self.assertRaisesRegex(ValueError, 'CLI version changed'):
            catalog.check_catalog(report, modified)

    def test_boolean_and_integer_substitutions_are_protocol_drift(self):
        report = self.build()
        for field, value in (('catalogVersion', True), ('implementedMethods', False)):
            with self.subTest(field=field):
                modified = copy.deepcopy(report)
                modified[field] = value
                with self.assertRaisesRegex(ValueError, 'Catalog drift'):
                    catalog.check_catalog(report, modified)
        modified = copy.deepcopy(report)
        modified['methods']['ClientRequest'][0]['presentInDefaultExport'] = 1
        with self.assertRaisesRegex(ValueError, 'Catalog drift'):
            catalog.check_catalog(report, modified)


if __name__ == '__main__':
    unittest.main()
