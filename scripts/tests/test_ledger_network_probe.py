"""Offline boundary and real-process cleanup tests; no TLS or ledger execution is simulated."""

from contextlib import redirect_stderr, redirect_stdout
from email.message import Message
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / 'probe-ledger-network.py'
SPEC = importlib.util.spec_from_file_location('ledger_network_under_test', SCRIPT)
ledger = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ledger)
FINGERPRINT = hashlib.sha256(b'synthetic verified peer DER').hexdigest()


def body(**changes):
    return json.dumps({'requestID': ledger.REQUEST_A, 'projectID': ledger.PROJECT,
                       'payload': ledger.TEXT, **changes}).encode('utf-8')


def snapshot(**changes):
    return {'event': 'result', 'state': 'ledger-snapshot', 'requestID': ledger.REQUEST_A,
            'phase': 'accepted', **changes}


def native_result(**changes):
    return {'event': 'result', 'bodyBytes': 120, 'overflow': False, 'redirectRejected': False,
            'cancelledOnResponse': False, 'serverChallenges': 1, 'clientChallenges': 1,
            'trustRejected': 0, 'httpStatus': 200, 'tlsProtocol': 772, 'proxy': False,
            'state': 'ledger-snapshot', 'requestID': ledger.REQUEST_A, 'phase': 'accepted', **changes}


def handler(policy, *, path='/fixture/submit', data=None, headers=None):
    value = ledger.LedgerHTTPHandler.__new__(ledger.LedgerHTTPHandler)
    value.path = path
    value.connection = Mock()
    value.connection.getpeercert.return_value = b'synthetic verified peer DER'
    value.server = SimpleNamespace(policy=policy)
    value.rfile = io.BytesIO(body() if data is None else data)
    value.send_result = Mock()
    value.headers = Message()
    for name, content in (headers if headers is not None else [
            ('Content-Type', 'application/json'),
            ('Content-Length', str(len(body() if data is None else data)))]):
        value.headers.add_header(name, content)
    return value


class HTTPIdentityBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.bridge = Mock()
        self.bridge.call.return_value = snapshot()
        self.policy = ledger.LedgerPolicy(self.bridge)

    def test_only_verified_peer_der_selects_identity_even_with_forged_headers(self):
        request = handler(self.policy, headers=[
            ('Content-Type', 'application/json'), ('Content-Length', str(len(body()))),
            ('X-Munie-Device', ledger.DEVICE_B), ('X-Munie-Fingerprint', 'f' * 64),
            ('Authorization', 'Bearer synthetic-forgery')])
        request.do_POST()
        request.connection.getpeercert.assert_called_once_with(binary_form=True)
        self.bridge.call.assert_called_once_with({
            'operation': 'accept', 'peerFingerprint': FINGERPRINT, 'requestID': ledger.REQUEST_A,
            'projectID': ledger.PROJECT, 'text': ledger.TEXT})
        request.send_result.assert_called_once_with(200, {k: v for k, v in snapshot().items()
                                                        if k != 'event'}, close=False)

    def test_body_cannot_supply_identity_or_local_administration_fields(self):
        for field in ('deviceID', 'fingerprint', 'peerFingerprint', 'hostID', 'operation', 'cwd'):
            with self.subTest(field=field):
                status, result = self.policy.submit(FINGERPRINT, body(**{field: ledger.DEVICE_B}))
                self.assertEqual((status, result), (400, {'error': 'invalid-request'}))
        self.bridge.call.assert_not_called()
        self.assertFalse(self.policy.results)

    def test_duplicate_identity_is_rejected_when_all_other_fields_are_valid(self):
        duplicate = ('{"requestID":"' + ledger.REQUEST_A + '","\\u0072equestID":"' +
                     ledger.REQUEST_B + '","projectID":"' + ledger.PROJECT + '","payload":"' +
                     ledger.TEXT + '"}').encode('utf-8')
        self.assertEqual(self.policy.submit(FINGERPRINT, duplicate),
                         (400, {'error': 'invalid-request'}))
        self.bridge.call.assert_not_called()

    def test_snapshot_is_a_read_with_only_the_request_identifier(self):
        request = handler(self.policy, path='/fixture/snapshot',
                          data=json.dumps({'requestID': ledger.REQUEST_A}).encode())
        request.do_POST()
        self.bridge.call.assert_called_once_with({'operation': 'snapshot',
                                                  'peerFingerprint': FINGERPRINT,
                                                  'requestID': ledger.REQUEST_A})
        self.assertEqual([row['operation'] for row in self.policy.results], ['snapshot'])
        self.bridge.reset_mock()
        for injected in ({'requestID': ledger.REQUEST_A, 'projectID': ledger.PROJECT},
                         {'requestID': ledger.REQUEST_A, 'operation': 'claim'},
                         {'requestID': ledger.REQUEST_A, 'deviceID': ledger.DEVICE_B}):
            with self.subTest(keys=list(injected)):
                self.assertEqual(self.policy.request('snapshot', FINGERPRINT,
                                                      json.dumps(injected).encode()),
                                 (400, {'error': 'invalid-request'}))
        self.bridge.call.assert_not_called()

    def test_remote_admin_and_ambiguous_routes_never_reach_stdio(self):
        for route in ('revoke', 'claim', 'snapshot?requestID=synthetic', '../submit', 'submit/'):
            with self.subTest(route=route):
                request = handler(self.policy, path='/fixture/' + route)
                request.do_POST()
                request.send_result.assert_called_once_with(
                    404, {'error': 'fixture-route'}, close=True)
                request.connection.getpeercert.assert_not_called()
        self.bridge.call.assert_not_called()
        for operation in ('revoke', 'claim'):
            self.assertEqual(self.policy.request(operation, FINGERPRINT, body()),
                             (400, {'error': 'invalid-request'}))
        self.bridge.call.assert_not_called()

    def test_ambiguous_framing_and_oversize_are_rejected_before_bridge_calls(self):
        content_type = ('Content-Type', 'application/json')
        for headers, status in [
                ([content_type], 400),
                ([content_type, ('Content-Length', '2'), ('Content-Length', '2')], 400),
                ([content_type, ('Content-Length', '2'), ('Transfer-Encoding', 'chunked')], 400),
                ([content_type, ('Content-Length', '\u0662')], 400),
                ([content_type, ('Content-Length', '0')], 413),
                ([content_type, ('Content-Length', '2049')], 413)]:
            with self.subTest(headers=headers):
                request = handler(self.policy, data=b'{}', headers=headers)
                request.do_POST()
                self.assertEqual(request.send_result.call_args.args[0], status)
                self.assertIs(request.send_result.call_args.kwargs['close'], True)
                request.connection.getpeercert.assert_not_called()
        self.bridge.call.assert_not_called()

    def test_malformed_identifiers_and_payload_types_never_reach_bridge(self):
        invalid = [b'\xff', b'null', b'[]', body(requestID=True), body(requestID='not-a-uuid'),
                   body(requestID='abcdef00-0000-0000-0000-000000000001'), body(projectID=False),
                   body(payload=True), body(payload='  '), body(payload='\u754c' * 683)]
        for data in invalid:
            with self.subTest(data=data[:40]):
                self.assertEqual(self.policy.submit(FINGERPRINT, data),
                                 (400, {'error': 'invalid-request'}))
        self.bridge.call.assert_not_called()

    def test_wrong_request_or_non_domain_frame_cannot_be_forwarded_as_success(self):
        invalid = [snapshot(requestID=ledger.REQUEST_B), snapshot(phase='invented'),
                   snapshot(rawBody='synthetic-private'),
                   {'event': 'result', 'state': 'ledger-claim', 'requestID': ledger.REQUEST_A,
                    'phase': 'dispatching', 'send': True},
                   {'event': 'revoked'}, {'event': 'result', 'error': 'arbitrary-private-error'},
                   {'event': 'result', 'error': 'unauthorized', 'state': 'ledger-snapshot'},
                   {'event': 'result', 'error': True}]
        for frame in invalid:
            with self.subTest(frame=frame):
                self.bridge.call.return_value = frame
                with self.assertRaises(ValueError):
                    self.policy.submit(FINGERPRINT, body())
                self.assertFalse(self.policy.results)

    def test_forwarding_failure_is_recorded_even_when_http_server_suppresses_tracebacks(self):
        for failure in (ValueError('synthetic-private-frame'), OSError('synthetic-private-EOF')):
            with self.subTest(failure=type(failure).__name__):
                self.bridge.call.side_effect = failure
                request = handler(self.policy)
                with self.assertRaises(type(failure)):
                    request.do_POST()
                self.assertEqual(self.policy.failure, type(failure).__name__)
                request.send_result.assert_not_called()
                self.assertFalse(self.policy.results)

    def test_candidate_denial_remains_a_denial_without_an_acceptance_record(self):
        self.bridge.call.return_value = {'event': 'result', 'error': 'unauthorized'}
        self.assertEqual(self.policy.submit(FINGERPRINT, body()), (200, {'error': 'unauthorized'}))
        self.assertEqual(self.policy.results[0]['result'], {'error': 'unauthorized'})
        self.assertNotIn('state', self.policy.results[0]['result'])


