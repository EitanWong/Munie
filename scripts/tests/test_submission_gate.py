"""Real shell failure propagation with synthetic tools; no Apple build or model execution."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


class SubmissionGateTests(unittest.TestCase):
    def test_failed_submission_experiment_stops_quality_before_benchmark_and_build(self):
        with tempfile.TemporaryDirectory(prefix='munie-submission-gate-') as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / '.tools').mkdir()
            (root / 'bin').mkdir()
            shutil.copyfile(SCRIPTS / 'check.sh', root / 'scripts/check.sh')
            (root / 'scripts/check-repository.py').write_text('pass\n')
            programs = {
                'scripts/bootstrap.sh': 'exit 0',
                'scripts/check-submissions.sh': 'echo "Fixture: submission experiment rejected" >&2\nexit 31',
                'scripts/benchmark-core.sh': 'touch benchmark-ran',
                'scripts/build-apple-platforms.sh': 'touch build-ran',
                '.tools/actionlint': 'exit 0', 'bin/swift': 'exit 0', 'bin/xcrun': 'exit 0',
            }
            for name, body in programs.items():
                path = root / name
                path.write_text('#!/bin/sh\n' + body + '\n')
                path.chmod(0o755)
            result = subprocess.run(['bash', str(root / 'scripts/check.sh')],
                                    env=dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.defpath),
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 31)
            self.assertEqual(result.stdout, '')
            self.assertEqual(result.stderr, 'Fixture: submission experiment rejected\n')
            self.assertFalse((root / 'benchmark-ran').exists())
            self.assertFalse((root / 'build-ran').exists())

    def test_failed_build_invalidates_previous_success_report(self):
        with tempfile.TemporaryDirectory(prefix='munie-submission-build-') as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'build').mkdir()
            (root / 'bin').mkdir()
            shutil.copyfile(SCRIPTS / 'check-submissions.sh', root / 'scripts/check-submissions.sh')
            report = root / 'build/submission-ledger-probe.json'
            report.write_text('{"status":"passed"}')
            swift = root / 'bin/swift'
            swift.write_text('#!/bin/sh\necho "Fixture: compiler failed" >&2\nexit 19\n')
            swift.chmod(0o755)
            result = subprocess.run(['bash', str(root / 'scripts/check-submissions.sh')],
                                    env=dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.defpath),
                                    capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Fixture: compiler failed', result.stderr)
            self.assertFalse(report.exists(), 'An old passing experiment survived a failed compile')


if __name__ == '__main__':
    unittest.main()
