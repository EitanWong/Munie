"""Offline product-acceptance gates and cleanup; no actual Codex or device execution."""

from pathlib import Path
from unittest.mock import Mock, patch
import contextlib
import io
import shlex
import copy
import hashlib
import importlib.util
import json
import plistlib
import signal
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import unquote, urlsplit

SOURCE = Path(__file__).resolve().parents[1] / 'accept-iphone-product.py'
SPEC = importlib.util.spec_from_file_location('acceptance', SOURCE)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
REMOTE_SOURCE = SOURCE.with_name('accept-remote-product.py')
REMOTE_SPEC = importlib.util.spec_from_file_location('remote_product_acceptance', REMOTE_SOURCE)
REMOTE = importlib.util.module_from_spec(REMOTE_SPEC)
REMOTE_SPEC.loader.exec_module(REMOTE)
REAL_POPEN = subprocess.Popen
PAIR_ID = '0fcf80c4-5f0e-42a7-8f9b-ac83e370a36a'
TASK_ID = '58f04227-75ea-44c1-8f7a-93bb428ec364'
FINGERPRINT = 'f' * 16

class Host:
    def __init__(self, fingerprint=FINGERPRINT):
        self.fingerprint = fingerprint
        self.approved = False
    def command(self, op, **fields):
        if op == 'candidate':
            return {'candidate': {'id': PAIR_ID, 'fingerprint': self.fingerprint}}
        if op == 'approvePairing':
            self.approved = True
            return {'event': 'paired'}
        raise AssertionError(op)

class BrokenSelector:
    def register(self, *args):
        raise OSError('synthetic registration failure')
    def close(self):
        self.closed = True

class AcceptanceToolingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='munie-offline-tooling-')
        self.root = Path(self.temp.name)
        self.children = []
    def tearDown(self):
        for child in self.children:
            M.stop_process(child)
            for stream in (child.stdin, child.stdout):
                if stream:
                    stream.close()
        self.temp.cleanup()
    def launch(self, code):
        def start(command, **kwargs):
            child = REAL_POPEN([sys.executable, '-c', code], **kwargs)
            self.children.append(child)
            return child
        return start
    def phase(self, *, code, host=None, approve=True, record=None):
        if record is None:
            record = {}
        with patch.object(M.subprocess, 'Popen', self.launch(code)):
            return M.run_device_phase(xctestrun=self.root/'fixture.xctestrun', device='fixture-device',
                selector='RemoteDeviceAcceptanceTests/testPairSubmitRealTask', result_path=self.root/'result',
                log_path=self.root/'phase.log', timeout=2, host=host or Host(), project_id='fixture',
                invitation_json='PRIVATE_FIXTURE_INVITATION', approve=approve, record=record)
    def test_digest_matches_sha256_on_default_python(self):
        self.assertEqual(M.digest(SOURCE), hashlib.sha256(SOURCE.read_bytes()).hexdigest())
    def test_clone_keeps_only_app_hosted_bundle_and_input(self):
        original = {'MunieTests': {'IsAppHostedTestBundle': True, 'DependentProductPaths':
            ['__TESTROOT__/Munie.app', '__TESTROOT__/MunieUITests-Runner.app'],
            'TestingEnvironmentVariables': {'DYLD_INSERT_LIBRARIES': 'fixture'},
            'SkipTestIdentifiers': ['unrelated']}, 'MunieUITests': {},
            '__xctestrun_metadata__': {'FormatVersion': 1,
            'CodeCoverageBuildableInfos': [{'Name': 'MunieTests'}, {'Name': 'MunieUITests'}]}}
        before = copy.deepcopy(original)
        result = M.prepare_test_run(original, {'PRIVATE': 'fixture'}, 'Class/test')
        self.assertEqual(original, before)
        self.assertEqual(set(result), {'MunieTests', '__xctestrun_metadata__'})
        test = result['MunieTests']
        self.assertEqual(test['OnlyTestIdentifiers'], ['Class/test'])
        self.assertNotIn('SkipTestIdentifiers', test)
        self.assertEqual(test['DependentProductPaths'], ['__TESTROOT__/Munie.app'])
        self.assertEqual(test['TestingEnvironmentVariables'], {'DYLD_INSERT_LIBRARIES': 'fixture'})
        self.assertEqual(test['EnvironmentVariables'], {'PRIVATE': 'fixture'})
        self.assertEqual(result['__xctestrun_metadata__']['CodeCoverageBuildableInfos'], [{'Name': 'MunieTests'}])
    def test_unreviewed_format_is_rejected(self):
        with self.assertRaises(ValueError):
            M.prepare_test_run({'__xctestrun_metadata__': {'FormatVersion': 2}}, {}, 'Class/test')
    def test_private_write_and_collision_preserve_original(self):
        path = self.root/'private'
        M.write_private(path, b'original')
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            M.write_private(path, b'replacement')
        self.assertEqual(path.read_bytes(), b'original')
    def test_report_replace_failure_removes_temporary_and_keeps_report(self):
        report = self.root/'report.json'
        report.write_text('existing')
        with patch.object(M.os, 'replace', side_effect=OSError('fixture')):
            with self.assertRaises(OSError):
                M.save_report(report, {'status': 'passed'})
        self.assertEqual(report.read_text(), 'existing')
        self.assertEqual(list(self.root.iterdir()), [report])
    def test_real_model_flag_is_required_before_start(self):
        command = [sys.executable, str(SOURCE), '--service', '/fixture', '--codex', '/fixture',
                   '--guardian', '/fixture', '--xctestrun', '/fixture', '--output', str(self.root/'report'),
                   '--device', 'fixture-device', '--endpoint', 'https://fixture.invalid']
        result = subprocess.run(command, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b'--allow-real-model is required', result.stderr)
        self.assertFalse((self.root/'report').exists())
    def test_matching_pairing_and_typed_result_are_accepted(self):
        host, record = Host(), {}
        code = 'print("MUNIE_DEVICE_PAIR %s %s", flush=True); print("MUNIE_DEVICE_RESULT %s 101 completed", flush=True)' % (PAIR_ID, FINGERPRINT, TASK_ID)
        result = self.phase(code=code, host=host, record=record)
        self.assertTrue(host.approved)
        self.assertEqual(result['taskID'], TASK_ID)
        self.assertEqual(result['appPID'], 101)
        self.assertEqual(record['xcodebuildExitStatus'], 0)
        self.assertTrue(record['processGroupGone'])
    def test_different_fingerprint_is_denied_and_process_reaped(self):
        host, record = Host('e'*16), {}
        code = 'import time; print("MUNIE_DEVICE_PAIR %s %s", flush=True); time.sleep(30)' % (PAIR_ID, FINGERPRINT)
        with self.assertRaisesRegex(RuntimeError, 'do not match'):
            self.phase(code=code, host=host, record=record)
        self.assertFalse(host.approved)
        self.assertTrue(record['processGroupGone'])
        self.assertIsNotNone(self.children[0].returncode)
    def test_conflicting_results_in_same_chunk_are_denied(self):
        record = {}
        code = 'print("MUNIE_DEVICE_RECOVERED %s 101 completed\\nMUNIE_DEVICE_RECOVERED %s 102 completed", flush=True)' % (TASK_ID, TASK_ID)
        with self.assertRaisesRegex(RuntimeError, 'inconsistent'):
            self.phase(code=code, approve=False, record=record)
        self.assertTrue(record['processGroupGone'])
    def test_test_process_selector_failure_is_reaped(self):
        record = {}
        with patch.object(M.selectors, 'DefaultSelector', BrokenSelector):
            with self.assertRaisesRegex(OSError, 'registration'):
                self.phase(code='import time; time.sleep(30)', record=record)
        self.assertTrue(record['processGroupGone'])
        self.assertTrue(self.children[0].stdout.closed)
    def test_host_process_selector_failure_is_reaped(self):
        with patch.object(M.subprocess, 'Popen', self.launch('import time; time.sleep(30)')):
            with patch.object(M.selectors, 'DefaultSelector', BrokenSelector):
                with self.assertRaisesRegex(OSError, 'registration'):
                    M.LocalHost(Path('/fixture'), Path('/fixture'), self.root/'host.stderr')
        self.assertIsNotNone(self.children[0].returncode)
        self.assertTrue(M.group_gone(self.children[0].pid))
        self.assertTrue(self.children[0].stdout.closed)
        self.assertTrue(self.children[0].stdin.closed)
    def test_host_quit_closes_streams_and_process_group(self):
        code = 'import sys,json; value=json.loads(sys.stdin.readline()); assert value["op"] == "quit"; print(json.dumps({"event":"closed"}), flush=True)'
        with patch.object(M.subprocess, 'Popen', self.launch(code)):
            host = M.LocalHost(Path('/fixture'), Path('/fixture'), self.root/'host.stderr')
            result = host.finish()
        self.assertEqual(result, {'graceful': True, 'processGroupGone': True, 'exitStatus': 0})
        self.assertTrue(host.stderr.closed)
        self.assertTrue(host.closed)

    def test_exiting_leader_permission_race_requires_reap_and_group_disappearance(self):
        process = Mock(pid=43210)
        process.poll.side_effect = [None, 0]
        def signal_group(_pid, requested_signal):
            if requested_signal == signal.SIGTERM:
                raise PermissionError()
            raise ProcessLookupError()
        with patch.object(M.os, 'killpg', side_effect=signal_group):
            self.assertTrue(M.stop_process(process))
        process.wait.assert_called_once_with(timeout=5)

    def test_permission_denial_for_a_live_group_is_not_success(self):
        process = Mock(pid=43210)
        process.poll.return_value = 0
        with patch.object(M.os, 'killpg', side_effect=PermissionError()):
            self.assertFalse(M.stop_process(process))