class EvidenceValidationTests(unittest.TestCase):
    def test_native_missing_or_ambiguous_domain_fields_fail_closed(self):
        invalid = [None, [], native_result(phase='invented'), native_result(requestID=True),
                   native_result(fixtureError='unauthorized'), native_result(ordinal=1),
                   native_result(bodyBytes=True), native_result(proxy=True),
                   native_result(tlsProtocol=771), native_result(errorCode=-999),
                   native_result(rawBody='synthetic-private')]
        for name in ('state', 'requestID', 'phase', 'cancelledOnResponse'):
            incomplete = native_result()
            del incomplete[name]
            invalid.append(incomplete)
        for frame in invalid:
            with self.subTest(frame=frame), self.assertRaises(ValueError):
                ledger.validate_native_reply(frame)
        self.assertEqual(ledger.validate_native_reply(native_result()), native_result())

    def test_old_pass_is_invalidated_before_work_and_failure_text_is_private(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'report.json'
            output.write_text('{"status":"passed","obsolete":"previous-evidence"}')
            secret = 'synthetic-private-token-and-request-text'

            def fail(*_arguments):
                self.assertEqual(json.loads(output.read_bytes())['status'], 'failed')
                self.assertEqual(json.loads(output.read_bytes())['phase'], 'starting')
                self.assertNotIn('obsolete', output.read_text())
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
                raise ValueError(secret)

            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(ledger.sys, 'argv', [
                    'probe', '--native-executable', '/synthetic-native',
                    '--ledger-executable', '/synthetic-ledger', '--openssl', '/synthetic-openssl',
                    '--output', str(output)]), patch.object(ledger, 'experiment', side_effect=fail), \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                self.assertEqual(ledger.main(), 1)
            report = json.loads(output.read_bytes())
            self.assertEqual((report['status'], report['failureType']), ('failed', 'ValueError'))
            self.assertNotIn(secret, output.read_text() + stdout.getvalue() + stderr.getvalue())
            self.assertNotIn('PASS', stdout.getvalue())

    def run_incomplete_experiment(self, cases, *, primary=None, cleanup=None):
        report, roots = {}, []
        bridge = Mock()
        bridge.stop.side_effect = cleanup

        def run(_native, _bridge, root, _password, value):
            roots.append(root)
            value['cases'] = cases
            if primary is not None:
                raise primary

        executable = Path(sys.executable).resolve()
        with patch.object(ledger.native.platform, 'system', return_value='Darwin'), \
                patch.object(ledger.native.ssl, 'HAS_TLSv1_3', True), \
                patch.object(ledger.native, 'record_metadata'), \
                patch.object(ledger.native, 'prepare_native_certificates', return_value='synthetic'), \
                patch.object(ledger.network, 'fingerprint', return_value=FINGERPRINT), \
                patch.object(ledger, 'LedgerBridge', return_value=bridge), \
                patch.object(ledger, 'run_cases', side_effect=run):
            with self.assertRaises(type(primary) if primary is not None else ValueError) as raised:
                ledger.experiment(executable, executable, executable, report)
        self.assertTrue(report['temporaryCredentialsAndLedgerRemoved'])
        self.assertEqual(len(roots), 1)
        self.assertFalse(roots[0].exists())
        bridge.stop.assert_called_once_with()
        return raised.exception, report

    def test_no_empty_missing_reordered_duplicate_or_failed_case_set_is_complete(self):
        expected = [{'name': name, 'passed': True} for name in ledger.EXPECTED_CASES]
        failed = [dict(value) for value in expected]
        failed[0]['passed'] = False
        for cases in ([], expected[:-1], list(reversed(expected)), expected + [expected[0]], failed):
            with self.subTest(names=[value['name'] for value in cases]):
                self.run_incomplete_experiment(cases)

    def test_primary_execution_failure_survives_cleanup_failure_and_removes_material(self):
        primary = ValueError('synthetic-private-primary')
        raised, report = self.run_incomplete_experiment(
            [], primary=primary, cleanup=OSError('synthetic-private-cleanup'))
        self.assertIs(raised, primary)
        self.assertEqual(report['ledgerCleanupFailureType'], 'OSError')
        self.assertNotIn('synthetic-private', json.dumps(report))


class BridgeLifecycleTests(unittest.TestCase):
    def test_http_and_local_admin_share_one_complete_stdio_exchange_lock(self):
        bridge = ledger.LedgerBridge(Path('/synthetic-ledger'), Path('/synthetic-root'), {})
        waiting, release, second_sent = threading.Event(), threading.Event(), threading.Event()
        requests, outcomes = [], []
        peer = Mock()

        def send(command):
            requests.append(command['operation'])
            if len(requests) == 2:
                second_sent.set()

        def read(_deadline):
            if len(requests) == 1:
                waiting.set()
                if not release.wait(2):
                    raise TimeoutError('Test failed to release first exchange')
            return {'event': 'offline-exchange'}

        peer.send.side_effect, peer.read_frame.side_effect = send, read
        bridge.peer = peer

        def call(operation):
            try:
                outcomes.append(bridge.call({'operation': operation}))
            except BaseException as error:
                outcomes.append(error)

        first = threading.Thread(target=call, args=('snapshot',))
        second = threading.Thread(target=call, args=('revoke',))
        first.start()
        try:
            self.assertTrue(waiting.wait(1))
            second.start()
            self.assertFalse(second_sent.wait(.05), 'Admin wrote inside an unfinished HTTP exchange')
        finally:
            release.set()
            first.join(2)
            if second.ident is not None:
                second.join(2)
        self.assertFalse(first.is_alive() or second.is_alive())
        self.assertEqual(requests, ['snapshot', 'revoke'])
        self.assertEqual(outcomes, [{'event': 'offline-exchange'}] * 2)

    def test_stop_still_finishes_and_records_cleanup_when_kill_or_wait_fails(self):
        for signal_failure in (PermissionError('synthetic-signal'), None):
            with self.subTest(signal_failure=signal_failure):
                report = {'ledgerProcesses': [{}]}
                bridge = ledger.LedgerBridge(Path('/synthetic-ledger'), Path('/synthetic-root'), report)
                peer = Mock(cleanup={'processGroupGone': True, 'streamsReachedEOF': True},
                            totals={'stdout': 0, 'stderr': 0},
                            digests={'stdout': hashlib.sha256(), 'stderr': hashlib.sha256()})
                failure = signal_failure or subprocess.TimeoutExpired('synthetic-child', 3)
                peer.process.wait.side_effect = failure if signal_failure is None else None
                peer.finish.side_effect = ValueError('synthetic-cleanup')
                bridge.peer = peer
                with patch.object(ledger.os, 'killpg', side_effect=signal_failure):
                    with self.assertRaises(type(failure)) as raised:
                        bridge.stop(killed=True)
                self.assertIs(raised.exception, failure)
                peer.finish.assert_called_once_with(killed=True)
                self.assertIsNone(bridge.peer)
                self.assertEqual(report['ledgerProcesses'][0]['cleanup'], peer.cleanup)
                self.assertEqual(report['ledgerProcesses'][0]['cleanupFailureType'], 'ValueError')
                bridge.stop()
                peer.finish.assert_called_once()

    def real_peer(self, directory, *, closed=True, trailing=False, stderr=False):
        source = directory / 'offline-ledger-peer.py'
        source.write_text(
            'import json,sys\n'
            'print(json.dumps({"event":"ready","sqliteVersion":"offline-test"}),flush=True)\n'
            'for line in sys.stdin: pass\n'
            + ('print(json.dumps({"event":"closed"}),flush=True)\n' if closed else '')
            + ('print(json.dumps({"event":"unexpected"}),flush=True)\n' if trailing else '')
            + ('print("synthetic-private-stderr",file=sys.stderr,flush=True)\n' if stderr else ''),
            encoding='utf-8')
        peer = ledger.LedgerPeer([sys.executable, '-I', str(source)], directory,
                                 {'PATH': '/usr/bin:/bin'}, request_seconds=1, total_seconds=10)

        def cleanup():
            try:
                ledger.helper.JsonLinePeer.close(peer)
            except (ValueError, OSError):
                pass
            self.assertIsNotNone(peer.cleanup)
            self.assertTrue(peer.cleanup['processGroupGone'])

        self.addCleanup(cleanup)
        return peer

    def test_actual_process_requires_closed_ack_eof_zero_stderr_and_group_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            peer = self.real_peer(Path(directory))
            self.assertEqual(peer.ready(), 'offline-test')
            self.assertEqual(peer.finish(), {'exitStatus': 0, 'streamsReachedEOF': True,
                                             'processGroupGone': True})

    def test_missing_ack_or_trailing_frame_cannot_hide_successful_process_exit(self):
        for changes in ({'closed': False}, {'trailing': True}, {'stderr': True}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                peer = self.real_peer(Path(directory), **changes)
                peer.ready()
                with self.assertRaises(ValueError):
                    peer.finish()
                self.assertEqual(peer.cleanup['exitStatus'], 0)
                self.assertTrue(peer.cleanup['processGroupGone'])

    def test_actual_sigkill_has_no_fake_close_ack_and_still_reaps_streams(self):
        with tempfile.TemporaryDirectory() as directory:
            report = {'ledgerProcesses': [{}]}
            bridge = ledger.LedgerBridge(Path('/synthetic-ledger'), Path(directory), report)
            peer = self.real_peer(Path(directory))
            peer.ready()
            bridge.peer = peer
            bridge.stop(killed=True)
            self.assertEqual(report['ledgerProcesses'][0]['cleanup'], {
                'exitStatus': -signal.SIGKILL, 'streamsReachedEOF': True, 'processGroupGone': True})


if __name__ == '__main__':
    unittest.main()
