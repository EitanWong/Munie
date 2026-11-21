"""Offline lifecycle boundaries with synthetic stdio peers and loopback HTTP only."""

import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'probe-codex-turns.py'
SPEC = importlib.util.spec_from_file_location('codex_turn_probe', SCRIPT)
turns = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(turns)


class LifecycleBindingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='munie-turn-binding-')
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name)
        self.peers = []
        self.addCleanup(self.close_peers)

    def close_peers(self):
        for peer in reversed(self.peers):
            peer.close()
            self.assertTrue(peer.cleanup['processGroupGone'])
            self.assertTrue(peer.cleanup['streamsReachedEOF'])

    def peer(self, code='import sys\nsys.stdin.read()', case='approval-accept'):
        peer = turns.LifecyclePeer([sys.executable, '-I', '-u', '-c', code], self.workspace,
                                   {'PATH': os.defpath})
        peer.thread_id, peer.turn_id, peer.case = 'thread-synthetic', 'turn-synthetic', case
        self.peers.append(peer)
        return peer

    def approval(self, case='approval-accept', request_id=9):
        return {
            'id': request_id, 'method': 'item/commandExecution/requestApproval',
            'params': {
                'threadId': 'thread-synthetic', 'turnId': 'turn-synthetic',
                'itemId': 'call_' + case, 'command': "/bin/sh -c '/usr/bin/touch approval-marker'",
                'cwd': str(self.workspace), 'kind': 'command',
                'reason': 'Munie synthetic fixture approval', 'availableDecisions': [
                    'accept', {'acceptWithExecpolicyAmendment': {
                        'execpolicy_amendment': ['/usr/bin/touch', 'approval-marker']}}, 'cancel'],
            },
        }

    def event(self, method, **params):
        return {'method': method, 'params': dict(threadId='thread-synthetic', **params)}

    def test_valid_approval_binds_action_and_retains_no_command_or_path(self):
        peer = self.peer()
        peer.accept_notification(self.approval())
        self.assertEqual(peer.approval, 9)
        self.assertEqual(peer.events, [
            {'method': 'item/commandExecution/requestApproval', 'case': 'approval-accept'}])
        retained = json.dumps(peer.events)
        self.assertNotIn(str(self.workspace), retained)
        self.assertNotIn('touch', retained)

    def test_approval_wrong_thread_turn_item_command_cwd_or_kind_is_rejected(self):
        peer = self.peer()
        for field, value in (
            ('threadId', 'other-thread'), ('turnId', 'other-turn'), ('itemId', 'other-item'),
            ('command', '/usr/bin/touch other-marker'), ('cwd', '/synthetic/other-project'),
            ('kind', 'file'), ('reason', 'other action'),
        ):
            with self.subTest(field=field):
                frame = self.approval()
                frame['params'][field] = value
                with self.assertRaisesRegex(ValueError, 'Approval differs'):
                    peer.accept_notification(frame)
                self.assertIsNone(peer.approval)
                self.assertEqual(peer.events, [])

    def test_approval_available_decisions_must_be_real_options(self):
        peer = self.peer()
        for decisions in (['accept'], ['cancel'], 'acceptcancel', {'accept': 1, 'cancel': 2},
                          ['accept', 'cancel', 'accept'], ['accept', 'cancel', True]):
            with self.subTest(decisions=decisions):
                frame = self.approval()
                frame['params']['availableDecisions'] = decisions
                with self.assertRaises(ValueError):
                    peer.accept_notification(frame)
                self.assertIsNone(peer.approval)

    def test_approval_request_ids_do_not_accept_bool_or_unbound_scenario(self):
        peer = self.peer()
        for request_id in (True, None, 1.5):
            with self.subTest(request_id=request_id):
                with self.assertRaisesRegex(ValueError, 'Unexpected server request'):
                    peer.accept_notification(self.approval(request_id=request_id))
        peer.case = 'text'
        with self.assertRaisesRegex(ValueError, 'Unexpected server request'):
            peer.accept_notification(self.approval())

    def test_approval_decision_is_case_bound_and_sent_only_once(self):
        for case, decision in (('approval-cancel', 'cancel'), ('approval-accept', 'accept')):
            with self.subTest(case=case):
                marker = self.workspace / (case + '-decisions.json')
                code = ('import json,select,sys\nfrom pathlib import Path\n'
                        'frames=[json.loads(sys.stdin.readline())]\n'
                        'ready,_,_=select.select([sys.stdin],[],[],.15)\n'
                        'if ready:\n'
                        '    extra=sys.stdin.readline()\n'
                        '    if extra.strip(): frames.append(json.loads(extra))\n'
                        f'Path({str(marker)!r}).write_text(json.dumps(frames))\n'
                        'sys.stdin.read()\n')
                peer = self.peer(code, case=case)
                peer.accept_notification(self.approval(case=case))
                for invalid in ('decline', 'acceptForSession', None, True,
                                'accept' if decision == 'cancel' else 'cancel'):
                    with self.subTest(invalid=invalid):
                        with self.assertRaisesRegex(ValueError, 'approval response'):
                            peer.respond_approval(invalid)
                        self.assertFalse(peer.approval_replied)
                peer.respond_approval(decision)
                self.assertTrue(peer.approval_replied)
                with self.assertRaisesRegex(ValueError, 'approval response'):
                    peer.respond_approval(decision)
                deadline = time.monotonic() + 2
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(.005)
                self.assertTrue(marker.exists(), 'Synthetic peer did not observe the decision')
                self.assertEqual(json.loads(marker.read_text()), [
                    {'id': 9, 'result': {'decision': decision}}])

    def test_approval_cannot_be_answered_after_terminal_or_without_request(self):
        peer = self.peer()
        with self.assertRaisesRegex(ValueError, 'approval response'):
            peer.respond_approval('accept')
        peer.accept_notification(self.approval())
        peer.accept_notification(self.event('turn/completed', turn={
            'id': 'turn-synthetic', 'status': 'interrupted'}))
        with self.assertRaisesRegex(ValueError, 'approval response'):
            peer.respond_approval('accept')
        self.assertFalse(peer.approval_replied)

    def test_duplicate_approval_cannot_replace_original_request(self):
        peer = self.peer()
        peer.accept_notification(self.approval())
        with self.assertRaisesRegex(ValueError, 'Unexpected server request'):
            peer.accept_notification(self.approval(request_id=10))
        self.assertEqual(peer.approval, 9)

    def test_unknown_server_request_has_no_response_on_real_stdin(self):
        marker = self.workspace / 'input-observed.json'
        request = {'id': 51, 'method': 'item/fileChange/requestApproval', 'params': {}}
        code = ('import json,os,select,sys\nfrom pathlib import Path\n'
                f'print({json.dumps(request)!r},flush=True)\n'
                'ready,_,_=select.select([sys.stdin],[],[],.15)\n'
                'data=os.read(sys.stdin.fileno(),4096) if ready else b""\n'
                f'Path({str(marker)!r}).write_text(json.dumps(data.decode()))\n'
                'sys.stdin.read()\n')
        peer = self.peer(code)
        with self.assertRaisesRegex(ValueError, 'Unexpected server request'):
            peer.wait_for(lambda: peer.approval is not None)
        deadline = time.monotonic() + 2
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.005)
        self.assertTrue(marker.exists(), 'Synthetic peer did not finish observing its stdin')
        self.assertEqual(json.loads(marker.read_text()), '')
        self.assertIsNone(peer.approval)

    def test_terminal_ids_and_duplicates_are_rejected(self):
        peer = self.peer(case='text')
        for field in ('threadId', 'turn'):
            frame = self.event('turn/completed', turn={'id': 'turn-synthetic', 'status': 'completed'})
            if field == 'threadId':
                frame['params']['threadId'] = 'other-thread'
            else:
                frame['params']['turn']['id'] = 'other-turn'
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, '(thread|turn) mismatch'):
                    peer.accept_notification(frame)
                self.assertIsNone(peer.terminal)
        frame = self.event('turn/completed', turn={'id': 'turn-synthetic', 'status': 'completed'})
        peer.accept_notification(frame)
        self.assertEqual(peer.terminal, 'completed')
        with self.assertRaisesRegex(ValueError, 'duplicate terminal'):
            peer.accept_notification(frame)

    def test_acknowledgement_or_unknown_status_cannot_become_terminal(self):
        peer = self.peer(case='text')
        peer.accept_notification(self.event('turn/started', turn={'id': 'turn-synthetic', 'status': 'inProgress'}))
        self.assertIsNone(peer.terminal)
        for status in ('inProgress', 'accepted', 'unknown'):
            with self.subTest(status=status):
                with self.assertRaisesRegex(ValueError, 'terminal event'):
                    peer.accept_notification(self.event('turn/completed', turn={
                        'id': 'turn-synthetic', 'status': status}))
                self.assertIsNone(peer.terminal)

    def test_stale_item_or_command_id_does_not_count_as_result(self):
        peer = self.peer()
        frame = self.event('item/completed', turnId='other-turn', item={
            'type': 'commandExecution', 'id': 'call_approval-accept', 'status': 'completed', 'exitCode': 0})
        with self.assertRaisesRegex(ValueError, 'Item turn mismatch'):
            peer.accept_notification(frame)
        frame['params']['turnId'] = 'turn-synthetic'
        frame['params']['item']['id'] = 'other-item'
        with self.assertRaisesRegex(ValueError, 'Command item mismatch'):
            peer.accept_notification(frame)
        self.assertIsNone(peer.command_result)

    def test_resolved_approval_is_bound_to_original_request(self):
        peer = self.peer()
        peer.accept_notification(self.approval(request_id=1))
        for request_id in (2, '1', True):
            with self.subTest(request_id=request_id):
                with self.assertRaisesRegex(ValueError, 'Resolved approval identity mismatch'):
                    peer.accept_notification(self.event('serverRequest/resolved', requestId=request_id))
                self.assertFalse(peer.resolved)
        peer.accept_notification(self.event('serverRequest/resolved', requestId=1))
        self.assertTrue(peer.resolved)

    def test_unknown_event_and_wrong_final_marker_fail_closed(self):
        peer = self.peer(case='text')
        with self.assertRaisesRegex(ValueError, 'Unexpected native lifecycle notification'):
            peer.accept_notification(self.event('unknown/native/event'))
        with self.assertRaisesRegex(ValueError, 'Synthetic final marker mismatch'):
            peer.accept_notification(self.event('item/completed', turnId='turn-synthetic', item={
                'type': 'agentMessage', 'text': 'not the marker'}))
        self.assertIsNone(peer.message)

    def test_synthetic_key_in_trailing_native_notification_fails_the_probe(self):
        code = (
            'import json, os, sys\n'
            'sys.stdin.read()\n'
            'print(json.dumps({"method": "remoteControl/status/changed", '
            '"params": {"status": "disabled", "canary": '
            f'os.environ[{turns.PROVIDER_KEY_ENV!r}]}}}}), flush=True)\n')
        peer = turns.LifecyclePeer(
            [sys.executable, '-I', '-u', '-c', code], self.workspace,
            {turns.PROVIDER_KEY_ENV: 'disposable-synthetic-key'}, check_key_environment=True)
        with self.assertRaisesRegex(ValueError, 'Provider key reached native protocol output'):
            peer.close()
        self.assertTrue(peer.cleanup['processGroupGone'])


class LoopbackProviderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='munie-turn-provider-')
        self.addCleanup(self.temporary.cleanup)
        self.workspace = Path(self.temporary.name)
        self.server = turns.FixtureServer(self.workspace)
        self.addCleanup(self.server.close)

    def payload(self, **updates):
        body = {'model': turns.MODEL, 'stream': True, 'input': [], 'tools': [{'name': 'exec_command'}]}
        body.update(updates)
        return json.dumps(body).encode()

    def post(self, body=None, path=None, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        try:
            connection.request('POST', path or self.server.path,
                               body=self.payload() if body is None else body, headers=headers or {})
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def rejected(self, **kwargs):
        with self.assertRaises((http.client.HTTPException, OSError)):
            self.post(**kwargs)
        with self.assertRaisesRegex(ValueError, 'provider rejected'):
            self.server.check(self.server.count)

    def test_fixture_binds_loopback_and_random_endpoint(self):
        self.assertEqual(self.server.server_address[0], '127.0.0.1')
        self.assertTrue(self.server.path.startswith('/fixture-'))
        self.assertTrue(self.server.path.endswith('/responses'))
        self.server.select('text')
        status, wire = self.post()
        self.assertEqual(status, 200)
        events = [json.loads(frame[6:]) for frame in wire.decode().strip().split('\n\n')]
        self.assertEqual(events[-1]['type'], 'response.completed')
        self.assertEqual(events[-1]['response']['output'][0]['content'][0]['text'], turns.MARKER)
        self.server.check(1)

    def test_wrong_endpoint_is_rejected_without_provider_response(self):
        self.server.select('text')
        self.rejected(path='/responses')
        self.assertEqual(self.server.total, 0)

    def test_credentials_are_rejected(self):
        self.server.select('text')
        for name in ('Authorization', 'Cookie'):
            with self.subTest(header=name):
                self.rejected(headers={name: 'synthetic-sensitive-value'})
        self.assertEqual(self.server.total, 0)

    def test_duplicate_credential_headers_cannot_hide_behind_empty_first_value(self):
        self.server.select('text')
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        body = self.payload()
        try:
            connection.putrequest('POST', self.server.path)
            connection.putheader('Content-Length', str(len(body)))
            connection.putheader('Authorization', '')
            connection.putheader('Authorization', 'synthetic-token')
            connection.endheaders(body)
            with self.assertRaises((http.client.HTTPException, OSError)):
                connection.getresponse()
        finally:
            connection.close()
        self.assertIsNotNone(self.server.failure)
        self.assertEqual(self.server.total, 0)

    def test_synthetic_auth_requires_exact_bearer_and_never_accepts_key_in_body(self):
        original = self.server
        fake_key = 'synthetic-key-only'
        try:
            self.server = turns.FixtureServer(self.workspace, synthetic_key=fake_key)
            self.server.select('text')
            headers = {'Authorization': 'Bearer ' + fake_key}
            self.assertEqual(self.post(headers=headers)[0], 200)
            self.server.check(1)
            for rejected in ({}, {'Authorization': 'Bearer different-key'},
                             {**headers, 'Cookie': 'synthetic'}):
                with self.subTest(headers=rejected):
                    self.rejected(headers=rejected)
            self.rejected(headers=headers, body=self.payload(input=[fake_key]))
            self.assertEqual(self.server.total, 1)
        finally:
            self.server.close()
            self.server = original

    def test_key_guard_rejects_even_an_empty_inherited_key(self):
        marker = self.workspace / 'approval-marker'
        for value in ('synthetic-key-only', ''):
            result = subprocess.run(
                ['/bin/sh', '-c', turns.key_guard_source()], cwd=self.workspace,
                env={turns.PROVIDER_KEY_ENV: value}, capture_output=True, timeout=3)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (87, b'', b''))
            self.assertFalse(marker.exists())
        subprocess.run(['/bin/sh', '-c', turns.key_guard_source()], cwd=self.workspace,
                       env={}, check=True, timeout=3)
        self.assertTrue(marker.exists())

    def test_oversized_and_chunked_request_are_rejected(self):
        self.server.select('text')
        self.rejected(body=b'x' * (turns.MAX_REQUEST + 1))
        self.rejected(headers={'Transfer-Encoding': 'chunked'})
        self.assertEqual(self.server.total, 0)

    def test_invalid_json_duplicate_keys_and_wrong_shapes_are_rejected(self):
        self.server.select('text')
        for body in (b'not json', b'{"model":"x","model":"y"}', b'[]',
                     self.payload(model='other-model'), self.payload(stream=False), self.payload(input={})):
            with self.subTest(body=body[:100]):
                self.rejected(body=body)
        self.assertEqual(self.server.total, 0)

    def test_retry_and_total_provider_request_limits_are_enforced(self):
        self.server.select('text')
        self.assertEqual(self.post()[0], 200)
        self.rejected()
        self.assertEqual(self.server.count, 2)

    def test_lifetime_request_limit_survives_scenario_reset(self):
        for _ in range(6):
            self.server.select('text')
            self.assertEqual(self.post()[0], 200)
        self.assertEqual(self.server.total, 6)
        self.assertEqual(self.server.connections, 6)
        self.server.select('text')
        self.rejected()
        self.assertEqual(self.server.total, 7)

    def test_command_tool_must_exist_before_fixture_emits_call(self):
        self.server.select('approval-accept')
        self.rejected(body=self.payload(tools=[]))

    def test_command_call_arguments_are_narrow_and_bound_to_workspace(self):
        self.server.select('approval-accept')
        status, wire = self.post()
        self.assertEqual(status, 200)
        frames = [json.loads(frame[6:]) for frame in wire.decode().strip().split('\n\n')]
        call = frames[-1]['response']['output'][0]
        self.assertEqual(call['type'], 'function_call')
        self.assertEqual(call['call_id'], 'call_approval-accept')
        arguments = json.loads(call['arguments'])
        self.assertEqual(arguments['cmd'], '/usr/bin/touch approval-marker')
        self.assertEqual(arguments['workdir'], str(self.workspace))
        self.assertEqual(arguments['sandbox_permissions'], 'require_escalated')
        self.assertFalse((self.workspace / 'approval-marker').exists(), 'Fixture itself ran a command')

    def test_tool_result_must_match_call_and_contain_real_output(self):
        original = self.server
        try:
            for result in ([], [{'type': 'function_call_output', 'call_id': 'other-call', 'output': 'exit 0'}],
                           [{'type': 'function_call_output', 'call_id': 'call_approval-accept'}],
                           [{'type': 'function_call_output', 'call_id': 'call_approval-accept', 'output': ''}]):
                with self.subTest(result=result):
                    self.server = turns.FixtureServer(self.workspace)
                    try:
                        self.server.select('approval-accept')
                        self.assertEqual(self.post()[0], 200)
                        self.rejected(body=self.payload(input=result))
                    finally:
                        self.server.close()
        finally:
            self.server = original

    def test_matching_tool_result_allows_exactly_one_followup(self):
        self.server.select('approval-accept')
        self.assertEqual(self.post()[0], 200)
        body = self.payload(input=[{
            'type': 'function_call_output', 'call_id': 'call_approval-accept',
            'output': 'Synthetic tool fixture: process exited with code 0',
        }])
        self.assertEqual(self.post(body=body)[0], 200)
        self.server.check(2)
        self.rejected(body=body)
        self.assertEqual(self.server.count, 3)

    def assert_close_interrupts_partial_http(self, wire):
        connection = socket.create_connection(('127.0.0.1', self.server.server_port), timeout=2)
        try:
            connection.sendall(wire)
            deadline = time.monotonic() + 2
            while self.server.connections < 1 and time.monotonic() < deadline:
                time.sleep(.005)
            self.assertEqual(self.server.connections, 1)
            start = time.monotonic()
            self.server.close()
            self.assertLess(time.monotonic() - start, 1.5,
                            'Shutdown waited for the socket read timeout instead of ending the read')
            self.assertFalse(self.server.thread.is_alive())
        finally:
            connection.close()

    def test_close_interrupts_incomplete_http_headers(self):
        wire = f'POST {self.server.path} HTTP/1.1\r\nHost: localhost\r\nX-Synthetic: '.encode()
        self.assert_close_interrupts_partial_http(wire)

    def test_close_interrupts_incomplete_http_body(self):
        self.server.select('text')
        wire = (f'POST {self.server.path} HTTP/1.1\r\nHost: localhost\r\n'
                'Content-Length: 100\r\n\r\n{').encode()
        self.assert_close_interrupts_partial_http(wire)

    def test_malformed_trailing_connection_is_visible_beyond_valid_requests(self):
        self.server.select('text')
        self.assertEqual(self.post()[0], 200)
        self.server.check(1)
        connection = socket.create_connection(('127.0.0.1', self.server.server_port), timeout=2)
        try:
            connection.sendall(b'not a valid HTTP request\r\n\r\n')
            connection.recv(4096)
        finally:
            connection.close()
        self.assertEqual(self.server.total, 1)
        self.assertEqual(self.server.connections, 2)
        self.assertGreater(self.server.connections, self.server.total)


