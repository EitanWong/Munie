"""Offline failures and evidence semantics; no Apple Security function executes."""

from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'probe-identity-sdk.py'
SPEC = importlib.util.spec_from_file_location('identity_sdk_probe', SCRIPT)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class EvidenceTests(unittest.TestCase):
    def test_similar_symbol_or_comment_does_not_claim_public_api(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            framework = root / 'SDK/System/Library/Frameworks/Security.framework'
            headers = framework / 'Headers'
            headers.mkdir(parents=True)
            (headers / 'SecIdentity.h').write_text(
                '/* SecIdentityRef SecIdentityCreate(CFAllocatorRef allocator); */\n'
                'SecIdentityRef SecIdentityCreateWithCertificate(CFAllocatorRef allocator);\n')
            (framework / 'Security.tbd').write_text('symbols: [ _SecIdentityCreateWithCertificate ]\n')
            evidence = root / 'evidence'
            evidence.mkdir()
            result = probe.public_evidence(root / 'SDK', evidence)
            self.assertFalse(result['publicDeclaration'])
            self.assertFalse(result['exportedSymbol'])
            self.assertEqual((evidence / 'SecIdentity.h').read_bytes(),
                             (headers / 'SecIdentity.h').read_bytes())

    def test_compile_failure_completes_probe_without_claiming_availability(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / 'SDK'
            sdk.mkdir()
            compiler = root / 'swiftc'
            compiler.touch()
            project = root / 'project.yml'
            project.write_text("  deploymentTarget:\n    iOS: '18.0'\n    macOS: '15.0'\n"
                               "    watchOS: '11.0'\n    tvOS: '18.0'\n    visionOS: '2.0'\n")
            output = root / 'out'
            output.mkdir()
            report = {'commands': [], 'sdks': []}
            commands = []

            def tool(argv, *_args):
                if '--find' in argv:
                    return str(compiler)
                return str(sdk) if '--show-sdk-path' in argv else 'synthetic tool version'

            def compile_link(argv, *_args, **_kwargs):
                commands.append(argv)
                return {'exitStatus': 1}, b''

            with patch.object(probe, 'tool_value', side_effect=tool), \
                    patch.object(probe, 'run_command', side_effect=compile_link), \
                    patch.object(probe, 'public_evidence', return_value={
                        'publicDeclaration': True, 'exportedSymbol': True}):
                probe.probe(output, report, project)
            self.assertTrue(report['probeCompleted'])
            self.assertFalse(report['allAvailable'])
            self.assertEqual(len(report['sdks']), 6)
            self.assertTrue(all(not item['available'] for item in report['sdks']))
            self.assertTrue(all(item['unavailableReasons'] == ['compile-or-link-failed']
                                for item in report['sdks']))
            self.assertTrue(all('-emit-library' in argv and '-framework' in argv for argv in commands))
            self.assertTrue(all('-warnings-as-errors' in argv for argv in commands))
            self.assertIn('arm64-apple-ios18.0-simulator', [item['target'] for item in report['sdks']])

    def test_existing_output_is_preserved_and_prevents_tool_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = b'old-evidence'
            (root / 'report.json').write_bytes(original)
            with patch.object(probe.sys, 'argv', ['probe', '--output-dir', str(root)]), \
                    patch.object(probe, 'probe') as execute, redirect_stdout(io.StringIO()):
                self.assertEqual(probe.main(), 2)
            execute.assert_not_called()
            self.assertEqual((root / 'report.json').read_bytes(), original)

    def test_execution_error_is_failure_and_saved_report_is_reopenable(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'new'
            with patch.object(probe.sys, 'argv', ['probe', '--output-dir', str(output)]), \
                    patch.object(probe, 'probe', side_effect=probe.ProbeFailure('tool-nonzero-sdk-path')), \
                    redirect_stdout(io.StringIO()):
                self.assertEqual(probe.main(), 1)
            report = json.loads((output / 'report.json').read_bytes())
            self.assertFalse(report['probeCompleted'])
            self.assertFalse(report['allAvailable'])
            self.assertEqual(report['failure'], 'tool-nonzero-sdk-path')


class RealProcessTests(unittest.TestCase):
    def test_sigterm_during_command_reaps_child_and_preserves_failure_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / 'evidence'
            marker = root / 'child-started'
            child_source = ('import os,pathlib,time;'
                            f'pathlib.Path({str(marker)!r}).write_text(str(os.getpid()));'
                            'time.sleep(30)')
            source = ('import importlib.util,sys,time\n'
                      f's=importlib.util.spec_from_file_location("probe",{str(SCRIPT)!r})\n'
                      'm=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n'
                      'def probe(output,report,project):\n'
                      f' m.run_command([sys.executable,"-c",{child_source!r}],'
                      'output,"silent",report,time.monotonic()+40)\n'
                      'm.probe=probe\n'
                      f'sys.argv=["probe","--output-dir",{str(output)!r}]\n'
                      'sys.exit(m.main())\n')
            process = subprocess.Popen([sys.executable, '-c', source], stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(marker.exists(), 'Synthetic command did not start')
                process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 1)
                self.assertEqual(stderr, b'')
                report = json.loads((output / 'report.json').read_bytes())
                self.assertFalse(json.loads(stdout)['probeCompleted'])
                self.assertEqual(report['failure'], 'runner-terminated')
                self.assertFalse(report['allAvailable'])
                self.assertTrue(report['commands'][0]['processGroupGone'])
                self.assertIsNotNone(report['commands'][0]['exitStatus'])
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=3)
                if marker.exists():
                    try:
                        os.killpg(int(marker.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_nonzero_compiler_status_preserves_literal_streams(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = {'commands': []}
            result, stdout = probe.run_command(
                [sys.executable, '-c', 'import sys;print("out");print("err",file=sys.stderr);sys.exit(7)'],
                root, 'compile', report, time.monotonic() + 5)
            self.assertEqual(result['exitStatus'], 7)
            self.assertEqual(stdout, b'out\n')
            self.assertEqual((root / 'compile.stderr.txt').read_bytes(), b'err\n')
            self.assertTrue(result['streamsReachedEOF'])
            self.assertTrue(result['processGroupGone'])

    def test_timeout_and_output_flood_are_tool_failures_with_cleanup(self):
        for source, seconds, failure in (
                ('import time;time.sleep(30)', .1, 'command-deadline'),
                ('import os;os.write(1,b"x"*300000)', 4, 'command-output-limit')):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                report = {'commands': []}
                root = Path(directory)
                with self.assertRaises(probe.ProbeFailure) as raised:
                    probe.run_command([sys.executable, '-c', source], root, 'bad', report,
                                      time.monotonic() + 6, seconds=seconds)
                self.assertEqual(raised.exception.code, failure)
                record = report['commands'][0]
                self.assertTrue(record['processGroupGone'])
                self.assertIsNotNone(record['exitStatus'])
                self.assertLessEqual((root / 'bad.stdout.txt').stat().st_size, probe.MAX_STREAM_BYTES)


if __name__ == '__main__':
    unittest.main()
