"""Offline acceptance-runner fixtures; never invoke a model, Xcode or a device."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid

SOURCE = Path(__file__).resolve().parents[1] / 'accept-remodex-device.py'
SPEC = importlib.util.spec_from_file_location('remodex_device_acceptance', SOURCE)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
RUN_ID = '8e5c7a01-e348-4844-97ba-0f74d5c64415'
THREAD_ID = '947897ae-9143-4b07-9528-969623851a40'
APPROVED_TURN = 'f467e369-b29e-4871-a4cf-3b17b99b668d'
CANCELLED_TURN = '9a2a8cb4-cbb3-4ed3-a62c-eb94b9684545'
CONTINUED_TURN = 'b5692374-f3d8-4d26-9101-e4b9bd6d2606'


class DeviceAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='munie-remodex-offline-')
        self.root = Path(self.temporary.name).resolve()
        self.products = self.root / 'build' / 'products'
        self.products.mkdir(parents=True)
        self.original = self.products / 'MunieRemodex_fixture.xctestrun'
        self.original_bytes = plistlib.dumps({
            '__xctestrun_metadata__': {'FormatVersion': 1},
            'MunieRemodexTests': {'EnvironmentVariables': {
                'TEST_RUNNER_REMODEX_ACCEPTANCE_PAIRING': 'unrelated-fixture'}},
            'MunieRemodexUITests': {}})
        self.original.write_bytes(self.original_bytes)
        native = self.root / 'apps/MunieHost/Transport/NativeCodexRuntime.swift'
        native.parent.mkdir(parents=True)
        native.write_text('private enum NativeCredentialStorage {}')
        self.paths = []
        self.commands = []
        self.configurations = []
        self.state = None
        self.project = None
        self.account = None

    def tearDown(self):
        for path in self.paths:
            if path.exists():
                shutil.rmtree(path)
        self.temporary.cleanup()

    def write_rollout(self, account, project, *, name='fixture', thread=THREAD_ID,
                      terminal='task_complete', extra=None):
        sessions = account / 'sessions/2026/11/18'
        sessions.mkdir(parents=True, exist_ok=True)
        rows = [
            {'type': 'session_meta', 'payload': {'id': thread, 'cwd': str(project),
                'personalHistory': 'DO_NOT_RETAIN_PERSONAL_HISTORY'}},
            {'type': 'event_msg', 'payload': {'type': 'task_started'}},
            {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user',
                'content': [{'type': 'input_text', 'text': M.PROMPT}]}},
            {'type': 'response_item', 'payload': {'type': 'message', 'role': 'assistant',
                'content': [{'type': 'output_text', 'text': M.MARKER}]}},
            {'type': 'event_msg', 'payload': {'type': terminal,
                'last_agent_message': M.MARKER, 'error': 'DO_NOT_RETAIN_ERROR_BODY'}}]
        if extra:
            rows.extend(extra)
        path = sessions / (name + '.jsonl')
        path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        return path

    def run_fixture(self, *, failure=None, cleanup_failure=False, cleanup_only=False,
                    omit_rollout=False, changed_recovery=False, preexisting_history=False,
                    with_controls=False, late_marker=False, wrong_cancel_terminal=False):
        def run(command, *, timeout, log, environment):
            self.commands.append(command)
            # No inherited acceptance authorization may enter a generated process environment.
            self.assertFalse(any('REMODEX_' in key for key in environment))
            name = log.stem
            record = {'command': command, 'exitStatus': 0, 'processGroupGone': True,
                      'log': str(log)}
            if name == 'prepare-account':
                self.account = Path(command[-2])
                self.paths.append(self.account.parent)
                self.account.mkdir(mode=0o700)
                (self.account / 'auth.json').write_text('DO_NOT_RETAIN_AUTH')
                if preexisting_history:
                    self.write_rollout(self.account, self.root / 'unrelated-project')
                log.write_text('Prepared private disposable account; no model called.\n')
            else:
                clone = Path(command[command.index('-xctestrun') + 1])
                value = plistlib.loads(clone.read_bytes())
                self.assertNotIn('MunieRemodexUITests', value)
                target = value['MunieRemodexTests']
                self.assertEqual(target['OnlyTestIdentifiers'], [M.SELECTOR])
                variables = target['EnvironmentVariables']
                self.configurations.append(variables)
                run_id = variables['REMODEX_ACCEPTANCE_RUN_ID']
                self.assertEqual(variables['REMODEX_ACCEPTANCE_AUTHORIZED'], 'disposable-project-only')
                if name == 'cleanup':
                    self.assertNotIn('REMODEX_ACCEPTANCE_PAIRING', variables)
                    self.assertNotIn('REMODEX_ACCEPTANCE_PROJECT', variables)
                    log.write_text('MUNIE_REMODEX_CLEANUP ' + run_id + '\n')
                else:
                    if name == 'submit' and not omit_rollout:
                        self.write_rollout(self.account, self.project)
                    reply = {
                        'mode': name, 'runID': run_id,
                        'threadID': str(uuid.uuid4()) if changed_recovery and name == 'recover' else THREAD_ID,
                        'pid': {'submit': 101, 'controls': 103, 'recover': 102}[name],
                        'previousPID': 0 if name == 'submit' else 101,
                        'encrypted': True, 'matchingUserMessages': 1, 'markerObserved': True}
                    if name == 'controls':
                        reply.update(approvalCount=2, approvalCommandMatched=True, approvalCwdMatched=True,
                            runningMarkerObserved=True, interruptionAcknowledged=True,
                            cancelledTerminalObserved=True, continuationMarkerObserved=True,
                            approvedTurnID=APPROVED_TURN, cancelledTurnID=CANCELLED_TURN,
                            continuedTurnID=CONTINUED_TURN)
                        for marker_name, content in M.CONTROL_MARKERS.items():
                            (self.project / marker_name).write_bytes(content)
                        if late_marker:
                            (self.project / M.CONTROL_LATE_MARKER).write_text('FORBIDDEN')
                        rollout = next((self.account / 'sessions').rglob('*.jsonl'))
                        with rollout.open('a') as output:
                            for turn, terminal in [(APPROVED_TURN, 'task_complete'),
                                (CANCELLED_TURN, 'task_complete' if wrong_cancel_terminal else 'turn_aborted'),
                                (CONTINUED_TURN, 'task_complete')]:
                                output.write(json.dumps({'type': 'event_msg', 'payload': {
                                    'type': 'task_started', 'turn_id': turn}}) + '\n')
                                output.write(json.dumps({'type': 'event_msg', 'payload': {
                                    'type': terminal, 'turn_id': turn,
                                    'last_agent_message': M.CONTINUATION_MARKER if turn == CONTINUED_TURN else ''}}) + '\n')
                    log.write_text('MUNIE_REMODEX_ACCEPTANCE ' + json.dumps(reply) + '\n')
            if name == failure or (name == 'cleanup' and cleanup_failure):
                record.update(exitStatus=65, failure='synthetic-failure')
            return record

        def launch(command, **_kwargs):
            self.project = Path(command[command.index('--project') + 1])
            self.state = Path(command[command.index('--state-dir') + 1])
            (self.state / 'device').mkdir()
            (self.state / 'device/pairing-session.json').write_text(json.dumps({
                'pairingPayload': {'fixture': 'NOT_A_REAL_PAIRING'}}))
            runtime = {'status': 'running', 'codexSHA256': 'a' * 64,
                       'processes': [{'processGroupGone': False}]}
            (self.state / 'run.json').write_text(json.dumps(runtime))
            process = Mock(returncode=0)
            process.poll.return_value = None
            def stop(timeout):
                runtime.update(status='stopped', processes=[{'processGroupGone': True}])
                (self.state / 'run.json').write_text(json.dumps(runtime))
                return 0
            process.wait.side_effect = stop
            return process

        command = ['--products', str(self.products), '--destination', 'id=synthetic-device']
        if cleanup_only:
            command += ['--cleanup-run-id', RUN_ID]
        else:
            command += ['--allow-real-model', '--codex', '/synthetic/codex',
                        '--relay', 'wss://synthetic.invalid:8443']
            if with_controls:
                command += ['--with-controls']
        stdout = io.StringIO()
        with patch.object(M, 'ROOT', self.root), patch.object(M.POLICY.CommandRunner, 'run', side_effect=run):
            with patch.object(M.subprocess, 'Popen', side_effect=launch) as start:
                with patch.object(M.time, 'sleep') as controlled_wait:
                    with contextlib.redirect_stdout(stdout):
                        result = M.main(command)
                    if with_controls and failure != 'controls':
                        controlled_wait.assert_any_call(31)
                if cleanup_only:
                    start.assert_not_called()
        printed = json.loads(stdout.getvalue())
        report_path = Path(printed['report'])
        report = json.loads(report_path.read_text())
        self.assertEqual(self.original.read_bytes(), self.original_bytes)
        self.assertEqual(list(self.products.glob('*Available-*')), [])
        return result, report, report_path

    def test_success_retains_only_sanitized_own_rollout_before_account_removal(self):
        result, report, path = self.run_fixture()
        self.assertEqual(result, 0)
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(report['stage'], 'complete')
        self.assertTrue(report['nativeEvidenceVerified'])
        self.assertTrue(report['temporaryAccountRemoved'])
        self.assertFalse(self.account.exists())
        evidence = (path.parent / 'native-metadata.json').read_text()
        for secret in ('DO_NOT_RETAIN_AUTH', 'DO_NOT_RETAIN_PERSONAL_HISTORY',
                       'DO_NOT_RETAIN_ERROR_BODY', M.PROMPT, M.MARKER):
            self.assertNotIn(secret, evidence)
        self.assertEqual(report['nativeEvidence']['rollouts'][0]['terminalStatus'], 'completed')
        self.assertEqual([item['REMODEX_ACCEPTANCE_MODE'] for item in self.configurations],
                         ['submit', 'recover', 'cleanup'])
        self.assertEqual(len({item['REMODEX_ACCEPTANCE_RUN_ID'] for item in self.configurations}), 1)

    def test_submit_failure_runs_exact_fixture_cleanup_and_preserves_primary_failure(self):
        result, report, _ = self.run_fixture(failure='submit', cleanup_failure=True)
        self.assertEqual(result, 1)
        self.assertEqual(report['failureStage'], 'device-submit')
        self.assertEqual(report['failure'], 'submit failed; original log retained.')
        self.assertEqual(report['cleanupFailures'][0]['stage'], 'device-cleanup')
        self.assertEqual(report['commands'][-1]['exitStatus'], 65)
        self.assertTrue(report['temporaryAccountRemoved'])
        self.assertEqual([item['REMODEX_ACCEPTANCE_MODE'] for item in self.configurations], ['submit', 'cleanup'])

    def test_pre_submit_failure_does_not_touch_any_device_fixture(self):
        result, report, _ = self.run_fixture(failure='prepare-account')
        self.assertEqual(result, 1)
        self.assertEqual(report['failureStage'], 'prepare-account')
        self.assertEqual(self.configurations, [])

    def test_cleanup_only_has_no_model_host_account_or_pairing(self):
        result, report, _ = self.run_fixture(cleanup_only=True)
        self.assertEqual(result, 0)
        self.assertEqual(report['mode'], 'cleanup-only')
        self.assertIsNone(report['workDirectory'])
        self.assertEqual(report['cleanupResult'], {'runID': RUN_ID, 'fixtureRemoved': True})
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(self.configurations[0]['REMODEX_ACCEPTANCE_RUN_ID'], RUN_ID)

    def test_cleanup_only_failure_is_retained_without_host_or_model(self):
        result, report, _ = self.run_fixture(cleanup_only=True, cleanup_failure=True)
        self.assertEqual(result, 1)
        self.assertEqual(report['failureStage'], 'device-cleanup')
        self.assertEqual(report['commands'][0]['exitStatus'], 65)
        self.assertEqual(len(self.commands), 1)

    def test_controls_are_explicit_and_preserve_same_run_thread_and_cleanup_order(self):
        result, report, _ = self.run_fixture(with_controls=True)
        self.assertEqual(result, 0)
        self.assertTrue(report['nativeControlsVerified'])
        self.assertEqual(report['lateMarkerObservationSeconds'], 31)
        self.assertTrue(report['controlMarkers']['lateMarkerAbsent'])
        self.assertEqual(report['controlsResult']['threadID'], report['submitResult']['threadID'])
        self.assertEqual([value['REMODEX_ACCEPTANCE_MODE'] for value in self.configurations],
                         ['submit', 'controls', 'recover', 'cleanup'])
        self.assertEqual(len({value['REMODEX_ACCEPTANCE_RUN_ID'] for value in self.configurations}), 1)
        self.assertTrue(all(value.get('REMODEX_ACCEPTANCE_WITH_CONTROLS') == 'fixed-marker-controls'
                            for value in self.configurations[:-1]))
        self.assertNotIn('REMODEX_ACCEPTANCE_WITH_CONTROLS', self.configurations[-1])

    def test_controls_failure_does_not_dispatch_recovery_or_retry_and_still_cleans_fixture(self):
        result, report, _ = self.run_fixture(with_controls=True, failure='controls')
        self.assertEqual(result, 1)
        self.assertEqual(report['failureStage'], 'device-controls')
        self.assertEqual([value['REMODEX_ACCEPTANCE_MODE'] for value in self.configurations],
                         ['submit', 'controls', 'cleanup'])

    def test_cancel_acknowledgement_without_native_cancelled_terminal_fails(self):
        result, report, _ = self.run_fixture(with_controls=True, wrong_cancel_terminal=True)
        self.assertEqual(result, 1)
        self.assertFalse(report['nativeControlsVerified'])
        self.assertEqual(report['cleanupFailures'][0]['stage'], 'retain-sanitized-rollout')

    def test_late_marker_fails_before_recovery_even_with_cancelled_client_result(self):
        result, report, _ = self.run_fixture(with_controls=True, late_marker=True)
        self.assertEqual(result, 1)
        self.assertEqual(report['failureStage'], 'observe-no-late-marker')
        self.assertEqual([value['REMODEX_ACCEPTANCE_MODE'] for value in self.configurations],
                         ['submit', 'controls', 'cleanup'])

    def test_marker_projection_rejects_wrong_content_symlinks_and_forbidden_late_object(self):
        project = self.root / 'project'
        project.mkdir()
        for name, expected in M.CONTROL_MARKERS.items():
            (project / name).write_bytes(expected)
        self.assertTrue(M.control_marker_evidence(project)['lateMarkerAbsent'])
        first = project / next(iter(M.CONTROL_MARKERS))
        first.write_text('different')
        with self.assertRaises(RuntimeError):
            M.control_marker_evidence(project)
        first.unlink()
        first.symlink_to(self.original)
        with self.assertRaises(OSError):
            M.control_marker_evidence(project)

    def test_control_result_requires_distinct_turns_exact_count_and_typed_flags(self):
        result, report, path = self.run_fixture(with_controls=True)
        self.assertEqual(result, 0)
        original = json.loads((path.parent / 'controls.log').read_text().split('MUNIE_REMODEX_ACCEPTANCE ')[1])
        log = self.root / 'modified-control.log'
        for update in ({'approvalCount': 3}, {'approvalCwdMatched': False},
                       {'approvedTurnID': CANCELLED_TURN}, {'cancelledTerminalObserved': 1}):
            value = dict(original)
            value.update(update)
            log.write_text('MUNIE_REMODEX_ACCEPTANCE ' + json.dumps(value) + '\n')
            with self.assertRaisesRegex(RuntimeError, 'invalid control record'):
                M.device_result(log, 'controls', report['runID'])

    def test_recovery_must_match_the_original_thread(self):
        result, report, _ = self.run_fixture(changed_recovery=True)
        self.assertEqual(result, 1)
        self.assertEqual(report['failureStage'], 'device-recover')
        self.assertIn('original thread', report['failure'])
        self.assertTrue(report['cleanupResult']['fixtureRemoved'])

    def test_success_without_native_rollout_fails_evidence_gate(self):
        result, report, _ = self.run_fixture(omit_rollout=True)
        self.assertEqual(result, 1)
        self.assertFalse(report['nativeEvidenceVerified'])
        self.assertEqual(report['cleanupFailures'][0]['stage'], 'retain-sanitized-rollout')
        self.assertTrue(report['temporaryAccountRemoved'])

    def test_mismatched_project_rollout_is_not_retained(self):
        account = self.root / 'account'
        self.write_rollout(account, self.root / 'other-project')
        result = M.rollout_evidence(account, self.root / 'project', RUN_ID)
        self.assertEqual(result['rollouts'], [])
        self.assertEqual(result['rejectedRollouts'], 1)

    def test_symlinked_rollout_never_reads_external_history(self):
        account = self.root / 'account'
        external = self.write_rollout(self.root / 'external', self.root)
        sessions = account / 'sessions'
        sessions.mkdir(parents=True)
        (sessions / 'linked.jsonl').symlink_to(external)
        with self.assertRaises(OSError):
            M.rollout_evidence(account, self.root, RUN_ID)

    def test_symlinked_session_directory_is_refused(self):
        account = self.root / 'account'
        account.mkdir()
        (account / 'sessions').symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'scope is unsafe'):
            M.rollout_evidence(account, self.root, RUN_ID)

    def test_fifo_rollout_is_refused_without_blocking(self):
        account = self.root / 'account'
        sessions = account / 'sessions'
        sessions.mkdir(parents=True)
        os.mkfifo(sessions / 'pipe.jsonl')
        with self.assertRaisesRegex(ValueError, 'regular file'):
            M.rollout_evidence(account, self.root, RUN_ID)

    def test_rollout_bounds_and_malformed_json_preserve_only_fixed_failure_state(self):
        account = self.root / 'account'
        rollout = self.write_rollout(account, self.root)
        with patch.object(M, 'MAX_ROLLOUT_BYTES', 10):
            with self.assertRaisesRegex(ValueError, 'bounded'):
                M.rollout_evidence(account, self.root, RUN_ID)
        with rollout.open('a') as output:
            output.write('PRIVATE_MALFORMED_RAW_TEXT\n')
        value = M.rollout_evidence(account, self.root, RUN_ID)
        self.assertEqual(value['rollouts'][0]['readStatus'], 'invalid-json')
        self.assertNotIn('PRIVATE_MALFORMED_RAW_TEXT', json.dumps(value))

    def test_native_cancelled_terminal_is_distinct_from_completion(self):
        account = self.root / 'account'
        self.write_rollout(account, self.root, terminal='turn_aborted')
        value = M.rollout_evidence(account, self.root, RUN_ID)
        self.assertEqual(value['rollouts'][0]['terminalStatus'], 'cancelled')

    def test_account_cleanup_failure_is_reported_and_retains_original_failure(self):
        real_rmtree = shutil.rmtree
        def refuse_account(path, *args, **kwargs):
            if Path(path).name == 'account':
                raise OSError('synthetic-account-cleanup')
            return real_rmtree(path, *args, **kwargs)
        with patch.object(M.shutil, 'rmtree', side_effect=refuse_account):
            result, report, _ = self.run_fixture(failure='submit')
        self.assertEqual(result, 1)
        self.assertEqual(report['failureStage'], 'device-submit')
        self.assertTrue(self.account.exists())
        self.assertEqual(report['cleanupFailures'][-1]['stage'], 'temporary-account-cleanup')

    def test_real_model_gate_and_invalid_cleanup_uuid_start_nothing(self):
        for extra in ([], ['--cleanup-run-id', 'not-a-uuid']):
            with patch.object(M.subprocess, 'Popen') as launch:
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                    M.main(['--products', str(self.products), '--destination', 'synthetic'] + extra)
                self.assertEqual(raised.exception.code, 2)
                launch.assert_not_called()

    def test_atomic_report_failure_keeps_previous_stage_and_removes_temporary(self):
        path = self.root / 'report.json'
        path.write_text('previous-stage')
        with patch.object(M.os, 'replace', side_effect=OSError('synthetic-replace')):
            with self.assertRaises(OSError):
                M.save_report(path, {'status': 'running'})
        self.assertEqual(path.read_text(), 'previous-stage')
        self.assertFalse(path.with_suffix('.json.tmp').exists())

    def test_disposable_scope_refuses_a_different_project_and_alias(self):
        work = Path(tempfile.mkdtemp(prefix='munie-remodex-account-')).resolve()
        self.paths.append(work)
        project = work / 'project'
        project.mkdir(mode=0o700)
        M.disposable_scope(work, project, work / 'account')
        with self.assertRaisesRegex(ValueError, 'scope'):
            M.disposable_scope(work, self.root, work / 'account')
        alias = self.root / 'alias'
        alias.symlink_to(work, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'scope'):
            M.disposable_scope(alias, alias / 'project', alias / 'account')

    def test_missing_duplicate_and_malformed_results_are_rejected(self):
        log = self.root / 'result.log'
        for body in ('', 'MUNIE_REMODEX_ACCEPTANCE {"runID": "private-raw"}\n',
                     ('MUNIE_REMODEX_CLEANUP ' + RUN_ID + '\n') * 2):
            log.write_text(body)
            with self.assertRaises(RuntimeError):
                M.device_result(log, 'cleanup' if 'CLEANUP' in body else 'submit', RUN_ID)

    def test_fresh_account_with_existing_history_never_reaches_a_device(self):
        result, report, _ = self.run_fixture(preexisting_history=True)
        self.assertEqual(result, 1)
        self.assertEqual(report['failureStage'], 'prepare-account')
        self.assertIn('unexpectedly contains native history', report['failure'])
        self.assertEqual(self.configurations, [])
        self.assertEqual(report['nativeEvidence']['rollouts'], [])
        self.assertTrue(report['temporaryAccountRemoved'])


if __name__ == '__main__':
    unittest.main()