class TurnProbeReportTests(unittest.TestCase):
    def test_failed_experiment_invalidates_previous_pass_without_raw_failure_details(self):
        with tempfile.TemporaryDirectory(prefix='munie-turn-report-') as directory:
            root = Path(directory)
            report = root / 'report.json'
            ready = root / 'experiment-ready'
            report.write_text(json.dumps({'status': 'passed', 'oldEvidence': True}))
            code = (
                'import importlib.util,sys\\nfrom pathlib import Path\\n'
                'script,report,ready=sys.argv[1:]\\n'
                'spec=importlib.util.spec_from_file_location("synthetic_turn_probe",script)\\n'
                'module=importlib.util.module_from_spec(spec)\\nspec.loader.exec_module(module)\\n'
                'def synthetic_experiment(args, evidence):\\n'
                '    Path(ready).write_text(Path(report).read_text())\\n'
                '    raise ValueError("synthetic-private-host-and-token")\\n'
                'module.experiment=synthetic_experiment\\n'
                'sys.argv=[script,"--codex","/synthetic/codex",\\n'
                '    "--schema-dir","/synthetic/schema",\\n'
                '    "--default-schema-dir","/synthetic/default","--output",report]\\n'
                'sys.exit(module.main())\\n'
            ).replace('\\n', '\n')
            completed = subprocess.run([sys.executable, '-I', '-c', code, str(SCRIPT), str(report), str(ready)],
                                       stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5)
            self.assertEqual(completed.returncode, 1)
            self.assertTrue(ready.exists(), completed.stderr)
            initial = json.loads(ready.read_text())
            self.assertEqual((initial['status'], initial['phase']), ('failed', 'starting'))
            final = json.loads(report.read_text())
            self.assertEqual(final['status'], 'failed')
            self.assertNotIn('oldEvidence', final)
            self.assertEqual(final['failureType'], 'ValueError')
            self.assertNotIn('synthetic-private-host-and-token', report.read_text() + completed.stderr)
            self.assertEqual(report.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