class AcceptanceGateTests(unittest.TestCase):
    def test_iphone_endpoint_requires_an_explicit_origin(self):
        command = [str(SOURCE), '--allow-real-model', '--service', '/fixture', '--codex', '/fixture',
                   '--guardian', '/fixture', '--xctestrun', '/fixture', '--output', '/fixture-report',
                   '--device', 'fixture-device']
        stderr = io.StringIO()
        with patch.object(sys, 'argv', command), contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as raised:
                M.arguments()
        self.assertEqual(raised.exception.code, 2)
        self.assertIn('--endpoint', stderr.getvalue())

    def test_invalid_iphone_endpoint_is_rejected_before_execution(self):
        for endpoint in ('http://fixture.invalid', 'https://owner:secret@fixture.invalid',
                         'https://fixture.invalid/path', 'https://fixture.invalid?token=fixture'):
            with self.subTest(endpoint=endpoint):
                command = [str(SOURCE), '--allow-real-model', '--service', '/fixture', '--codex', '/fixture',
                           '--guardian', '/fixture', '--xctestrun', '/fixture', '--output', '/fixture-report',
                           '--device', 'fixture-device', '--endpoint', endpoint]
                with patch.object(sys, 'argv', command), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        M.arguments()
                self.assertEqual(raised.exception.code, 2)

    def test_host_acceptance_requires_real_model_authorization_before_launch(self):
        command = [str(REMOTE_SOURCE), '--service', '/fixture', '--codex', '/fixture',
                   '--guardian', '/fixture', '--output', '/fixture-report']
        stderr = io.StringIO()
        with patch.object(sys, 'argv', command), patch.object(REMOTE.subprocess, 'Popen') as start:
            with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
                REMOTE.main()
        self.assertEqual(raised.exception.code, 2)
        self.assertIn('--allow-real-model', stderr.getvalue())
        start.assert_not_called()

    def test_iphone_temporary_configuration_uses_canonical_directory(self):
        with tempfile.TemporaryDirectory(prefix='munie-canonical-acceptance-') as directory:
            root = Path(directory).resolve()
            original = {'MunieTests': {'IsAppHostedTestBundle': True},
                        '__xctestrun_metadata__': {'FormatVersion': 1}}
            signed = root / 'signed.xctestrun'
            signed.write_bytes(plistlib.dumps(original))
            report = root / 'report.json'
            # Model /var -> /private/var with an ordinary fixture symlink on any host.
            canonical = root / 'canonical'
            canonical.mkdir()
            alias = root / 'alias'
            alias.symlink_to(canonical, target_is_directory=True)
            temporary = Mock(name=str(alias))
            temporary.name = str(alias)
            temporary.cleanup.side_effect = lambda: alias.unlink()
            command = [str(SOURCE), '--allow-real-model', '--service', sys.executable,
                       '--codex', sys.executable, '--guardian', sys.executable,
                       '--xctestrun', str(signed), '--output', str(report),
                       '--device', 'fixture-device', '--endpoint', 'https://fixture.invalid']
            captured = {}
            def inspect_configuration(_executable, configuration, _stderr):
                captured.update(json.loads(configuration.read_bytes()))
                raise RuntimeError('Stop before any actual host/model/device launch.')
            with patch.object(sys, 'argv', command), patch.object(M.tempfile, 'TemporaryDirectory', return_value=temporary):
                with patch.object(M.subprocess, 'run'), patch.object(M, 'LocalHost', side_effect=inspect_configuration):
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(M.main(), 1)
            self.assertTrue(captured)
            for field in ('codexHome', 'stateDirectory'):
                path = Path(unquote(urlsplit(captured[field]).path))
                self.assertEqual(path.parent, canonical)
            project = Path(unquote(urlsplit(captured['projects'][0]['directory']).path))
            self.assertEqual(project.parent, canonical)
            self.assertEqual(json.loads(report.read_bytes())['stage'], 'host-start')
            self.assertEqual(signed.read_bytes(), plistlib.dumps(original))


