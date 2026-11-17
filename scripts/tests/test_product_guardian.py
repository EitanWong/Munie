"""Runner safety and actual product-guardian subprocess regressions; synthetic peers only."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / 'probe-product-guardian.py'
SPEC = importlib.util.spec_from_file_location('munie_product_guardian_probe', SOURCE)
PROBE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROBE
SPEC.loader.exec_module(PROBE)


class RunnerValidationTests(unittest.TestCase):
    def test_executable_and_report_paths_are_explicit_and_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            missing = root / 'missing'
            for path in (Path('relative-guardian'), missing, root):
                with self.subTest(path=path), self.assertRaises(PROBE.ProbeError):
                    PROBE.validate_guardian(path)
            guardian = PROBE.validate_guardian(Path('/bin/sh'))
            for path in (Path('relative.json'), guardian, root):
                with self.subTest(output=path), self.assertRaises(PROBE.ProbeError):
                    PROBE.validate_output(path, guardian)
            alias = root / 'binary-alias'
            alias.symlink_to(guardian)
            with self.assertRaises(PROBE.ProbeError):
                PROBE.validate_output(alias, guardian)

    def test_reused_pid_is_not_a_signal_identity(self):
        original = PROBE.Identity(42, 1, 42, 100, 123)
        replacement = PROBE.Identity(42, 1, 42, 100, 124)
        self.assertFalse(original.same_process(replacement))
        self.assertFalse(original.same_process(None))
        self.assertTrue(original.same_process(PROBE.Identity(42, 99, 42, 100, 123)))
        table = object.__new__(PROBE.ProcessTable)
        with mock.patch.object(table, 'identity', return_value=replacement), mock.patch.object(PROBE.os, 'kill') as kill:
            with self.assertRaises(PROBE.ProbeError):
                table.signal_identity(original, 9)
            kill.assert_not_called()

    def test_group_cleanup_requires_a_live_recorded_start_identity(self):
        table = object.__new__(PROBE.ProcessTable)
        original = PROBE.Identity(42, 1, 42, 100, 123)
        replacement = PROBE.Identity(42, 1, 42, 101, 123)
        with mock.patch.object(table, 'members', return_value=[replacement]), mock.patch.object(PROBE.os, 'killpg') as kill:
            with self.assertRaises(PROBE.ProbeError):
                table.clean_group(42, [original])
            kill.assert_not_called()

    def test_reports_replace_stale_success_atomically_and_privately(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'report.json'
            report.write_text('{"status":"passed","stale":true}')
            PROBE.write_report(report, {'status': 'failed', 'phase': 'starting'})
            self.assertEqual(json.loads(report.read_bytes()), {'status': 'failed', 'phase': 'starting'})
            self.assertEqual(stat.S_IMODE(report.stat().st_mode), 0o600)
            self.assertEqual(list(report.parent.glob('.report.json.*')), [])

    def test_fixture_records_reject_symlinks_and_oversized_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'target'
            target.write_bytes(b'x' * (PROBE.MAXIMUM_FILE_BYTES + 1))
            with self.assertRaises(PROBE.ProbeError):
                PROBE.read_small(target)
            alias = root / 'alias'
            alias.symlink_to(target)
            with self.assertRaises(PROBE.ProbeError):
                PROBE.read_small(alias)

    def test_cli_rejects_relative_binary_before_launching_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory).resolve() / 'report.json'
            result = subprocess.run([sys.executable, '-I', str(SOURCE), '--guardian', 'relative', '--output', str(report)],
                                    capture_output=True, timeout=5, check=False)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, b'')
            self.assertEqual(result.stderr, b'absolute-executable-guardian-required\n')
            self.assertFalse(report.exists())

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS libproc process fixture')
    def test_failed_subprocess_fixture_retains_failure_and_cleans_owned_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory).resolve() / 'failure.json'
            report.write_text('{"status":"passed","stale":true}')
            # /usr/bin/false is an actual failing subprocess, not a simulated guardian result.
            result = subprocess.run([sys.executable, '-I', str(SOURCE), '--guardian', '/usr/bin/false', '--output', str(report)],
                                    capture_output=True, timeout=15, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertEqual((result.stdout, result.stderr), (b'', b''))
            evidence = json.loads(report.read_bytes())
            try:
                self.assertEqual(evidence['status'], 'failed')
                self.assertNotIn('stale', evidence)
                self.assertEqual(evidence['failedPhase'], 'normal-exit')
                self.assertEqual(evidence['cases'][0]['status'], 'failed')
                self.assertTrue(all(row.get('directChildReaped', row.get('groupGone', False)) for row in evidence['cleanup']))
                self.assertTrue(Path(evidence['retainedFixture']).is_dir())
            finally:
                if 'retainedFixture' in evidence:
                    shutil.rmtree(evidence['retainedFixture'])

    @unittest.skipUnless(sys.platform == 'darwin' and os.environ.get('MUNIE_PRODUCT_GUARDIAN'),
                         'explicit MUNIE_PRODUCT_GUARDIAN binary required')
    def test_explicit_product_binary_passes_all_actual_process_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory).resolve() / 'actual.json'
            result = subprocess.run([sys.executable, '-I', str(SOURCE), '--guardian', os.environ['MUNIE_PRODUCT_GUARDIAN'], '--output', str(report)],
                                    capture_output=True, timeout=35, check=False)
            self.assertEqual(result.returncode, 0)
            self.assertEqual((result.stdout, result.stderr), (b'', b''))
            evidence = json.loads(report.read_bytes())
            self.assertEqual(evidence['status'], 'passed')
            self.assertEqual([case['name'] for case in evidence['cases']], [
                'normal-exit', 'owner-death', 'leader-exit-with-descendant', 'wrong-owner'])
            self.assertTrue(all(case['status'] == 'passed' and case['groupGone'] and case['unrelatedSentinelAlive'] for case in evidence['cases']))
            self.assertEqual(evidence['cases'][0]['guardianExitStatus'], 23)
            self.assertEqual(evidence['cases'][1]['ownerExitStatus'], -9)
            self.assertEqual(evidence['cases'][2]['guardianExitStatus'], 17)
            self.assertEqual(evidence['cases'][3]['guardianExitStatus'], 64)
            self.assertTrue(evidence['temporaryStateRemoved'])
            self.assertNotIn('retainedFixture', evidence)


if __name__ == '__main__':
    unittest.main()
