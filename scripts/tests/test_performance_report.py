"""Regression checks for performance evidence and budget failures, with synthetic measurements."""

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check-performance.py'
SPEC = importlib.util.spec_from_file_location('check_performance', SCRIPT)
performance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(performance)


class PerformanceReportTests(unittest.TestCase):
    def setUp(self):
        self.budgets = {
            'schemaVersion': 1, 'configuration': 'release', 'minimumSamples': 20,
            'minimumWarmups': 3, 'textUTF8Bytes': 248,
            'p95MillisecondsByRecordCount': {
                str(count): {'list': 10, 'save': 20, 'delete': 20} for count in (100, 1000)
            },
        }
        self.report = {
            'schemaVersion': 1, 'configuration': 'release', 'sampleCount': 20,
            'warmupCount': 3, 'textUTF8Bytes': 248,
            'environment': {'operatingSystem': 'Synthetic test OS', 'processorCount': 4},
            'provenance': {
                'sourceRevision': 'a' * 40, 'workingTreeDirty': True,
                'sourceSHA256': 'b' * 64, 'budgetSHA256': 'c' * 64,
                'executableSHA256': 'd' * 64, 'runnerSHA256': 'e' * 64,
                'toolchain': 'Swift synthetic fixture', 'architecture': 'arm64',
                'capturedAtUTC': '2026-11-17T00:00:00+00:00',
            },
            'workloads': [
                {'recordCount': count, 'fixtureBytes': count * 400, 'roundTripVerified': True,
                 'operations': {
                     operation: {'samplesMilliseconds': list(range(1, 21)),
                                 'p50Milliseconds': 10, 'p95Milliseconds': 19}
                     for operation in ('list', 'save', 'delete')
                 }} for count in (100, 1000)
            ],
        }
        # Give list the same passing budget for the shared synthetic sample series.
        for limits in self.budgets['p95MillisecondsByRecordCount'].values():
            limits['list'] = 20

    def test_valid_report_recomputes_six_measurements(self):
        self.assertEqual(len(performance.validate(self.report, self.budgets)), 6)

    def test_over_budget_fails(self):
        self.budgets['p95MillisecondsByRecordCount']['1000']['save'] = 18
        with self.assertRaisesRegex(ValueError, 'exceeds'):
            performance.validate(self.report, self.budgets)

    def test_percentiles_cannot_hide_slow_raw_samples(self):
        self.report['workloads'][0]['operations']['list']['samplesMilliseconds'] = [100] * 20
        with self.assertRaisesRegex(ValueError, 'does not match raw samples'):
            performance.validate(self.report, self.budgets)

    def test_nan_infinity_negative_and_boolean_samples_fail(self):
        for invalid in (float('nan'), float('inf'), -1, True, '1', 10 ** 1000):
            with self.subTest(value=invalid):
                report = copy.deepcopy(self.report)
                report['workloads'][0]['operations']['save']['samplesMilliseconds'][0] = invalid
                with self.assertRaisesRegex(ValueError, 'finite'):
                    performance.validate(report, self.budgets)

    def test_missing_duplicate_unknown_workloads_fail(self):
        replacements = [self.report['workloads'][:1],
                        [self.report['workloads'][0]] * 2,
                        [dict(self.report['workloads'][0], recordCount=10), self.report['workloads'][1]]]
        for workloads in replacements:
            with self.subTest(workloads=workloads):
                report = dict(self.report, workloads=workloads)
                with self.assertRaises(ValueError):
                    performance.validate(report, self.budgets)

    def test_missing_operation_and_short_samples_fail(self):
        for mutation in ('operation', 'samples'):
            with self.subTest(mutation=mutation):
                report = copy.deepcopy(self.report)
                operations = report['workloads'][1]['operations']
                if mutation == 'operation':
                    del operations['delete']
                else:
                    operations['delete']['samplesMilliseconds'].pop()
                with self.assertRaises(ValueError):
                    performance.validate(report, self.budgets)

    def test_debug_small_workload_or_unverified_roundtrip_fail(self):
        for key, value in (('configuration', 'debug'), ('textUTF8Bytes', 8),
                           ('sampleCount', 19), ('warmupCount', 0)):
            with self.subTest(key=key):
                with self.assertRaises(ValueError):
                    performance.validate(dict(self.report, **{key: value}), self.budgets)
        self.report['workloads'][0]['roundTripVerified'] = False
        with self.assertRaisesRegex(ValueError, 'correctness'):
            performance.validate(self.report, self.budgets)

    def test_nonfinite_or_missing_budgets_fail(self):
        for invalid in (float('nan'), float('inf'), 0, True):
            with self.subTest(value=invalid):
                budgets = copy.deepcopy(self.budgets)
                budgets['p95MillisecondsByRecordCount']['1000']['delete'] = invalid
                with self.assertRaises(ValueError):
                    performance.validate(self.report, budgets)
        del self.budgets['p95MillisecondsByRecordCount']['1000']
        with self.assertRaisesRegex(ValueError, 'Budgets must cover'):
            performance.validate(self.report, self.budgets)

    def test_different_budget_or_missing_provenance_fail(self):
        with self.assertRaisesRegex(ValueError, 'different budgets'):
            performance.validate(self.report, self.budgets, 'f' * 64)
        del self.report['provenance']['sourceSHA256']
        with self.assertRaises(KeyError):
            performance.validate(self.report, self.budgets)

    def test_json_constants_and_duplicate_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            for invalid in ('{"x": NaN}', '{"x": Infinity}', '{"x": 1, "x": 2}'):
                with self.subTest(invalid=invalid):
                    path.write_text(invalid)
                    with self.assertRaises(ValueError):
                        performance.load_json(path)
            path.write_text(json.dumps(self.report))
            self.assertEqual(performance.load_json(path), self.report)


if __name__ == '__main__':
    unittest.main()