class HostAcceptanceExitTests(unittest.TestCase):
    def test_failed_account_cleanup_returns_failure_after_successful_synthetic_journey(self):
        with tempfile.TemporaryDirectory(prefix='munie-synthetic-acceptance-') as directory:
            output = Path(directory).resolve() / 'report.json'
            tasks = []
            state = {'project': None, 'serviceStarts': 0}
            text_marker = 'MUNIE_REAL_TEXT_OK'
            continue_marker = 'MUNIE_REAL_CONTINUED_OK'
            approved_command = "printf 'MUNIE_APPROVED\\n' > approved.txt"
            cancel_command = "printf 'MUNIE_RUNNING\\n' > running.txt; sleep 30; printf 'MUNIE_AFTER_WAIT\\n' > after-wait.txt"
            def request(_url, payload):
                op = payload['op']
                if op == 'pair':
                    state['pair'] = payload
                    return {'pairingState': 'pending'}
                if op == 'pairStatus':
                    return {'credential': 'fixture-credential'}
                if op == 'status':
                    return {'status': {'projects': [{'id': state['projectID']}], 'tasks': tasks}}
                if op == 'submit':
                    existing = next((task for task in tasks if task['requestID'] == payload['requestID']), None)
                    if existing:
                        return {'task': existing}
                    if 'taskID' in payload:
                        task = next(task for task in tasks if task['id'] == payload['taskID'])
                        task['requestID'] = payload['requestID']
                        task['messages'].append({'role': 'assistant', 'text': continue_marker})
                    else:
                        task = {'id': 'fixture-task-' + str(len(tasks)), 'requestID': payload['requestID'],
                                'phase': 'completed', 'messages': [{'role': 'assistant', 'text': text_marker}]}
                        if len(tasks) >= 1:
                            task.update({'phase': 'awaitingApproval', 'approval': {'id': 'fixture-approval',
                                'command': approved_command if len(tasks) == 1 else cancel_command,
                                'cwd': str(state['project'])}})
                        tasks.append(task)
                    return {'task': task}
                task = next(task for task in tasks if task['id'] == payload['taskID'])
                if op == 'approve':
                    task['approval'] = None
                    if task is tasks[1]:
                        (state['project'] / 'approved.txt').write_text('MUNIE_APPROVED\n')
                        task['phase'] = 'completed'
                    else:
                        (state['project'] / 'running.txt').write_text('MUNIE_RUNNING\n')
                        task['phase'] = 'running'
                    return {'task': task}
                if op == 'cancel':
                    task.update({'phase': 'cancelled', 'cancellationRequested': True})
                    return {'task': task}
                raise AssertionError(op)
            opener = Mock()
            def open_request(value, **_kwargs):
                reply = json.dumps(request(value.full_url, json.loads(value.data))).encode()
                stream = io.BytesIO(reply)
                return stream
            opener.open.side_effect = open_request
            def service(command, **_kwargs):
                config = json.loads(Path(command[-1]).read_bytes())
                state.update({'project': Path(unquote(urlsplit(config['projects'][0]['directory']).path)),
                              'projectID': config['projects'][0]['id']})
                Path(unquote(urlsplit(config['codexHome']).path)).mkdir(exist_ok=True)
                state['serviceStarts'] += 1
                process = Mock(returncode=None)
                process.poll.side_effect = lambda: process.returncode
                def wait(**_kwargs):
                    process.returncode = 0
                    return 0
                process.wait.side_effect = wait
                replies = [{'event': 'ready', 'port': 12345}]
                def write(line):
                    op = json.loads(line)['op']
                    if op == 'invite':
                        replies.append({'invitation': {'secret': 'fixture'}})
                    elif op == 'candidate':
                        pair = state['pair']
                        replies.append({'candidate': {'id': pair['pairingID'],
                            'fingerprint': hashlib.sha256(pair['pairingSecret'].encode()).hexdigest()[:16]}})
                    elif op == 'approvePairing':
                        replies.append({'event': 'paired'})
                    elif op == 'diagnostics':
                        replies.append({'diagnostics': {'groupGone': True, 'stdoutEOF': True, 'stderrEOF': True}})
                    elif op == 'quit':
                        replies.append({'event': 'closed'})
                    else:
                        raise AssertionError(op)
                process.stdin.write.side_effect = write
                process.stdout.readline.side_effect = lambda: json.dumps(replies.pop(0)) + '\n'
                return process
            database = Mock()
            database.execute.return_value.fetchall.return_value = [('thread', 'turn1'), ('thread', 'turn2')]
            database.execute.return_value.fetchone.return_value = (4,)
            command = [str(REMOTE_SOURCE), '--allow-real-model', '--service', sys.executable,
                       '--codex', sys.executable, '--guardian', sys.executable, '--output', str(output)]
            with patch.object(sys, 'argv', command), patch.object(REMOTE.subprocess, 'Popen', side_effect=service):
                with patch.object(REMOTE.subprocess, 'check_output', return_value='fixture-revision'):
                    with patch.object(REMOTE.urllib.request, 'build_opener', return_value=opener):
                        with patch.object(REMOTE.select, 'select', return_value=([True], [], [])):
                            with patch.object(REMOTE.sqlite3, 'connect', return_value=database), patch.object(REMOTE.time, 'sleep'):
                                with patch.object(REMOTE.shutil, 'rmtree', side_effect=OSError('fixture cleanup failure')):
                                    with contextlib.redirect_stdout(io.StringIO()):
                                        self.assertEqual(REMOTE.main(), 1)
            report = json.loads(output.read_bytes())
            self.assertEqual(state['serviceStarts'], 2)
            self.assertEqual(len(report['checks']), 7)
            self.assertFalse(report['passed'])
            self.assertIn('cleanupFailure', report)
            self.assertEqual(report['serviceExit'], 0)


class ExactMarkerCommandTests(unittest.TestCase):
    command = "printf 'MUNIE_APPROVED\\n' > approved.txt"

    def test_exact_body_and_reviewed_shell_wrappers_are_accepted(self):
        self.assertTrue(REMOTE.exact_marker_command(self.command, self.command))
        for shell in ('/bin/zsh', '/bin/bash', '/bin/sh'):
            for mode in ('-c', '-lc'):
                with self.subTest(shell=shell, mode=mode):
                    observed = shell + ' ' + mode + ' ' + shlex.quote(self.command)
                    self.assertTrue(REMOTE.exact_marker_command(observed, self.command))

    def test_body_changes_and_injected_commands_are_denied(self):
        for body in (self.command + '; touch injected', self.command + '\ntrue',
                     'true; ' + self.command, self.command.replace(' > ', '  > '),
                     self.command + ' $(touch injected)', self.command + ' #fixture'):
            for observed in (body, '/bin/sh -c ' + shlex.quote(body)):
                with self.subTest(observed=observed):
                    self.assertFalse(REMOTE.exact_marker_command(observed, self.command))

    def test_unreviewed_launchers_arguments_and_malformed_quotes_are_denied(self):
        quoted = shlex.quote(self.command)
        for observed in ('/usr/bin/env sh -c ' + quoted, '/bin/fish -c ' + quoted,
                         '/bin/sh --command ' + quoted, '/bin/sh -c ' + quoted + ' extra',
                         '/bin/sh -c ' + quoted + '; touch injected',
                         '/bin/sh -c \"unterminated', '/bin/sh -c "$PAYLOAD"'):
            with self.subTest(observed=observed):
                self.assertFalse(REMOTE.exact_marker_command(observed, self.command))


if __name__ == '__main__':
    unittest.main()
